//
//  Vectors.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  Feature prints as float vectors and the one distance the matcher uses.
//  A deliberate small copy of swift-photo-index's Vectors — independent
//  packages, per the fleet's hex-parser precedent — kept byte-compatible
//  so the calibrated thresholds transfer.
//

import Accelerate
import Foundation

enum Vectors {

    /// The floats packed in a blob, little-endian float32 as Vision hands
    /// them over.
    static func floats(from data: Data) -> [Float] {
        guard !data.isEmpty, data.count % MemoryLayout<Float>.size == 0 else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Euclidean (L2) distance.
    static func euclidean(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .greatestFiniteMagnitude }
        var distanceSquared: Float = 0
        vDSP_distancesq(a, 1, b, 1, &distanceSquared, vDSP_Length(a.count))
        return distanceSquared.squareRoot()
    }
}
