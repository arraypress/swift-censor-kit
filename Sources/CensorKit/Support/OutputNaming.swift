//
//  OutputNaming.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  Where a censored copy goes and whether the work is already done — the
//  batch's safety rules as pure functions. Never in place: originals are
//  the one thing this tool must not be able to destroy.
//

import Foundation

public enum OutputNaming {

    /// The censored copy's URL: `name-censored.ext` beside the input, or
    /// mirrored under `outDir` relative to `root`. Video always lands in
    /// `.mov` — the writer's container for passthrough audio.
    public static func output(
        for input: URL, outDir: URL?, root: URL?, isVideo: Bool
    ) -> URL {
        let ext = isVideo ? "mov" : input.pathExtension.lowercased()
        let name = input.deletingPathExtension().lastPathComponent + "-censored"
        if let outDir {
            var relativeDir = ""
            if let root {
                let rootPath = root.standardizedFileURL.path
                let parent = input.deletingLastPathComponent().standardizedFileURL.path
                if parent.hasPrefix(rootPath), parent != rootPath {
                    relativeDir = String(parent.dropFirst(rootPath.count + 1))
                }
            }
            let dir = relativeDir.isEmpty ? outDir : outDir.appendingPathComponent(relativeDir)
            return dir.appendingPathComponent(name).appendingPathExtension(ext)
        }
        return input.deletingLastPathComponent()
            .appendingPathComponent(name).appendingPathExtension(ext)
    }

    /// Whether to skip: the output exists and is newer than the input, and
    /// nobody said `--force`. Also refuses the degenerate case where input
    /// and output collide.
    public static func shouldSkip(
        inputModified: Date?, outputModified: Date?, force: Bool
    ) -> Bool {
        guard !force, let outputModified else { return false }
        guard let inputModified else { return true }
        return outputModified > inputModified
    }
}
