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

    /// Nearest-center association of sampled detections into tracks.
    ///
    /// Samples must arrive in ascending time order. Within a sample, the
    /// closest detection-and-track pair is joined first, then the next
    /// closest, each detection and each track at most once — so two faces
    /// side by side keep their own tracks. Until 2026-10-28 each detection
    /// took its nearest track in the order Vision listed them, and two
    /// people shoulder to shoulder swapped tracks sample after sample. A
    /// pair is only joined within ``maxJump``; a detection left over
    /// starts a new track. Track embeddings are the running mean of their
    /// detections', so identity smooths the way boxes do.
    ///
    /// No track continues across a time in `cuts` — where the shot
    /// changes. Without that, the next shot's face in the same part of the
    /// frame continued the last shot's track: its embedding averaged two
    /// people, so a reference photo matched neither, and its cover slid
    /// between the two places across any gap.
    public static func associate(_ samples: [[Detection]], cuts: [TimeInterval] = []) -> [Track] {
        struct Live {
            var track: Track
            var embeddingCount: Int
        }
        var live: [Live] = []
        var nextID = 0

        for sample in samples {
            var pairs: [(detection: Int, live: Int, distance: Double)] = []
            for (d, detection) in sample.enumerated() {
                for (index, candidate) in live.enumerated() {
                    guard let last = candidate.track.keyframes.last,
                          !separated(last.time, detection.time, by: cuts) else { continue }
                    let dx = (last.x + last.width / 2) - (detection.x + detection.width / 2)
                    let dy = (last.y + last.height / 2) - (detection.y + detection.height / 2)
                    let distance = (dx * dx + dy * dy).squareRoot()
                    if distance <= maxJump { pairs.append((d, index, distance)) }
                }
            }
            pairs.sort { ($0.distance, $0.detection, $0.live) < ($1.distance, $1.detection, $1.live) }
            var trackOf: [Int: Int] = [:]
            var taken = Set<Int>()
            for pair in pairs where trackOf[pair.detection] == nil && !taken.contains(pair.live) {
                trackOf[pair.detection] = pair.live
                taken.insert(pair.live)
            }

            // A track started in this sample is taken for this sample. It
            // was not, until 2026-10-10: the second of two things first seen
            // together joined the first one's track, which then slid between
            // them, and the second went uncovered until the next sample.
            for (d, detection) in sample.enumerated() {
                let box = TrackedBox(time: detection.time, x: detection.x, y: detection.y,
                                     width: detection.width, height: detection.height)
                guard let index = trackOf[d] else {
                    live.append(Live(track: Track(id: nextID, keyframes: [box], embedding: detection.embedding),
                                     embeddingCount: detection.embedding.isEmpty ? 0 : 1))
                    nextID += 1
                    continue
                }
                live[index].track.keyframes.append(box)
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
            }
        }
        return live.map(\.track)
    }

    /// Whether a cut falls after `earlier` and at or before `later`.
    static func separated(_ earlier: TimeInterval, _ later: TimeInterval, by cuts: [TimeInterval]) -> Bool {
        cuts.contains { $0 > earlier && $0 <= later }
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

    /// How long before a cut a held cover ends — under one frame at 120 fps.
    static let cutMargin = 0.005

    /// Below this speed (frame fractions per second) a held cover freezes
    /// in place; above it, the hold follows the motion.
    public static let exitSpeedThreshold = 0.05

    /// The same keyframes, with the first held `lead` seconds earlier
    /// (never before zero) — cover from just before a thing was first seen.
    ///
    /// A lead never reaches back past a cut in `cuts`: before it, the
    /// shot was another picture.
    public static func leadIn(_ keyframes: [TrackedBox], by lead: TimeInterval,
                              cuts: [TimeInterval] = []) -> [TrackedBox] {
        guard lead > 0, let first = keyframes.first, first.time > 0 else { return keyframes }
        let floor = cuts.filter { $0 <= first.time }.max() ?? 0
        guard first.time > floor else { return keyframes }
        var early = first
        early.time = max(floor, first.time - lead)
        return [early] + keyframes
    }

    /// Extends a track `hold` seconds past its last sighting, so a cover
    /// outlives a missed detection instead of flickering off.
    ///
    /// A STATIONARY subject's cover freezes where it was — conservative,
    /// for mid-frame occlusions. A MOVING subject's cover continues along
    /// its exit velocity instead (the first real clip showed why: a
    /// walker leaving frame left a stale pixel patch floating over the
    /// empty doorway), and the hold is cut short once the extrapolated
    /// box has fully left the frame — nothing there needs covering.
    ///
    /// A hold also ends at the next cut in `cuts`: after it the shot is
    /// another picture, and a cover left where the face was is a smudge
    /// on an empty wall.
    public static func extend(_ keyframes: [TrackedBox], hold: TimeInterval,
                              cuts: [TimeInterval] = []) -> [TrackedBox] {
        guard let last = keyframes.last else { return keyframes }
        let hold = min(hold, (cuts.filter { $0 > last.time }.min() ?? .infinity) - last.time - cutMargin)
        guard hold > 0 else { return keyframes }

        func frozen() -> [TrackedBox] {
            var held = last
            held.time = last.time + hold
            return keyframes + [held]
        }

        guard keyframes.count >= 2 else { return frozen() }
        let previous = keyframes[keyframes.count - 2]
        let dt = last.time - previous.time
        guard dt > 0 else { return frozen() }
        let vx = (last.x - previous.x) / dt
        let vy = (last.y - previous.y) / dt
        guard (vx * vx + vy * vy).squareRoot() >= exitSpeedThreshold else { return frozen() }

        // Seconds until the box is FULLY outside the frame on its heading.
        var timeToExit = Double.infinity
        if vx > 0 { timeToExit = min(timeToExit, (1 - last.x) / vx) }
        if vx < 0 { timeToExit = min(timeToExit, (last.x + last.width) / -vx) }
        if vy > 0 { timeToExit = min(timeToExit, (1 - last.y) / vy) }
        if vy < 0 { timeToExit = min(timeToExit, (last.y + last.height) / -vy) }

        let effectiveHold = min(hold, max(0.1, timeToExit))
        var held = last
        held.time = last.time + effectiveHold
        held.x = last.x + vx * effectiveHold
        held.y = last.y + vy * effectiveHold
        return keyframes + [held]
    }

    /// How near the frame edge a lost box counts as having exited.
    public static let edgeTolerance = 0.02

    /// The windows the tool cannot vouch for: a track lost MID-FRAME (not
    /// out an edge) before the video ends may mean the person left — or
    /// that detection failed while they stayed. Each gap runs from the
    /// cover's expiry to the first later track starting nearby (the
    /// re-acquisition) or the video's end. Honest reporting beats a
    /// longer guess.
    public static func gaps(
        in tracks: [Track], duration: TimeInterval
    ) -> [CoverageGap] {
        var out: [CoverageGap] = []
        for track in tracks {
            guard let last = track.keyframes.last else { continue }
            if last.time >= duration - 0.1 { continue }
            if last.x <= edgeTolerance || last.y <= edgeTolerance
                || last.x + last.width >= 1 - edgeTolerance
                || last.y + last.height >= 1 - edgeTolerance { continue }
            let cx = last.x + last.width / 2
            let cy = last.y + last.height / 2
            var end = duration
            for other in tracks where other.id != track.id {
                guard let first = other.keyframes.first, first.time > last.time else { continue }
                let dx = (first.x + first.width / 2) - cx
                let dy = (first.y + first.height / 2) - cy
                if (dx * dx + dy * dy).squareRoot() <= maxJump {
                    end = min(end, first.time)
                }
            }
            if end > last.time + 0.01 {
                out.append(CoverageGap(track: track.id, start: last.time, end: end))
            }
        }
        return out.sorted { $0.start < $1.start }
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
