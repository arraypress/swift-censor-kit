//
//  FaceOrdering.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  The numbering people point at: `--outline` labels each detected face
//  and `--only 2,4` covers exactly those, so a group photo needs no
//  reference image. The order must be the one a reader assumes —
//  left to right by box center, top to bottom on a near-tie — and it
//  must be stable across runs, so it is a pure sort, pinned.
//

import Foundation

public enum FaceOrdering {

    /// Centers within this horizontal distance count as one column and
    /// fall back to top-to-bottom.
    public static let columnTolerance = 0.03

    /// Detections in reading order: left-to-right, ties top-to-bottom.
    /// Position 0 is face number 1.
    public static func ordered(_ detections: [TrackMath.Detection]) -> [TrackMath.Detection] {
        detections.sorted { a, b in
            let ax = a.x + a.width / 2
            let bx = b.x + b.width / 2
            if abs(ax - bx) > columnTolerance { return ax < bx }
            return a.y + a.height / 2 < b.y + b.height / 2
        }
    }
}
