//
//  VideoPerson.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  One person a video scan found: every face track Apple's face grouping
//  put together, numbered by first appearance. The shape only — grouping
//  lives in Support/PeopleGrouping, the grouping itself in Core/FaceGroups.
//

import Foundation

/// A person found in a video — the number `--outline` draws and
/// `--only`/`--skip` take.
public struct VideoPerson: Sendable, Codable, Equatable {
    /// 1-based, in order of first appearance; left to right on a tie.
    public var number: Int
    /// Seconds into the video they are first seen.
    public var from: TimeInterval
    /// Seconds into the video they are last seen.
    public var to: TimeInterval
    /// Seconds on screen, summed over their appearances.
    public var seconds: TimeInterval
    /// How many separate times they appear — face tracks, split at cuts
    /// and where detection lost them.
    public var appearances: Int
    /// The face tracks that are this person.
    public var tracks: [Int]

    /// The track ids are this library's bookkeeping, not a reader's.
    private enum CodingKeys: String, CodingKey {
        case number, from, to, seconds, appearances
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(number: try container.decode(Int.self, forKey: .number),
                  from: try container.decode(TimeInterval.self, forKey: .from),
                  to: try container.decode(TimeInterval.self, forKey: .to),
                  seconds: try container.decode(TimeInterval.self, forKey: .seconds),
                  appearances: try container.decode(Int.self, forKey: .appearances),
                  tracks: [])
    }

    public init(number: Int, from: TimeInterval, to: TimeInterval, seconds: TimeInterval,
                appearances: Int, tracks: [Int]) {
        self.number = number
        self.from = from
        self.to = to
        self.seconds = seconds
        self.appearances = appearances
        self.tracks = tracks
    }
}
