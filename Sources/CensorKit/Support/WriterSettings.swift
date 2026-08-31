//
//  WriterSettings.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  What the writer should be told, derived from what the source is — as
//  a pure function over plain values, so the quality-parity rules are
//  pinned by tests with no video in sight. The defaults this replaces
//  (H.264, 8-bit, writer-chosen bitrate, no color tags) turned iPhone
//  HDR into washed-out SDR at a fraction of the source rate: exactly
//  the degradation the tool must not introduce.
//

import CoreVideo
import Foundation

/// The derived video-writer configuration.
public struct WriterSettings: Equatable, Sendable {

    /// `AVVideoCodecType` raw value: source codec in, source codec out.
    public var codec: String
    /// HEVC Main10 for 10-bit sources; nil otherwise.
    public var profileLevel: String?
    /// Never below the source's estimated rate.
    public var averageBitRate: Int
    /// The source's nominal rate, rounded, when it reports one.
    public var expectedFrameRate: Int?
    /// Copied verbatim from the source — all three or none, because the
    /// writer rejects a partial color-properties dictionary.
    public var colorPrimaries: String?
    public var transferFunction: String?
    public var yCbCrMatrix: String?
    /// The pipeline pixel format: 10-bit RGB for 10-bit sources, else BGRA.
    public var pixelFormat: OSType

    /// Whether all three color tags survive to the writer.
    public var hasColorProperties: Bool {
        colorPrimaries != nil && transferFunction != nil && yCbCrMatrix != nil
    }

    /// Derives the writer's story from the source track's.
    ///
    /// Rules, each load-bearing:
    /// - HEVC in → HEVC out; anything else re-encodes as H.264 — except a
    ///   10-bit source, which is ALWAYS HEVC Main10 (H.264 hardware paths
    ///   are 8-bit; writing one would truncate the source's depth).
    /// - Bitrate is the source's estimate or a resolution floor, whichever
    ///   is higher — matching quality needs matching budget.
    /// - Color tags are copied only as a complete set.
    public static func derive(
        codecSubtype: String, width: Int, height: Int,
        estimatedDataRate: Double, nominalFrameRate: Double,
        bitsPerComponent: Int?, colorPrimaries: String?,
        transferFunction: String?, yCbCrMatrix: String?
    ) -> WriterSettings {
        let tenBit = (bitsPerComponent ?? 8) >= 10
        let hevcIn = codecSubtype == "hvc1" || codecSubtype == "hev1"
        let codec = (hevcIn || tenBit) ? "hvc1" : "avc1"

        let fps = nominalFrameRate > 0 ? nominalFrameRate : 30
        let floorRate = Double(width * height) * fps * 0.05
        let bitRate = Int(max(estimatedDataRate, max(floorRate, 1_000_000)))

        let complete = colorPrimaries != nil && transferFunction != nil && yCbCrMatrix != nil
        return WriterSettings(
            codec: codec,
            profileLevel: tenBit ? "HEVC_Main10_AutoLevel" : nil,
            averageBitRate: bitRate,
            expectedFrameRate: nominalFrameRate > 0 ? Int(nominalFrameRate.rounded()) : nil,
            colorPrimaries: complete ? colorPrimaries : nil,
            transferFunction: complete ? transferFunction : nil,
            yCbCrMatrix: complete ? yCbCrMatrix : nil,
            pixelFormat: tenBit
                ? kCVPixelFormatType_ARGB2101010LEPacked
                : kCVPixelFormatType_32BGRA)
    }
}
