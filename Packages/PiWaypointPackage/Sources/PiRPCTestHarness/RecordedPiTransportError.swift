//
//  RecordedPiTransportError.swift
//  PiWaypointPackage
//
//  Created by Tomasz Kubiak on 23/09/2026.
//

import Foundation

public enum RecordedPiTransportError: Error, Sendable {
    case invalidFixture(String)
    case fixtureReadFailed(String)
    case waitingForStdin(String)
    case unexpectedStdin(String)
    case stdinMismatch(expected: String, actual: String)
    case incompleteFixture(remaining: Int, bufferedStdinBytes: Int)
    case invalidPacing
    case closed
}
