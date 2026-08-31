//
//  Track.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  A cover's path through a video: sampled boxes on the source timeline.
//  The shape only — association, smoothing and interpolation live in
//  Support/TrackMath, and the box-at-time lookup delegates there.
//

import Foundation

/// One sampled box, normalized to the frame, top-left origin.
public struct TrackedBox: Sendable, Equatable {
    public var time: TimeInterval
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(time: TimeInterval, x: Double, y: Double, width: Double, height: Double) {
        self.time = time
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One face (or held text box) followed across a video.
public struct Track: Sendable, Equatable {
    /// Stable per-video id, in order of first appearance.
    public var id: Int
    /// Sampled boxes, ascending in time.
    public var keyframes: [TrackedBox]
    /// Mean feature print of the face crops, when identity was needed.
    public var embedding: [Float]

    public init(id: Int, keyframes: [TrackedBox], embedding: [Float] = []) {
        self.id = id
        self.keyframes = keyframes
        self.embedding = embedding
    }
}
