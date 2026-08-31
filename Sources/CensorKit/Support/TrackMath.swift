//
//  TrackMath.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  Everything that turns sampled detections into steady covers, as pure
//  functions: association across samples, exponential smoothing,
//  persistence past a lost detection, and the box at a time. No Vision,
//  no video — a test replays synthetic samples and pins each rule.
//

import Foundation

public enum TrackMath {

    /// How far (in frame fractions, center to center) a box may move
    /// between consecutive samples and still be the same subject.
    public static let maxJump = 0.25

    /// One detection at one sampled time.
    public struct Detection: Sendable, Equatable {
        public var time: TimeInterval
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public var embedding: [Float]

        public init(time: TimeInterval, x: Double, y: Double,
                    width: Double, height: Double, embedding: [Float] = []) {
            self.time = time
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.embedding = embedding
        }
    }

    /// Greedy nearest-center association of sampled detections into tracks.
    ///
    /// Samples must arrive in ascending time order. A detection continues
    /// the nearest live track whose last center is within ``maxJump``;
    /// otherwise it starts a new track. Track embeddings are the running
    /// mean of their detections', so identity smooths the way boxes do.
    public static func associate(_ samples: [[Detection]]) -> [Track] {
        struct Live {
            var track: Track
            var lastTime: TimeInterval
            var embeddingCount: Int
        }
        var live: [Live] = []
        var nextID = 0

        for sample in samples {
            var claimed = Set<Int>()
            for detection in sample {
                var bestIndex: Int?
                var bestDistance = Double.greatestFiniteMagnitude
                for (index, candidate) in live.enumerated() where !claimed.contains(index) {
                    guard let last = candidate.track.keyframes.last else { continue }
                    let dx = (last.x + last.width / 2) - (detection.x + detection.width / 2)
                    let dy = (last.y + last.height / 2) - (detection.y + detection.height / 2)
                    let distance = (dx * dx + dy * dy).squareRoot()
                    if distance < bestDistance {
                        bestDistance = distance
                        bestIndex = index
                    }
                }
                let box = TrackedBox(time: detection.time, x: detection.x, y: detection.y,
                                     width: detection.width, height: detection.height)
                if let index = bestIndex, bestDistance <= maxJump {
                    claimed.insert(index)
                    live[index].track.keyframes.append(box)
                    live[index].lastTime = detection.time
                    if !detection.embedding.isEmpty {
                        let n = live[index].embeddingCount
                        if n == 0 || live[index].track.embedding.count != detection.embedding.count {
                            live[index].track.embedding = detection.embedding
                            live[index].embeddingCount = 1
                        } else {
                            for i in detection.embedding.indices {
                                live[index].track.embedding[i] =
                                    (live[index].track.embedding[i] * Float(n) + detection.embedding[i]) / Float(n + 1)
                            }
                            live[index].embeddingCount = n + 1
                        }
                    }
                } else {
                    live.append(Live(
                        track: Track(id: nextID, keyframes: [box], embedding: detection.embedding),
                        lastTime: detection.time,
                        embeddingCount: detection.embedding.isEmpty ? 0 : 1))
                    nextID += 1
                }
            }
        }
        return live.map(\.track)
    }

    /// Exponential smoothing over a track's boxes. `alpha` is the weight of
    /// the NEW sample: 1 leaves the track alone, small values steady it.
    public static func smooth(_ keyframes: [TrackedBox], alpha: Double) -> [TrackedBox] {
        guard alpha > 0, alpha < 1, keyframes.count > 1 else { return keyframes }
        var out = [keyframes[0]]
        for box in keyframes.dropFirst() {
            let previous = out[out.count - 1]
            out.append(TrackedBox(
                time: box.time,
                x: previous.x + alpha * (box.x - previous.x),
                y: previous.y + alpha * (box.y - previous.y),
                width: previous.width + alpha * (box.width - previous.width),
                height: previous.height + alpha * (box.height - previous.height)))
        }
        return out
    }

    /// Extends a track `hold` seconds past its last sighting, so a cover
    /// outlives a missed detection instead of flickering off.
    public static func extend(_ keyframes: [TrackedBox], hold: TimeInterval) -> [TrackedBox] {
        guard hold > 0, let last = keyframes.last else { return keyframes }
        var held = last
        held.time = last.time + hold
        return keyframes + [held]
    }

    /// The linearly interpolated box at `time`, or nil outside the track.
    public static func box(at time: TimeInterval, in keyframes: [TrackedBox]) -> TrackedBox? {
        guard let first = keyframes.first, let last = keyframes.last,
              time >= first.time, time <= last.time else { return nil }
        guard keyframes.count > 1 else { return first }
        for (a, b) in zip(keyframes, keyframes.dropFirst()) where time <= b.time {
            let span = b.time - a.time
            let f = span > 0 ? (time - a.time) / span : 0
            return TrackedBox(
                time: time,
                x: a.x + f * (b.x - a.x),
                y: a.y + f * (b.y - a.y),
                width: a.width + f * (b.width - a.width),
                height: a.height + f * (b.height - a.height))
        }
        return last
    }
}
