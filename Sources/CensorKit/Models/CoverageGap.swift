//
//  CoverageGap.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  Seconds the tool cannot vouch for. A track lost mid-frame may mean
//  the person left — or that detection failed while they stayed. The
//  honest move is not to guess longer but to say so: each gap names the
//  window a human should review. The shape only; the rule that finds
//  them is TrackMath.gaps.
//

import Foundation

/// One window where a tracked subject may be present but uncovered.
public struct CoverageGap: Sendable, Codable, Equatable {
    /// The track that was lost (its cover's id).
    public var track: Int
    /// When its cover expired, in seconds.
    public var start: TimeInterval
    /// When it was re-acquired nearby, or the video's end.
    public var end: TimeInterval

    public init(track: Int, start: TimeInterval, end: TimeInterval) {
        self.track = track
        self.start = start
        self.end = end
    }
}
