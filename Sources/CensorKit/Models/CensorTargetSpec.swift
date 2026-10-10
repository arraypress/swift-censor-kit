//
//  CensorTargetSpec.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// What to cover. Reference faces arrive as feature-print embeddings —
/// the CLI extracts them from reference photos before the batch starts,
/// so the engine never re-reads a reference per file.
public enum CensorTargetSpec: Sendable {
    /// Every face, filtered by ``FaceSelection`` — reference photos,
    /// outline numbers, or nothing (cover everyone).
    case faces(FaceSelection)
    /// Whole people by segmentation; `only` selects the Nth largest
    /// instance (1-based) where instance masks are available.
    case person(only: Int?)
    /// Recognized text lines containing the pattern (case-insensitive).
    case text(pattern: String)
    /// Recognized text lines a caller's rule picks — checksum-verified card
    /// numbers, IBANs, emails, from RedactKit, without this kit depending
    /// on it.
    case matching(TextMatcher)
    /// Manually chosen areas.
    case regions([Region])
}

public extension CensorTargetSpec {

    /// The rule for text targets, nil for every other kind.
    var textMatcher: TextMatcher? {
        switch self {
        case .text(let pattern): return .containing(pattern)
        case .matching(let matcher): return matcher
        default: return nil
        }
    }
}
