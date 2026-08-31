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
    /// Every face, minus `except`, or restricted to `only`.
    case faces(except: [[Float]], only: [[Float]])
    /// Whole people by segmentation; `only` selects the Nth largest
    /// instance (1-based) where instance masks are available.
    case person(only: Int?)
    /// Recognized text lines containing the pattern (case-insensitive).
    case text(pattern: String)
    /// Manually chosen areas.
    case regions([Region])
}
