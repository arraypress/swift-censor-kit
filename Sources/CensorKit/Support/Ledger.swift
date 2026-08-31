//
//  Ledger.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// The batch's honest bookkeeping: what was covered, skipped and failed,
/// and whether the whole run counts as a success.
public struct Ledger: Sendable, Codable, Equatable {

    public var files: [FileOutcome] = []

    public init() {}

    public mutating func record(_ outcome: FileOutcome) {
        files.append(outcome)
    }

    public var covered: Int { files.filter { $0.status == .covered }.count }
    public var wouldCover: Int { files.filter { $0.status == .wouldCover }.count }
    public var skipped: Int { files.filter { $0.status == .skipped }.count }
    public var failed: Int { files.filter { $0.status == .failed }.count }

    /// A batch succeeds when nothing failed. Nothing-to-do is success:
    /// re-running over an already-censored folder is the normal case.
    public var succeeded: Bool { failed == 0 }

    /// The one-line summary a run ends with.
    public var summary: String {
        var parts: [String] = []
        if covered > 0 { parts.append("\(covered) covered") }
        if wouldCover > 0 { parts.append("\(wouldCover) would be covered") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if failed > 0 { parts.append("\(failed) FAILED") }
        return parts.isEmpty ? "nothing to do" : parts.joined(separator: " · ")
    }
}
