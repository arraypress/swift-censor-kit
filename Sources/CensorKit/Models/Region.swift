//
//  Region.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// A manually chosen cover area: fractions of the frame, top-left origin
/// (the fleet's reporting convention), optionally limited to a time window
/// on video.
public struct Region: Sendable, Equatable {

    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Seconds; nil means from the start.
    public var start: TimeInterval?
    /// Seconds; nil means to the end.
    public var end: TimeInterval?

    public init(x: Double, y: Double, width: Double, height: Double,
                start: TimeInterval? = nil, end: TimeInterval? = nil) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.start = start
        self.end = end
    }

    /// Whether the region applies at `time` (always true for stills).
    public func covers(at time: TimeInterval) -> Bool {
        if let start, time < start { return false }
        if let end, time > end { return false }
        return true
    }
}
