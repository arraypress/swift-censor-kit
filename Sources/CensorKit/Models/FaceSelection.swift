//
//  FaceSelection.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  Which faces a run covers. Two vocabularies compose: reference photos
//  (matched on-device by face-crop feature print) and the numbers the
//  outline diagnostic draws. The shape only — matching lives in
//  FaceMatching, numbering in FaceOrdering.
//

import Foundation

/// The face-selection flags, resolved to plain values.
public struct FaceSelection: Sendable {

    /// Faces matching any of these are LEFT UNCOVERED.
    public var except: [[Float]]
    /// When non-empty, ONLY faces matching these are covered.
    public var only: [[Float]]
    /// When non-empty, ONLY these face numbers are covered (1-based,
    /// reading order — the numbers `--outline` draws). Images only.
    public var onlyNumbers: Set<Int>
    /// These face numbers are left uncovered (1-based). Images only.
    public var skipNumbers: Set<Int>

    public init(except: [[Float]] = [], only: [[Float]] = [],
                onlyNumbers: Set<Int> = [], skipNumbers: Set<Int> = []) {
        self.except = except
        self.only = only
        self.onlyNumbers = onlyNumbers
        self.skipNumbers = skipNumbers
    }

    /// Whether any selection is active at all.
    public var isSelective: Bool {
        !except.isEmpty || !only.isEmpty || !onlyNumbers.isEmpty || !skipNumbers.isEmpty
    }

    /// Whether reference matching is needed (embeddings must be computed).
    public var wantsIdentity: Bool { !except.isEmpty || !only.isEmpty }

    /// Whether numbered selection is in play (images only).
    public var usesNumbers: Bool { !onlyNumbers.isEmpty || !skipNumbers.isEmpty }

    /// The keep-or-cover decision for face `number` with `embedding`.
    public func shouldCover(number: Int, embedding: [Float]) -> Bool {
        if skipNumbers.contains(number) { return false }
        if !onlyNumbers.isEmpty, !onlyNumbers.contains(number) { return false }
        return FaceMatching.shouldCover(embedding, except: except, only: only)
    }
}
