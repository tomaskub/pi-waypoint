//
//  PiRPCTransport.swift
//  PiWaypointPackage
//
//  Created by Tomasz Kubiak on 23/09/2026.
//

import Foundation

public protocol PiRPCTransport: Sendable {
    func stdout() async -> AsyncThrowingStream<Data, Error>
    func writeStdin(_ data: Data) async throws
    func close() async
}
