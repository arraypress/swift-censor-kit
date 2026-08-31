//
//  FaceMatching.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  The keep-or-cover decision for a face, alone and testable. The
//  threshold is swift-photo-index's calibration, measured there on real
//  portraits: the same person's crops range 0.19–0.59 apart (flipped
//  copies, and the same model across two different shoots at 0.188);
//  different people never came closer than 1.1. 0.8 sits in the gap.
//

public enum FaceMatching {

    /// Euclidean distance between face-crop feature prints at which two
    /// faces count as the same person.
    public static let sameFaceThreshold: Float = 0.8

    /// Whether `embedding` matches any of the reference embeddings.
    public static func matches(
        _ embedding: [Float], anyOf references: [[Float]],
        threshold: Float = sameFaceThreshold
    ) -> Bool {
        guard !embedding.isEmpty else { return false }
        return references.contains { Vectors.euclidean(embedding, $0) <= threshold }
    }

    /// Whether a track should be covered, given the selection flags.
    ///
    /// `except` wins the argument its name starts: a face matching any
    /// reference there is left alone. With `only`, everything is left
    /// alone EXCEPT matching faces. Both empty means cover everyone.
    public static func shouldCover(
        _ embedding: [Float], except: [[Float]], only: [[Float]],
        threshold: Float = sameFaceThreshold
    ) -> Bool {
        if !except.isEmpty, matches(embedding, anyOf: except, threshold: threshold) {
            return false
        }
        if !only.isEmpty {
            return matches(embedding, anyOf: only, threshold: threshold)
        }
        return true
    }
}
