//
//  OrientationMap.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  The bridge between the two spaces a rotated video lives in. Frames
//  are DECODED in storage space (an iPhone portrait clip is a landscape
//  buffer plus a 90° transform); faces are UPRIGHT only in display
//  space. Detection therefore runs with the display orientation handed
//  to Vision, and the boxes come back in display coordinates — these
//  functions carry them to storage space, where the covers are drawn
//  and the writer works. All pure; the mis-registration this fixes was
//  invisible to every unrotated test.
//

import CoreGraphics
import ImageIO

public enum OrientationMap {

    /// The transform's rotation in quarter turns clockwise (0…3).
    /// Anything that is not a pure quarter-turn rotation maps to 0.
    public static func quarterTurns(of transform: CGAffineTransform) -> Int {
        let a = transform.a.rounded()
        let b = transform.b.rounded()
        let c = transform.c.rounded()
        let d = transform.d.rounded()
        if a == 0, b == 1, c == -1, d == 0 { return 1 }
        if a == -1, b == 0, c == 0, d == -1 { return 2 }
        if a == 0, b == -1, c == 1, d == 0 { return 3 }
        return 0
    }

    /// How Vision must be told to hold the storage buffer so faces are
    /// upright.
    public static func visionOrientation(quarterTurns: Int) -> CGImagePropertyOrientation {
        switch quarterTurns {
        case 1: return .right
        case 2: return .down
        case 3: return .left
        default: return .up
        }
    }

    /// A display-space box (normalized, top-left) → the storage-space box
    /// covering the same pixels.
    public static func toStorage(
        x: Double, y: Double, width: Double, height: Double, quarterTurns: Int
    ) -> (x: Double, y: Double, width: Double, height: Double) {
        switch quarterTurns {
        case 1: return (y, 1 - x - width, height, width)
        case 2: return (1 - x - width, 1 - y - height, width, height)
        case 3: return (1 - y - height, x, height, width)
        default: return (x, y, width, height)
        }
    }

    /// The orientation that turns a storage-space crop upright — the
    /// inverse of the display rotation, for feature-printing face crops
    /// so they match upright reference photos.
    public static func uprightingOrientation(quarterTurns: Int) -> CGImagePropertyOrientation {
        visionOrientation(quarterTurns: quarterTurns)
    }
}
