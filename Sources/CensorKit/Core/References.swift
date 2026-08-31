//
//  References.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  Reference photos → embeddings, once per batch. The CLI hands these to
//  the engine so a thousand-file run never re-reads a reference.
//

import CoreImage
import Foundation

public enum References {

    /// The largest face's embedding in the photo at `url`.
    ///
    /// - Throws: ``CensorError/usage(_:)`` when the file holds no
    ///   detectable face — a silent empty reference would quietly cover
    ///   the person it was meant to protect.
    public static func embedding(fromImageAt url: URL) throws -> [Float] {
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw CensorError.io("could not read reference \(url.lastPathComponent) as an image")
        }
        let context = CIContext()
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            throw CensorError.processing("could not rasterize reference \(url.lastPathComponent)")
        }
        do {
            return try Detector.referenceEmbedding(in: cgImage)
        } catch let error as CensorError {
            if case .usage = error {
                throw CensorError.usage("no face found in reference \(url.lastPathComponent)")
            }
            throw error
        }
    }
}
