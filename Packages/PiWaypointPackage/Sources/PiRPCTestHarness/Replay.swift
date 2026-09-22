//
//  Replay.swift
//  PiWaypointPackage
//
//  Created by Tomasz Kubiak on 23/09/2026.
//

import Foundation

actor Replay {
    private struct Entry: Decodable {
        enum Direction: String, Decodable {
            case `in`, out
        }
        
        let direction: Direction
        let raw: String
    }
    
    private let fixtureURL: URL
    private let pacing: RecordedPiTransport.ReplayPacing
    
    private var entries: [Entry]?
    private var cursor = 0
    private var manualPermits = 0
    private var pendingStdin = Data()
    private var continuation: AsyncThrowingStream<Data, any Error>.Continuation?
    private var stream: AsyncThrowingStream<Data, any Error>?
    private var timer: Task<Void, Never>?
    private var stopped = false
    private var failure: RecordedPiTransportError?
    
    init(fixtureURL: URL, pacing: RecordedPiTransport.ReplayPacing) {
        self.fixtureURL = fixtureURL
        self.pacing = pacing
    }
    
    func stdout() -> AsyncThrowingStream<Data, any Error> {
        if let stream { return stream }
        
        var source: AsyncThrowingStream<Data, any Error>.Continuation!
        let newStream = AsyncThrowingStream<Data, any Error> { source = $0 }
        stream = newStream
        continuation = source
        source.onTermination = { @Sendable [weak self] termination in
            if case .cancelled = termination {
                Task { await self?.close() }
            }
        }
        
        if let failure {
            source.finish(throwing: failure)
        } else if stopped {
            source.finish()
        } else {
            do {
                try loadIfNeeded()
                drain()
            } catch let error as RecordedPiTransportError {
                fail(error)
            } catch {
                fail(.fixtureReadFailed(String(describing: error)))
            }
        }
        
        return newStream
    }
    
    func writeStdin(_ data: Data) throws {
        if let failure { throw failure }
        guard !stopped else { throw RecordedPiTransportError.closed }
        do {
            try loadIfNeeded()
            pendingStdin.append(data)
            
            while let newline = pendingStdin.firstIndex(of: 0x0A) {
                let line = Data(pendingStdin[..<newline])
                pendingStdin.removeSubrange(...newline)
                let actual = String(decoding: line, as: UTF8.self)
                
                guard let entries, cursor < entries.count,
                      entries[cursor].direction == .out else {
                    throw RecordedPiTransportError.unexpectedStdin(actual)
                }
                
                let expected = entries[cursor].raw
                guard line == Data(expected.utf8) else {
                    throw RecordedPiTransportError.stdinMismatch(
                        expected: expected,
                        actual: actual
                    )
                }
                
                cursor += 1
                drain()
            }
            
        } catch let error as RecordedPiTransportError {
            fail(error)
            throw error
        } catch {
            let wrapped = RecordedPiTransportError.fixtureReadFailed(String(describing: error))
            fail(wrapped)
            throw wrapped
        }
    }
    
    func emitNext() throws {
        if let failure { throw failure }
        guard !stopped else { throw RecordedPiTransportError.closed }
        guard case .manual = pacing else {
            throw RecordedPiTransportError.invalidPacing
        }
        
        do {
            try loadIfNeeded()
            guard let entries, cursor < entries.count else {
                throw RecordedPiTransportError.incompleteFixture(
                    remaining: 0, bufferedStdinBytes: pendingStdin.count
                )
            }
            guard entries[cursor].direction == .in else {
                throw RecordedPiTransportError.waitingForStdin(entries[cursor].raw)
            }
            manualPermits += 1
            drain()
        } catch let error as RecordedPiTransportError {
            // A test calling emitNext too early can still recover by writing
            // the expected command. Only fixture/load errors are terminal.
            if case .invalidFixture = error { fail(error) }
            if case .fixtureReadFailed = error { fail(error) }
            throw error
        } catch {
            let wrapped = RecordedPiTransportError
                .fixtureReadFailed(String(describing: error))
            fail(wrapped)
            throw wrapped
        }
    }
    
    func assertComplete() throws {
        if let failure { throw failure }
        try loadIfNeeded()
        let remaining = (entries?.count ?? 0) - cursor
        guard remaining == 0, pendingStdin.isEmpty else {
            throw RecordedPiTransportError.incompleteFixture(
                remaining: remaining, bufferedStdinBytes: pendingStdin.count
            )
        }
    }
    
    func close() {
        guard !stopped else { return }
        stopped = true
        timer?.cancel()
        timer = nil
        continuation?.finish()
    }
    
    private func loadIfNeeded() throws {
        guard entries == nil else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fixtureURL)
        } catch {
            throw RecordedPiTransportError.fixtureReadFailed(String(describing: error))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw RecordedPiTransportError.invalidFixture("File must be UTF-8")
        }
        var loaded: [Entry] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (offset, slice) in lines.enumerated() {
            // One empty last line is the usual NDJSON trailing newline.
            if offset == lines.count - 1, slice.isEmpty { break }
            let line = slice.hasSuffix("\r") ? slice.dropLast() : slice[...]
            do {
                loaded.append(try JSONDecoder().decode(Entry.self, from: Data(line.utf8)))
            } catch {
                throw RecordedPiTransportError.invalidFixture("line \(offset + 1): \(error)")
            }
        }
        entries = loaded
    }
    
    private func drain() {
        guard !stopped, let entries, let continuation else { return }
        
        while cursor < entries.count {
            let entry = entries[cursor]
            guard entry.direction == .in else { return }
            switch pacing {
            case .immediate: break
            case .manual:
                guard manualPermits > 0 else { return }
                manualPermits -= 1
            case .fixedInterval(let interval):
                guard timer == nil else { return }
                timer = Task { [weak self] in
                    do {
                        try await Task.sleep(for: interval)
                        await self?.timerFired()
                    } catch { /* close() cancels the pending timer */ }
                }
                return
            }
            
            var bytes = Data(entry.raw.utf8)
            bytes.append(0x0A)
            continuation.yield(bytes)
            cursor += 1
        }
        stopped = true
        continuation.finish()
    }
    
    private func timerFired() {
        timer = nil
        guard !stopped, let entries, cursor < entries.count,
              entries[cursor].direction == .in else { return }
        var bytes = Data(entries[cursor].raw.utf8)
        bytes.append(0x0A)
        continuation?.yield(bytes)
        cursor += 1
        drain()
    }
    
    private func fail(_ error: RecordedPiTransportError) {
        guard failure == nil else { return }
        failure = error
        stopped = true
        timer?.cancel()
        timer = nil
        continuation?.finish(throwing: error)
    }
}
