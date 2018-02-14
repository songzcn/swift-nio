//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import NIO
import XCTest

private extension SocketAddress {
    init(_ addr: UnsafePointer<sockaddr>) {
        let family = addr.pointee.sa_family

        switch family {
        case sa_family_t(AF_UNIX):
            self = addr.withMemoryRebound(to: sockaddr_un.self, capacity: 1) {
                SocketAddress($0.pointee)
            }
        case sa_family_t(AF_INET):
            self = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                SocketAddress($0.pointee, host: "")
            }
        case sa_family_t(AF_INET6):
            self = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                SocketAddress($0.pointee, host: "")
            }
        default:
            fatalError("Unexpected family type")
        }
    }

    var expectedSize: socklen_t {
        switch self {
        case .v4:
            return socklen_t(MemoryLayout<sockaddr_in>.size)
        case .v6:
            return socklen_t(MemoryLayout<sockaddr_in6>.size)
        case .unixDomainSocket:
            return socklen_t(MemoryLayout<sockaddr_un>.size)
        }
    }
}

class PendingDatagramWritesManagerTests: XCTestCase {
    private enum FakeWriteResult {
        case ok(IOResult<Int>)
        case error(Error)
    }

    private func withPendingDatagramWritesManager(_ fn: (PendingDatagramWritesManager) throws -> Void) rethrows {
        try withExtendedLifetime(NSObject()) { o in
            var iovecs: [IOVector] = Array(repeating: iovec(), count: Socket.writevLimitIOVectors + 1)
            var managed: [Unmanaged<AnyObject>] = Array(repeating: Unmanaged.passUnretained(o), count: Socket.writevLimitIOVectors + 1)
            var msgs: [MMsgHdr] = Array(repeating: MMsgHdr(), count: Socket.writevLimitIOVectors + 1)
            var addresses: [sockaddr_storage] = Array(repeating: sockaddr_storage(), count: Socket.writevLimitIOVectors + 1)
            /* put a canary value at the end */
            iovecs[iovecs.count - 1] = iovec(iov_base: UnsafeMutableRawPointer(bitPattern: 0xdeadbeef)!, iov_len: 0xdeadbeef)
            try iovecs.withUnsafeMutableBufferPointer { iovecs in
                try managed.withUnsafeMutableBufferPointer { managed in
                    try msgs.withUnsafeMutableBufferPointer { msgs in
                        try addresses.withUnsafeMutableBufferPointer { addresses in
                            let pwm = NIO.PendingDatagramWritesManager(msgs: msgs, iovecs: iovecs, addresses: addresses, storageRefs: managed)
                            XCTAssertTrue(pwm.isEmpty)
                            XCTAssertFalse(pwm.closed)
                            XCTAssertFalse(pwm.isFlushPending)
                            XCTAssertTrue(pwm.isWritable)

                            try fn(pwm)

                            XCTAssertTrue(pwm.isEmpty)
                            XCTAssertFalse(pwm.isFlushPending)
                        }
                    }
                }
            }
            /* assert that the canary values are still okay, we should definitely have never written those */
            XCTAssertEqual(managed.last!.toOpaque(), Unmanaged.passUnretained(o).toOpaque())
            XCTAssertEqual(0xdeadbeef, Int(bitPattern: iovecs.last!.iov_base))
            XCTAssertEqual(0xdeadbeef, iovecs.last!.iov_len)
        }
    }

    /// A frankenstein testing monster. It asserts that for `PendingDatagramWritesManager` `pwm` and `EventLoopPromises` `promises`
    /// the following conditions hold:
    ///  - The 'single write operation' is called `exepectedSingleWritabilities.count` number of times with the respective buffer lengths in the array.
    ///  - The 'vector write operation' is called `exepectedVectorWritabilities.count` number of times with the respective buffer lengths in the array.
    ///  - after calling the write operations, the promises have the states in `promiseStates`
    ///
    /// The write operations will all be faked and return the return values provided in `returns`.
    ///
    /// - parameters:
    ///     - pwm: The `PendingStreamWritesManager` to test.
    ///     - promises: The promises for the writes issued.
    ///     - expectedSingleWritabilities: The expected buffer lengths and addresses for the calls to the single write operation.
    ///     - expectedVectorWritabilities: The expected buffer lengths and addresses for the calls to the vector write operation.
    ///     - returns: The return values of the fakes write operations (both single and vector).
    ///     - promiseStates: The states of the promises _after_ the write operations are done.
    private func assertExpectedWritability(pendingWritesManager pwm: PendingDatagramWritesManager,
                                           promises: [EventLoopPromise<()>],
                                           expectedSingleWritabilities: [(Int, SocketAddress)]?,
                                           expectedVectorWritabilities: [[(Int, SocketAddress)]]?,
                                           returns: [FakeWriteResult],
                                           promiseStates: [[Bool]],
                                           file: StaticString = #file,
                                           line: UInt = #line) throws -> WriteResult {
        var everythingState = 0
        var singleState = 0
        var multiState = 0
        var err: Error? = nil
        var result: WriteResult? = nil

        do {
            let r = try pwm.triggerAppropriateWriteOperation(singleWriteOperation: { (buf, addr, len) in
                defer {
                    singleState += 1
                    everythingState += 1
                }
                if let expected = expectedSingleWritabilities {
                    if expected.count > singleState {
                        XCTAssertGreaterThan(returns.count, everythingState)
                        XCTAssertEqual(expected[singleState].0, buf.count, "in single write \(singleState) (overall \(everythingState)), \(expected[singleState].0) bytes expected but \(buf.count) actual", file: file, line: line)
                        XCTAssertEqual(expected[singleState].1, SocketAddress(addr), "in single write \(singleState) (overall \(everythingState)), \(expected[singleState].1) address expected but \(SocketAddress(addr)) received", file: file, line: line)
                        XCTAssertEqual(expected[singleState].1.expectedSize, len, "in single write \(singleState) (overall \(everythingState)), \(expected[singleState].1.expectedSize) socklen expected but \(len) received", file: file, line: line)

                        switch returns[everythingState] {
                        case .ok(let r):
                            return r
                        case .error(let e):
                            throw e
                        }
                    } else {
                        XCTFail("single write call \(singleState) but less than \(expected.count) expected", file: file, line: line)
                        return IOResult.wouldBlock(-1 * (everythingState + 1))
                    }
                } else {
                    XCTFail("single write called on \(buf) but no single writes expected", file: file, line: line)
                    return IOResult.wouldBlock(-1 * (everythingState + 1))
                }
            }, vectorWriteOperation: { ptrs in
                defer {
                    multiState += 1
                    everythingState += 1
                }
                if let expected = expectedVectorWritabilities {
                    if expected.count > multiState {
                        XCTAssertGreaterThan(returns.count, everythingState)
                        XCTAssertEqual(ptrs.map { $0.msg_hdr.msg_iovlen }, Array(repeating: 1, count: ptrs.count), "mustn't write more than one iovec element per datagram", file: file, line: line)
                        XCTAssertEqual(expected[multiState].map { $0.0 }, ptrs.map { $0.msg_hdr.msg_iov.pointee.iov_len },
                                       "in vector write \(multiState) (overall \(everythingState)), \(expected[multiState]) byte counts expected but \(ptrs.map { $0.msg_hdr.msg_iov.pointee.iov_len }) actual",
                                       file: file, line: line)
                        XCTAssertEqual(expected[multiState].map { $0.0 }, ptrs.map { Int($0.msg_len) },
                                       "in vector write \(multiState) (overall \(everythingState)), \(expected[multiState]) byte counts expected but \(ptrs.map { $0.msg_len }) actual",
                            file: file, line: line)
                        XCTAssertEqual(expected[multiState].map { $0.1 }, ptrs.map { SocketAddress($0.msg_hdr.msg_name.assumingMemoryBound(to: sockaddr.self)) }, "in vector write \(multiState) (overall \(everythingState)), \(expected[multiState].map { $0.1 }) addresses expected but \(ptrs.map { SocketAddress($0.msg_hdr.msg_name.assumingMemoryBound(to: sockaddr.self)) }) actual",
                            file: file, line: line)
                        XCTAssertEqual(expected[multiState].map { $0.1.expectedSize }, ptrs.map { $0.msg_hdr.msg_namelen }, "in vector write \(multiState) (overall \(everythingState)), \(expected[multiState].map { $0.1.expectedSize }) address lengths expected but \(ptrs.map { $0.msg_hdr.msg_namelen }) actual",
                            file:file, line: line)

                        switch returns[everythingState] {
                        case .ok(let r):
                            return r
                        case .error(let e):
                            throw e
                        }
                    } else {
                        XCTFail("vector write call \(multiState) but less than \(expected.count) expected", file: file, line: line)
                        return IOResult.wouldBlock(-1 * (everythingState + 1))
                    }
                } else {
                    XCTFail("vector write called on \(ptrs) but no vector writes expected",
                        file: file, line: line)
                    return IOResult.wouldBlock(-1 * (everythingState + 1))
                }
            })
            result = r.writeResult
        } catch {
            err = error
        }

        if everythingState > 0 {
            XCTAssertEqual(promises.count, promiseStates[everythingState - 1].count,
                           "number of promises (\(promises.count)) != number of promise states (\(promiseStates[everythingState - 1].count))",
                file: file, line: line)
            _ = zip(promises, promiseStates[everythingState - 1]).map { p, pState in
                XCTAssertEqual(p.futureResult.fulfilled, pState, "promise states incorrect (\(everythingState) callbacks)", file: file, line: line)
            }

            XCTAssertEqual(everythingState, singleState + multiState,
                           "odd, calls the single/vector writes: \(singleState)/\(multiState)/ but overall \(everythingState+1)", file: file, line: line)

            if singleState == 0 {
                XCTAssertNil(expectedSingleWritabilities, "no single writes have been done but we expected some", file: file, line: line)
            } else {
                XCTAssertEqual(singleState, (expectedSingleWritabilities?.count ?? Int.min), "different number of single writes than expected", file: file, line: line)
            }
            if multiState == 0 {
                XCTAssertNil(expectedVectorWritabilities, "no vector writes have been done but we expected some")
            } else {
                XCTAssertEqual(multiState, (expectedVectorWritabilities?.count ?? Int.min), "different number of vector writes than expected", file: file, line: line)
            }
        } else {
            XCTAssertEqual(0, returns.count, "no callbacks called but apparently \(returns.count) expected", file: file, line: line)
            XCTAssertNil(expectedSingleWritabilities, "no callbacks called but apparently some single writes expected", file: file, line: line)
            XCTAssertNil(expectedVectorWritabilities, "no callbacks calles but apparently some vector writes expected", file: file, line: line)

            _ = zip(promises, promiseStates[0]).map { p, pState in
                XCTAssertEqual(p.futureResult.fulfilled, pState, "promise states incorrect (no callbacks)", file: file, line: line)
            }
        }

        if let error = err {
            throw error
        }
        return result!
    }

    /// Tests that writes of empty buffers work correctly and that we don't accidentally write buffers that haven't been flushed.
    func testPendingWritesEmptyWritesWorkAndWeDontWriteUnflushedThings() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 65535)
        var buffer = alloc.buffer(capacity: 12)

        try withPendingDatagramWritesManager { pwm in
            buffer.clear()
            let ps: [EventLoopPromise<()>] = (0..<2).map { _ in el.newPromise() }
            _ = pwm.add(envelope: AddressedEnvelope(remoteAddress: address, data: buffer), promise: ps[0])

            XCTAssertFalse(pwm.isEmpty)
            XCTAssertFalse(pwm.isFlushPending)

            pwm.markFlushCheckpoint(promise: nil)

            XCTAssertFalse(pwm.isEmpty)
            XCTAssertTrue(pwm.isFlushPending)

            _ = pwm.add(envelope: AddressedEnvelope(remoteAddress: address, data: buffer), promise: ps[1])

            var result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                       promises: ps,
                                                       expectedSingleWritabilities: [(0, address)],
                                                       expectedVectorWritabilities: nil,
                                                       returns: [.ok(.processed(0))],
                                                       promiseStates: [[true, false]])

            XCTAssertFalse(pwm.isEmpty)
            XCTAssertFalse(pwm.isFlushPending)
            XCTAssertEqual(.writtenCompletely, result)

            result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: nil,
                                                   expectedVectorWritabilities: nil,
                                                   returns: [],
                                                   promiseStates: [[true, false]])
            XCTAssertEqual(WriteResult.nothingToBeWritten, result)

            pwm.markFlushCheckpoint(promise: nil)

            result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: [(0, address)],
                                                   expectedVectorWritabilities: nil,
                                                   returns: [.ok(.processed(0))],
                                                   promiseStates: [[true, true]])
            XCTAssertEqual(WriteResult.writtenCompletely, result)
        }
    }

    /// This tests that we do use the vector write operation if we have more than one flushed and still doesn't write unflushed buffers
    func testPendingWritesUsesVectorWriteOperationAndDoesntWriteTooMuch() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        let firstAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 65535)
        let secondAddress = try SocketAddress(ipAddress: "127.0.0.2", port: 65535)
        var buffer = alloc.buffer(capacity: 12)
        let emptyBuffer = buffer
        _ = buffer.write(string: "1234")

        try withPendingDatagramWritesManager { pwm in
            let ps: [EventLoopPromise<()>] = (0..<3).map { _ in el.newPromise() }
            _ = pwm.add(envelope: AddressedEnvelope(remoteAddress: firstAddress, data: buffer), promise: ps[0])
            _ = pwm.add(envelope: AddressedEnvelope(remoteAddress: secondAddress, data: buffer), promise: ps[1])
            pwm.markFlushCheckpoint(promise: nil)
            _ = pwm.add(envelope: AddressedEnvelope(remoteAddress: firstAddress, data: emptyBuffer), promise: ps[2])

            var result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                       promises: ps,
                                                       expectedSingleWritabilities: nil,
                                                       expectedVectorWritabilities: [[(4, firstAddress), (4, secondAddress)]],
                                                       returns: [.ok(.processed(2))],
                                                       promiseStates: [[true, true, false]])
            XCTAssertEqual(WriteResult.writtenCompletely, result)

            pwm.markFlushCheckpoint(promise: nil)

            result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: [(0, firstAddress)],
                                                   expectedVectorWritabilities: nil,
                                                   returns: [.ok(.processed(0))],
                                                   promiseStates: [[true, true, true]])
            XCTAssertEqual(WriteResult.writtenCompletely, result)
        }
    }

    /// Tests that we can handle partial writes correctly.
    func testPendingWritesWorkWithPartialWrites() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        let firstAddress = try SocketAddress(ipAddress: "fe80::1", port: 65535)
        let secondAddress = try SocketAddress(ipAddress: "fe80::2", port: 65535)
        var buffer = alloc.buffer(capacity: 12)
        _ = buffer.write(string: "1234")

        try withPendingDatagramWritesManager { pwm in
            let ps: [EventLoopPromise<()>] = (0..<4).map { _ in el.newPromise() }
            _ = pwm.add(envelope: AddressedEnvelope(remoteAddress: firstAddress, data: buffer), promise: ps[0])
            _ = pwm.add(envelope: AddressedEnvelope(remoteAddress: secondAddress, data: buffer), promise: ps[1])
            _ = pwm.add(envelope: AddressedEnvelope(remoteAddress: firstAddress, data: buffer), promise: ps[2])
            _ = pwm.add(envelope: AddressedEnvelope(remoteAddress: secondAddress, data: buffer), promise: ps[3])
            pwm.markFlushCheckpoint(promise: nil)

            var result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                       promises: ps,
                                                       expectedSingleWritabilities: nil,
                                                       expectedVectorWritabilities: [
                                                            [(4, firstAddress), (4, secondAddress), (4, firstAddress), (4, secondAddress)],
                                                            [(4, secondAddress), (4, firstAddress), (4, secondAddress)]
                                                       ],
                                                       returns: [.ok(.processed(1)), .ok(.wouldBlock(0))],
                                                       promiseStates: [[true, false, false, false], [true, false, false, false]])

            XCTAssertEqual(WriteResult.wouldBlock, result)
            result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: nil,
                                                   expectedVectorWritabilities: [
                                                        [(4, secondAddress), (4, firstAddress), (4, secondAddress)],
                                                        [(4, secondAddress)],
                                                   ],
                                                   returns: [.ok(.processed(2)), .ok(.wouldBlock(0))],
                                                   promiseStates: [[true, true, true, false], [true, true, true, false]]

            )
            XCTAssertEqual(WriteResult.wouldBlock, result)

            result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: [(4, secondAddress)],
                                                   expectedVectorWritabilities: nil,
                                                   returns: [.ok(.processed(4))],
                                                   promiseStates: [[true, true, true, true]])
            XCTAssertEqual(WriteResult.writtenCompletely, result)
        }
    }

    /// Tests that the spin count works for many buffers if each is written one by one.
    func testPendingWritesSpinCountWorksForSingleWrites() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 65535)
        var buffer = alloc.buffer(capacity: 12)
        buffer.write(bytes: Array<UInt8>(repeating: 0xff, count: 12))

        try withPendingDatagramWritesManager { pwm in
            let ps: [EventLoopPromise<()>] = (0...pwm.writeSpinCount).map { _ in el.newPromise() }
            ps.forEach { _ = pwm.add(envelope: AddressedEnvelope(remoteAddress: address, data: buffer), promise: $0) }
            let maxVectorWritabilities = ps.map { _ in (buffer.readableBytes, address) }
            let actualVectorWritabilities = maxVectorWritabilities.indices.dropLast().map { Array(maxVectorWritabilities[$0...]) }
            let actualPromiseStates = ps.indices.dropFirst().map { Array(repeating: true, count: $0) + Array(repeating: false, count: ps.count - $0) }

            pwm.markFlushCheckpoint(promise: nil)

            /* below, we'll write 1 datagram at a time. So the number of datagrams offered should decrease by one.
             The write operation should be repeated until we did it 1 + spin count times and then return `.writtenPartially`.
             After that, one datagram will remain */
            var result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                       promises: ps,
                                                       expectedSingleWritabilities: nil,
                                                       expectedVectorWritabilities: actualVectorWritabilities,
                                                       returns: Array(repeating: .ok(.processed(1)), count: ps.count - 1),
                                                       promiseStates: actualPromiseStates)
            XCTAssertEqual(.writtenPartially, result)

            /* we'll now write the one last datagram and assert that all the writes are complete */
            result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: [(12, address)],
                                                   expectedVectorWritabilities: nil,
                                                   returns: [.ok(.processed(12))],
                                                   promiseStates: [Array(repeating: true, count: ps.count - 1) + [true]])
            XCTAssertEqual(.writtenCompletely, result)
        }
    }

    /// Test that cancellation of the Channel writes works correctly.
    func testPendingWritesCancellationWorksCorrectly() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 65535)
        var buffer = alloc.buffer(capacity: 12)
        _ = buffer.write(string: "1234")

        try withPendingDatagramWritesManager { pwm in
            let ps: [EventLoopPromise<()>] = (0..<3).map { _ in el.newPromise() }
            _ = pwm.add(envelope: AddressedEnvelope(remoteAddress: address, data: buffer), promise: ps[0])
            _ = pwm.add(envelope: AddressedEnvelope(remoteAddress: address, data: buffer), promise: ps[1])
            pwm.markFlushCheckpoint(promise: nil)
            _ = pwm.add(envelope: AddressedEnvelope(remoteAddress: address, data: buffer), promise: ps[2])

            let result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                       promises: ps,
                                                       expectedSingleWritabilities: nil,
                                                       expectedVectorWritabilities: [[(4, address), (4, address)]],
                                                       returns: [.ok(.wouldBlock(0))],
                                                       promiseStates: [[false, false, false], [false, false, false]])
            XCTAssertEqual(WriteResult.wouldBlock, result)

            pwm.failAll(error: ChannelError.operationUnsupported, close: true)

            XCTAssertTrue(ps.map { $0.futureResult.fulfilled }.reduce(true) { $0 && $1 })
        }
    }

    /// Test that with a few massive buffers, we don't offer more than we should to `writev` if the individual chunks fit.
    func testPendingWritesNoMoreThanWritevLimitIsWritten() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator(hookedMalloc: { _ in return UnsafeMutableRawPointer(bitPattern: 0xdeadbeef)! },
                                        hookedRealloc: { _, _ in return UnsafeMutableRawPointer(bitPattern: 0xdeadbeef)! },
                                        hookedFree: { _ in },
                                        hookedMemcpy: { _, _, _ in })
        /* each buffer is half the writev limit */
        let halfTheWriteVLimit = Socket.writevLimitBytes / 2
        var buffer = alloc.buffer(capacity: halfTheWriteVLimit)
        buffer.moveReaderIndex(to: 0)
        buffer.moveWriterIndex(to: halfTheWriteVLimit)
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 65535)

        try withPendingDatagramWritesManager { pwm in
            let ps: [EventLoopPromise<()>] = (0..<3).map { _ in el.newPromise() }
            /* add 1.5x the writev limit */
            _ = pwm.add(envelope: AddressedEnvelope(remoteAddress: address, data: buffer), promise: ps[0])
            _ = pwm.add(envelope: AddressedEnvelope(remoteAddress: address, data: buffer), promise: ps[1])
            _ = pwm.add(envelope: AddressedEnvelope(remoteAddress: address, data: buffer), promise: ps[2])
            pwm.markFlushCheckpoint(promise: nil)

            let result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                       promises: ps,
                                                       expectedSingleWritabilities: nil,
                                                       expectedVectorWritabilities: [[(halfTheWriteVLimit, address), (halfTheWriteVLimit, address)], [(halfTheWriteVLimit, address)]],
                                                       returns: [.ok(.processed(2)), .ok(.processed(1))],
                                                       promiseStates: [[true, true, false], [true, true, true]])
            XCTAssertEqual(WriteResult.writtenCompletely, result)
        }
    }

    /// Test that with a massive buffers (bigger than writev size), we fall back to linear processing.
    func testPendingWritesNoMoreThanWritevLimitIsWrittenInOneMassiveChunk() throws {
        let el = EmbeddedEventLoop()
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 65535)
        let alloc = ByteBufferAllocator(hookedMalloc: { _ in return UnsafeMutableRawPointer(bitPattern: 0xdeadbeef)! },
                                        hookedRealloc: { _, _ in return UnsafeMutableRawPointer(bitPattern: 0xdeadbeef)! },
                                        hookedFree: { _ in },
                                        hookedMemcpy: { _, _, _ in })
        /* each buffer is half the writev limit */
        let biggerThanWriteV = Socket.writevLimitBytes + 23
        var buffer = alloc.buffer(capacity: biggerThanWriteV)
        buffer.moveReaderIndex(to: 0)
        buffer.moveWriterIndex(to: biggerThanWriteV)

        try withPendingDatagramWritesManager { pwm in
            let ps: [EventLoopPromise<()>] = (0..<3).map { _ in el.newPromise() }
            /* add 1.5x the writev limit */
            _ = pwm.add(envelope: AddressedEnvelope(remoteAddress: address, data: buffer), promise: ps[0])
            buffer.moveReaderIndex(to: 100)
            _ = pwm.add(envelope: AddressedEnvelope(remoteAddress: address, data: buffer), promise: ps[1])
            _ = pwm.add(envelope: AddressedEnvelope(remoteAddress: address, data: buffer), promise: ps[2])

            let flushPromise1: EventLoopPromise<()> = el.newPromise()
            pwm.markFlushCheckpoint(promise: flushPromise1)

            let result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                       promises: ps,
                                                       expectedSingleWritabilities: [
                                                            (Socket.writevLimitBytes + 23, address),
                                                            (Socket.writevLimitBytes - 77, address),
                                                            (Socket.writevLimitBytes - 77, address)],
                                                       expectedVectorWritabilities: nil,
                                                       returns: [
                                                            .error(IOError(errnoCode: EMSGSIZE, reason: "")),
                                                            .ok(.processed(Socket.writevLimitBytes - 77)),
                                                            .ok(.processed(Socket.writevLimitBytes - 77))],
                                                       promiseStates: [[true, false, false], [true, true, false], [true, true, true]])

            XCTAssertEqual(WriteResult.writtenCompletely, result)
            XCTAssertTrue(flushPromise1.futureResult.fulfilled)

            XCTAssertNoThrow(try ps[1].futureResult.wait())
            XCTAssertNoThrow(try ps[2].futureResult.wait())

            do {
                try ps[0].futureResult.wait()
                XCTFail("Did not throw")
            } catch ChannelError.writeMessageTooLarge {
                // Ok
            } catch {
                XCTFail("Unexpected error \(error)")
            }

            do {
                try flushPromise1.futureResult.wait()
                XCTFail("Did not throw")
            } catch let e as NIOCompositeError {
                XCTAssertEqual(e.count, 1)
                XCTAssertEqual(e[0] as? ChannelError, ChannelError.writeMessageTooLarge)
            } catch {
                XCTFail("Unexpected error \(error)")
            }
        }
    }

    func testPendingWritesFlushPromiseWorksWithoutWritePromises() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        let address = try SocketAddress(ipAddress: "fe80::1", port: 80)
        var buffer = alloc.buffer(capacity: 12)
        _ = buffer.write(string: "1234")

        try withPendingDatagramWritesManager { pwm in
            let ps: [EventLoopPromise<()>] = (0..<2).map { _ in el.newPromise() }

            pwm.markFlushCheckpoint(promise: ps[0])

            /* let's start with no writes and just a promise */
            var result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                       promises: ps,
                                                       expectedSingleWritabilities: nil,
                                                       expectedVectorWritabilities: nil,
                                                       returns: [],
                                                       promiseStates: [[true, false]])

            /* let's add a few writes but still without any promises */
            _ = pwm.add(envelope: AddressedEnvelope(remoteAddress: address, data: buffer), promise: nil)
            _ = pwm.add(envelope: AddressedEnvelope(remoteAddress: address, data: buffer), promise: nil)
            _ = pwm.add(envelope: AddressedEnvelope(remoteAddress: address, data: buffer), promise: nil)

            pwm.markFlushCheckpoint(promise: ps[1])

            result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: nil,
                                                   expectedVectorWritabilities: [[(4, address), (4, address), (4, address)]],
                                                   returns: [.ok(.processed(3))],
                                                   promiseStates: [[true, true]])
            XCTAssertEqual(WriteResult.writtenCompletely, result)
        }
    }

    func testPendingWritesWorksWithManyEmptyWrites() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        let emptyBuffer = alloc.buffer(capacity: 12)
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 80)

        try withPendingDatagramWritesManager { pwm in
            let ps: [EventLoopPromise<()>] = (0..<3).map { _ in el.newPromise() }
            _ = pwm.add(envelope: AddressedEnvelope(remoteAddress: address, data: emptyBuffer), promise: ps[0])
            _ = pwm.add(envelope: AddressedEnvelope(remoteAddress: address, data: emptyBuffer), promise: ps[1])
            pwm.markFlushCheckpoint(promise: nil)
            _ = pwm.add(envelope: AddressedEnvelope(remoteAddress: address, data: emptyBuffer), promise: ps[2])

            var result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                       promises: ps,
                                                       expectedSingleWritabilities: nil,
                                                       expectedVectorWritabilities: [[(0, address), (0, address)]],
                                                       returns: [.ok(.processed(2))],
                                                       promiseStates: [[true, true, false]])
            XCTAssertEqual(WriteResult.writtenCompletely, result)

            pwm.markFlushCheckpoint(promise: nil)

            result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: [(0, address)],
                                                   expectedVectorWritabilities: nil,
                                                   returns: [.ok(.processed(0))],
                                                   promiseStates: [[true, true, true]])
            XCTAssertEqual(WriteResult.writtenCompletely, result)
        }
    }

    func testPendingWritesCloseDuringVectorWrite() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 80)
        var buffer = alloc.buffer(capacity: 12)
        buffer.write(string: "1234")

        try withPendingDatagramWritesManager { pwm in
            let ps: [EventLoopPromise<()>] = (0..<3).map { _ in el.newPromise() }
            _ = pwm.add(envelope: AddressedEnvelope(remoteAddress: address, data: buffer), promise: ps[0])
            _ = pwm.add(envelope: AddressedEnvelope(remoteAddress: address, data: buffer), promise: ps[1])
            pwm.markFlushCheckpoint(promise: nil)
            _ = pwm.add(envelope: AddressedEnvelope(remoteAddress: address, data: buffer), promise: ps[2])

            ps[0].futureResult.whenComplete { _ in
                pwm.failAll(error: ChannelError.inputClosed, close: true)
            }

            let result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                       promises: ps,
                                                       expectedSingleWritabilities: nil,
                                                       expectedVectorWritabilities: [[(4, address), (4, address)]],
                                                       returns: [.ok(.processed(1))],
                                                       promiseStates: [[true, true, true]])
            XCTAssertEqual(WriteResult.closed, result)
            XCTAssertNoThrow(try ps[0].futureResult.wait())
            XCTAssertThrowsError(try ps[1].futureResult.wait())
            XCTAssertThrowsError(try ps[2].futureResult.wait())
        }
    }

    func testPendingWritesMoreThanWritevIOVectorLimit() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 80)
        var buffer = alloc.buffer(capacity: 12)
        buffer.write(string: "1234")

        try withPendingDatagramWritesManager { pwm in
            let ps: [EventLoopPromise<()>] = (0...Socket.writevLimitIOVectors).map { _ in el.newPromise() }
            ps.forEach { p in
                _ = pwm.add(envelope: AddressedEnvelope(remoteAddress: address, data: buffer), promise: p)
            }
            let flushPromise: EventLoopPromise<()> = el.newPromise()
            pwm.markFlushCheckpoint(promise: flushPromise)

            var result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                       promises: ps,
                                                       expectedSingleWritabilities: nil,
                                                       expectedVectorWritabilities: [Array(repeating: (4, address), count: Socket.writevLimitIOVectors), [(4, address)]],
                                                       returns: [.ok(.processed(Socket.writevLimitIOVectors)), .ok(.wouldBlock(0))],
                                                       promiseStates: [Array(repeating: true, count: Socket.writevLimitIOVectors) + [false],
                                                                       Array(repeating: true, count: Socket.writevLimitIOVectors) + [false]])
            XCTAssertEqual(WriteResult.wouldBlock, result)
            XCTAssertFalse(flushPromise.futureResult.fulfilled)
            result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: [(4, address)],
                                                   expectedVectorWritabilities: nil,
                                                   returns: [.ok(.processed(4))],
                                                   promiseStates: [Array(repeating: true, count: Socket.writevLimitIOVectors + 1)])
            XCTAssertEqual(WriteResult.writtenCompletely, result)
            XCTAssertTrue(flushPromise.futureResult.fulfilled)
        }
    }
}