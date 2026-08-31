//
//  Track+Box.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  The track's one derived fact — where its box sits at a time — as a
//  delegation into TrackMath, so the rule stays a pure function.
//

import Foundation

extension Track {

    /// The interpolated box at `time`, or nil when the track isn't present.
    public func box(at time: TimeInterval) -> TrackedBox? {
        TrackMath.box(at: time, in: keyframes)
    }
}
