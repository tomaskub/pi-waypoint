import Foundation
import Testing
@testable import PiRPCTestHarness

// Byte-for-byte copies from pi-rpc-corpus/20260922T205510Z-786514c8/
// scenarios/15-unknown-command. stdin.jsonl and stdout.jsonl are independent
// captures used to check replay.ndjson.
private enum CorpusFixture {
    static func url(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: "unknown-command.\(name)", withExtension: "jsonl"))
    }

    static var replayURL: URL {
        get throws {
            try #require(Bundle.module.url(
                forResource: "unknown-command.replay",
                withExtension: "ndjson"
            ))
        }
    }

    static func lines(_ url: URL) throws -> [Data] {
        try Data(contentsOf: url).split(separator: 0x0A).map { slice in
            var line = Data(slice)
            line.append(0x0A)
            return line
        }
    }
}

private func recordedError(
    _ operation: () async throws -> Void
) async -> RecordedPiTransportError? {
    do {
        try await operation()
        Issue.record("Expected a replay error")
        return nil
    } catch let error as RecordedPiTransportError {
        return error
    } catch {
        Issue.record("Unexpected error: \(error)")
        return nil
    }
}

private func temporaryFixture(_ contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-rpc-replay-\(UUID().uuidString).ndjson")
    try Data(contents.utf8).write(to: url)
    return url
}

@Test(.timeLimit(.minutes(1)))
func replaysRealCorpusBytesInOrder() async throws {
    let commands = try CorpusFixture.lines(CorpusFixture.url("stdin"))
    let expected = try CorpusFixture.lines(CorpusFixture.url("stdout"))
    let transport = RecordedPiTransport(fixtureURL: try CorpusFixture.replayURL)

    let stream = await transport.stdout()
    for command in commands {
        try await transport.writeStdin(command)
    }
    try await transport.assertComplete()

    var actual: [Data] = []
    for try await line in stream {
        actual.append(line)
    }
    #expect(actual == expected)
    try #require(actual.count == 5)
    #expect(String(decoding: actual[1], as: UTF8.self).contains("Unknown command:"))
}

@Test(.timeLimit(.minutes(1)))
func manualReplayWaitsForCommandsAndPermits() async throws {
    let commands = try CorpusFixture.lines(CorpusFixture.url("stdin"))
    let expected = try CorpusFixture.lines(CorpusFixture.url("stdout"))
    let transport = RecordedPiTransport(
        fixtureURL: try CorpusFixture.replayURL,
        pacing: .manual
    )
    let stream = await transport.stdout()

    guard case .some(.waitingForStdin(let first)) = await recordedError({
        try await transport.emitNext()
    }) else { return }
    #expect(Data(first.utf8) == Data(commands[0].dropLast()))

    let split = commands[0].count / 2
    try await transport.writeStdin(Data(commands[0].prefix(split)))
    guard case .some(.incompleteFixture(let remaining, let buffered)) = await recordedError({
        try await transport.assertComplete()
    }) else { return }
    #expect(remaining == 9)
    #expect(buffered == split)

    try await transport.writeStdin(Data(commands[0].dropFirst(split)))
    guard case .some(.incompleteFixture(let waitingForPermit, 0)) = await recordedError({
        try await transport.assertComplete()
    }) else { return }
    #expect(waitingForPermit == 8)

    try await transport.emitNext()
    guard case .some(.incompleteFixture(let waitingForSecondPermit, 0)) = await recordedError({
        try await transport.assertComplete()
    }) else { return }
    #expect(waitingForSecondPermit == 7)
    try await transport.emitNext()

    guard case .some(.waitingForStdin) = await recordedError({
        try await transport.emitNext()
    }) else { return }

    for command in commands.dropFirst() {
        try await transport.writeStdin(command)
        try await transport.emitNext()
    }
    try await transport.assertComplete()

    var actual: [Data] = []
    for try await line in stream {
        actual.append(line)
    }
    #expect(actual == expected)
}

@Test(.timeLimit(.minutes(1)))
func mismatchFailsTheStreamAndFutureWrites() async throws {
    let transport = RecordedPiTransport(fixtureURL: try CorpusFixture.replayURL)
    let stream = await transport.stdout()
    let wrong = Data(
        "{\"type\":\"definitely_not_a_real_pi_rpc_command\",\"id\":\"15-unknown-command-req-1\"}\n".utf8
    )

    guard case .some(.stdinMismatch(let expected, let actual)) = await recordedError({
        try await transport.writeStdin(wrong)
    }) else { return }
    #expect(expected.contains("15-unknown-command-req-1"))
    #expect(actual == String(decoding: wrong.dropLast(), as: UTF8.self))

    guard case .some(.stdinMismatch) = await recordedError({
        try await transport.writeStdin(wrong)
    }) else { return }
    guard case .some(.stdinMismatch) = await recordedError({
        try await transport.assertComplete()
    }) else { return }

    do {
        for try await _ in stream {}
        Issue.record("Expected the output stream to fail")
    } catch let error as RecordedPiTransportError {
        guard case .stdinMismatch = error else {
            Issue.record("Unexpected stream error: \(error)")
            return
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func acceptsBatchedCommandsAndReportsUnexpectedInput() async throws {
    let commands = try CorpusFixture.lines(CorpusFixture.url("stdin"))
    let expected = try CorpusFixture.lines(CorpusFixture.url("stdout"))
    let transport = RecordedPiTransport(fixtureURL: try CorpusFixture.replayURL)
    let stream = await transport.stdout()

    try await transport.writeStdin(commands.reduce(into: Data()) { $0.append($1) })
    try await transport.assertComplete()
    var emitted: [Data] = []
    for try await line in stream { emitted.append(line) }
    #expect(emitted == expected)

    // Without a reader, a second line arrives while the next fixture entry is inbound.
    let unstarted = RecordedPiTransport(fixtureURL: try CorpusFixture.replayURL)
    var tooEarly = commands[0]
    tooEarly.append(commands[1])
    guard case .some(.unexpectedStdin(let actual)) = await recordedError({
        try await unstarted.writeStdin(tooEarly)
    }) else { return }
    #expect(Data(actual.utf8) == Data(commands[1].dropLast()))

    do {
        for try await _ in await unstarted.stdout() {}
        Issue.record("Expected the output stream to fail")
    } catch let error as RecordedPiTransportError {
        guard case .unexpectedStdin = error else {
            Issue.record("Unexpected stream error: \(error)")
            return
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func startsOutputAfterTheFirstCommandWasWritten() async throws {
    let commands = try CorpusFixture.lines(CorpusFixture.url("stdin"))
    let expected = try CorpusFixture.lines(CorpusFixture.url("stdout"))
    let transport = RecordedPiTransport(fixtureURL: try CorpusFixture.replayURL)

    try await transport.writeStdin(commands[0])
    let stream = await transport.stdout()
    for command in commands.dropFirst() {
        try await transport.writeStdin(command)
    }
    var actual: [Data] = []
    for try await line in stream { actual.append(line) }
    #expect(actual == expected)
    try await transport.assertComplete()
}

@Test(.timeLimit(.minutes(1)))
func rejectsInvalidAndMissingFixtures() async throws {
    let invalidURL = try temporaryFixture("{\"direction\":\"in\",\"raw\":\"ok\"}\nnot json\n")
    defer { try? FileManager.default.removeItem(at: invalidURL) }
    let invalid = RecordedPiTransport(fixtureURL: invalidURL)
    guard case .some(.invalidFixture(let reason)) = await recordedError({
        try await invalid.assertComplete()
    }) else { return }
    #expect(reason.contains("line 2"))
    do {
        for try await _ in await invalid.stdout() {}
        Issue.record("Expected the output stream to reject the invalid fixture")
    } catch let error as RecordedPiTransportError {
        guard case .invalidFixture = error else {
            Issue.record("Unexpected stream error: \(error)")
            return
        }
    }

    let missing = RecordedPiTransport(
        fixtureURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).ndjson")
    )
    guard case .some(.fixtureReadFailed) = await recordedError({
        try await missing.assertComplete()
    }) else { return }
}

@Test(.timeLimit(.minutes(1)))
func emitNextRequiresManualPacingAndCloseEndsTheStream() async throws {
    let transport = RecordedPiTransport(fixtureURL: try CorpusFixture.replayURL)
    let stream = await transport.stdout()
    guard case .some(.invalidPacing) = await recordedError({
        try await transport.emitNext()
    }) else { return }

    await transport.close()
    var actual: [Data] = []
    for try await line in stream { actual.append(line) }
    #expect(actual.isEmpty)
    guard case .some(.closed) = await recordedError({
        try await transport.writeStdin(Data("{}\n".utf8))
    }) else { return }
}

@Test(.timeLimit(.minutes(1)))
func handlesCRLFFixtureAndRejectsInvalidUTF8() async throws {
    let replay = #"{"direction":"in","raw":"{\"message\":\"café\"}"}"# + "\r\n"
    let url = try temporaryFixture(replay)
    defer { try? FileManager.default.removeItem(at: url) }
    let transport = RecordedPiTransport(fixtureURL: url)
    var actual: [Data] = []
    for try await line in await transport.stdout() { actual.append(line) }
    #expect(actual == [Data("{\"message\":\"café\"}\n".utf8)])
    try await transport.assertComplete()

    let invalidURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-rpc-invalid-\(UUID().uuidString).ndjson")
    try Data([0xFF]).write(to: invalidURL)
    defer { try? FileManager.default.removeItem(at: invalidURL) }
    let invalid = RecordedPiTransport(fixtureURL: invalidURL)
    guard case .some(.invalidFixture(let reason)) = await recordedError({
        try await invalid.assertComplete()
    }) else { return }
    #expect(reason == "File must be UTF-8")
}

@Test(.timeLimit(.minutes(1)))
func fixedIntervalReplaysAndCloseStopsFurtherInput() async throws {
    let commands = try CorpusFixture.lines(CorpusFixture.url("stdin"))
    let expected = try CorpusFixture.lines(CorpusFixture.url("stdout"))
    let transport = RecordedPiTransport(
        fixtureURL: try CorpusFixture.replayURL,
        pacing: .fixedInterval(.milliseconds(1))
    )
    var iterator = await transport.stdout().makeAsyncIterator()
    var offset = 0
    for (index, command) in commands.enumerated() {
        try await transport.writeStdin(command)
        let count = index == 0 ? 2 : 1
        for _ in 0..<count {
            #expect(try await iterator.next() == expected[offset])
            offset += 1
        }
    }
    #expect(try await iterator.next() == nil)
    try await transport.assertComplete()

    await transport.close()
    guard case .some(.closed) = await recordedError({
        try await transport.writeStdin(commands[0])
    }) else { return }
}
