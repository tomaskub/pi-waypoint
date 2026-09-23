//
//  RecordedPiTransport.swift
//  PiWaypointPackage
//
//  Created by Tomasz Kubiak on 23/09/2026.
//

import Foundation

public struct RecordedPiTransport: PiRPCTransport {
    public enum ReplayPacing: Sendable {
        case immediate, manual, fixedInterval(Duration)
    }

    private let replay: Replay

    public init(
        fixtureURL: URL,
        pacing: ReplayPacing = .immediate
    ) {
        replay = Replay(fixtureURL: fixtureURL, pacing: pacing)
    }
    
    public func stdout() async -> AsyncThrowingStream<Data, any Error> {
        await replay.stdout()
    }
    
    public func writeStdin(_ data: Data) async throws {
        try await replay.writeStdin(data)
    }
    
    public func close() async {
        await replay.close()
    }
    
    public func emitNext() async throws {
        try await replay.emitNext()
    }
    
    public func assertComplete() async throws {
        try await replay.assertComplete()
    }
}
