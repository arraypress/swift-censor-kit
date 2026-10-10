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
