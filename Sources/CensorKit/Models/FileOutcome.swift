//
//  FileOutcome.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// What happened to one file in a batch.
public struct FileOutcome: Sendable, Codable, Equatable {

    public enum Status: String, Sendable, Codable {
        /// Covers were rendered and the output written.
        case covered
        /// Nothing to cover, or the output was already current.
        case skipped
        /// The file could not be processed; the batch continued.
        case failed
        /// Dry run: what a real run would have covered.
        case wouldCover = "would-cover"
    }

    public var input: String
    public var output: String?
    public var status: Status
    /// How many covers were (or would be) applied.
    public var covers: Int
    /// The reason for a skip or failure, or a match summary.
    public var detail: String?
    /// Video only: windows where a tracked subject may be present but
    /// uncovered — the seconds a human should review.
    public var gaps: [CoverageGap]?

    public init(input: String, output: String? = nil, status: Status,
                covers: Int = 0, detail: String? = nil, gaps: [CoverageGap]? = nil) {
        self.input = input
        self.output = output
        self.status = status
        self.covers = covers
        self.detail = detail
        self.gaps = gaps
    }
}
