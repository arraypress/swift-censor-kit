//
//  MetadataCheck.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  What a written image still says about where, with what and by whom it
//  was taken. A covered photo is for sharing, and covering a face while the
//  file still carries the GPS of somebody's house is not redaction — so
//  every cover re-reads its own output and refuses one this finds anything
//  in. The idea is PrivacyCam's ("photo exports are re-encoded and checked
//  for remaining EXIF"); the need was found the same day, when a scratch
//  build showed GPS, make, model and serial number surviving the blur.
//

import Foundation
import ImageIO

/// Finds identifying metadata in an image file.
public enum MetadataCheck {

    /// The kinds of identifying metadata in an image file, by name.
    ///
    /// Reports kinds, never values: the point is to say a location is there,
    /// not to print it.
    ///
    /// - Parameter url: The image to read.
    /// - Returns: "GPS", "camera", "serial number", "author", "capture date",
    ///   "IPTC", "XMP", "maker notes" — whichever are present. Empty when clean.
    public static func leaks(in url: URL) -> [String] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return []
        }
        var found: [String] = []
        if properties[kCGImagePropertyGPSDictionary] != nil { found.append("GPS") }

        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        if tiff[kCGImagePropertyTIFFMake] != nil || tiff[kCGImagePropertyTIFFModel] != nil
            || exif[kCGImagePropertyExifLensModel] != nil { found.append("camera") }
        if exif[kCGImagePropertyExifBodySerialNumber] != nil || exif[kCGImagePropertyExifLensSerialNumber] != nil {
            found.append("serial number")
        }
        if tiff[kCGImagePropertyTIFFArtist] != nil || tiff[kCGImagePropertyTIFFCopyright] != nil
            || exif[kCGImagePropertyExifCameraOwnerName] != nil { found.append("author") }
        if exif[kCGImagePropertyExifDateTimeOriginal] != nil || tiff[kCGImagePropertyTIFFDateTime] != nil {
            found.append("capture date")
        }
        if properties[kCGImagePropertyIPTCDictionary] != nil { found.append("IPTC") }
        if properties[kCGImagePropertyMakerAppleDictionary] != nil { found.append("maker notes") }
        if CGImageSourceCopyMetadataAtIndex(source, 0, nil).map(hasXMP) == true { found.append("XMP") }
        return found
    }

    /// Whether image metadata carries any XMP namespace beyond the basics
    /// every encoder writes about the pixels themselves.
    static func hasXMP(_ metadata: CGImageMetadata) -> Bool {
        guard let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return false }
        let pixelOnly: Set<String> = ["http://ns.adobe.com/tiff/1.0/", "http://ns.adobe.com/exif/1.0/"]
        return tags.contains { tag in
            guard let namespace = CGImageMetadataTagCopyNamespace(tag) as String? else { return false }
            return !pixelOnly.contains(namespace)
        }
    }
}

// MARK: - Video

import AVFoundation

extension MetadataCheck {

    /// The words in a metadata identifier that mark it as identifying.
    static let identifyingVideoKeys = ["location", "iso6709", "gps", "make", "model", "author", "artist",
                                       "copyright", "owner", "serial", "detected-face", "face"]

    /// The kinds of identifying metadata in a video file, by name.
    ///
    /// Two places carry it: the container, where an iPhone writes the
    /// location and the camera, and timed metadata tracks, where a phone or
    /// a drone can write where it was every moment and where the faces in
    /// the frame were. Kinds, never values.
    ///
    /// - Parameter url: The video to read.
    /// - Returns: "location", "camera", "author", "timed location",
    ///   "timed faces", "timed identifying data" — whichever are present.
    public static func videoLeaks(in url: URL) async -> [String] {
        let asset = AVURLAsset(url: url)
        var found: [String] = []
        var items: [AVMetadataItem] = (try? await asset.load(.metadata)) ?? []
        for format in (try? await asset.load(.availableMetadataFormats)) ?? [] {
            items += (try? await asset.loadMetadata(for: format)) ?? []
        }
        let identifiers = items.compactMap { $0.identifier?.rawValue.lowercased() }
        if identifiers.contains(where: { $0.contains("location") || $0.contains("iso6709") || $0.contains("gps") }) {
            found.append("location")
        }
        if identifiers.contains(where: { $0.contains("make") || $0.contains("model") || $0.contains("serial") }) {
            found.append("camera")
        }
        if identifiers.contains(where: { $0.contains("author") || $0.contains("artist") || $0.contains("owner")
            || $0.contains("copyright") }) {
            found.append("author")
        }
        for track in (try? await asset.loadTracks(withMediaType: .metadata)) ?? [] {
            let timed = timedIdentifiers(of: track, descriptions: (try? await track.load(.formatDescriptions)) ?? [])
            if timed.contains(where: { $0.contains("location") || $0.contains("iso6709") || $0.contains("gps") }) {
                found.append("timed location")
            } else if timed.contains(where: { $0.contains("face") }) {
                found.append("timed faces")
            } else if timed.contains(where: { id in identifyingVideoKeys.contains { id.contains($0) } }) {
                found.append("timed identifying data")
            }
        }
        return Array(NSOrderedSet(array: found)) as? [String] ?? found
    }

    /// The identifiers a timed metadata track declares, lowercased.
    static func timedIdentifiers(of track: AVAssetTrack, descriptions: [CMFormatDescription]) -> [String] {
        descriptions.flatMap { description in
            (CMMetadataFormatDescriptionGetIdentifiers(description) as? [String] ?? []).map { $0.lowercased() }
        }
    }

    /// Whether a timed metadata track carries anything identifying — the
    /// ones a censored copy must not keep.
    static func isIdentifying(_ descriptions: [CMFormatDescription]) -> Bool {
        descriptions.contains { description in
            (CMMetadataFormatDescriptionGetIdentifiers(description) as? [String] ?? []).contains { id in
                identifyingVideoKeys.contains { id.lowercased().contains($0) }
            }
        }
    }
}
