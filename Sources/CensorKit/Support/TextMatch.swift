//
//  TextMatch.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// Whether a recognized line earns a cover.
public enum TextMatch {

    /// Case-insensitive containment — the pattern the CLI documents.
    public static func matches(_ candidate: String, pattern: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        return candidate.range(of: pattern, options: [.caseInsensitive]) != nil
    }
}
