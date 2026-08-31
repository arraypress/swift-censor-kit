//
//  CoverRenderer.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  Puts the covers on the pixels. The look — feathered oval masks, the
//  blur/pixelate/emoji trio, CoreText emoji rasterization — is ported
//  from caption-kit's FaceCensorFilter (stated duplication; independent
//  packages). Two traps are designed around, both fleet-documented:
//  `.clampedToExtent()` without a crop paints the whole canvas, and a
//  mask must feather rather than hard-edge or the cover reads as a bug.
//

import CoreImage
import CoreText
import Foundation

enum CoverRenderer {

    /// One cover in CoreImage pixel space (bottom-left origin).
    struct Cover {
        enum Shape { case oval, rectangle, mask(CIImage) }
        var shape: Shape
        var rect: CGRect
    }

    /// A cover rect grown by the style's padding.
    static func padded(_ rect: CGRect, padding: Double) -> CGRect {
        let grow = 1 + max(0, padding)
        let w = rect.width * grow
        let h = rect.height * grow
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    /// All covers applied to the frame.
    static func apply(_ covers: [Cover], to image: CIImage, style: CoverStyle,
                      emojiImage: CIImage?) -> CIImage {
        guard !covers.isEmpty else { return image }
        var out = image
        for cover in covers {
            out = apply(cover, to: out, style: style, emojiImage: emojiImage)
        }
        return out
    }

    private static func apply(_ cover: Cover, to image: CIImage, style: CoverStyle,
                              emojiImage: CIImage?) -> CIImage {
        let face = padded(cover.rect, padding: style.padding)

        switch style.mode {
        case .emoji:
            // The emoji covers boxes; a free-form person mask falls back to
            // pixelation, which respects the silhouette.
            if case .mask = cover.shape {
                return pixelated(image, over: cover, face: face, intensity: style.intensity)
            }
            guard let emojiImage else { return image }
            let extent = emojiImage.extent
            guard extent.width > 0, extent.height > 0 else { return image }
            let scale = max(face.width / extent.width, face.height / extent.height) * 1.15
            let scaled = emojiImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let placed = scaled.transformed(by: CGAffineTransform(
                translationX: face.midX - scaled.extent.midX,
                y: face.midY - scaled.extent.midY))
            return placed.composited(over: image)

        case .blur:
            let radius = 6 + style.intensity * 45
            let blurred = image
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius])
                .cropped(to: image.extent)
            return blurred.applyingFilter("CIBlendWithMask", parameters: [
                "inputBackgroundImage": image,
                "inputMaskImage": mask(for: cover, face: face, in: image.extent),
            ]).cropped(to: image.extent)

        case .pixelate:
            return pixelated(image, over: cover, face: face, intensity: style.intensity)
        }
    }

    private static func pixelated(_ image: CIImage, over cover: Cover, face: CGRect,
                                  intensity: Double) -> CIImage {
        let scale = max(6, 6 + intensity * min(face.width, face.height) * 0.35)
        let pixelated = image
            .clampedToExtent()
            .applyingFilter("CIPixellate", parameters: [
                "inputCenter": CIVector(x: face.midX, y: face.midY),
                "inputScale": scale,
            ])
            .cropped(to: image.extent)
        return pixelated.applyingFilter("CIBlendWithMask", parameters: [
            "inputBackgroundImage": image,
            "inputMaskImage": mask(for: cover, face: face, in: image.extent),
        ]).cropped(to: image.extent)
    }

    /// The blend mask: a feathered white oval for faces, a softened
    /// rectangle for text and manual regions, or the caller's own mask.
    private static func mask(for cover: Cover, face: CGRect, in extent: CGRect) -> CIImage {
        switch cover.shape {
        case .mask(let provided):
            return provided.cropped(to: extent)
        case .oval:
            let radius = max(face.width, face.height) / 2
            let gradient = CIFilter(name: "CIRadialGradient")
            gradient?.setValue(CIVector(x: face.midX, y: face.midY), forKey: "inputCenter")
            gradient?.setValue(radius * 0.72, forKey: "inputRadius0")
            gradient?.setValue(radius * 1.05, forKey: "inputRadius1")
            gradient?.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor0")
            gradient?.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 1), forKey: "inputColor1")
            return (gradient?.outputImage ?? CIImage(color: .black)).cropped(to: extent)
        case .rectangle:
            return CIImage(color: .white)
                .cropped(to: face)
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 3.0])
                .composited(over: CIImage(color: .black))
                .cropped(to: extent)
        }
    }

    /// Rasterizes an emoji to a CIImage via CoreText (no AppKit),
    /// transparent background.
    static func renderEmoji(_ emoji: String) -> CIImage? {
        let side = 256
        let fontSize: CGFloat = 200
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, fontSize, nil)
        let attributed = NSAttributedString(
            string: emoji.isEmpty ? "🙂" : emoji,
            attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetImageBounds(line, context)
        context.textPosition = CGPoint(
            x: (CGFloat(side) - bounds.width) / 2 - bounds.minX,
            y: (CGFloat(side) - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, context)
        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }

    /// Normalized top-left boxes → CoreImage pixel-space cover rects.
    static func coverRect(x: Double, y: Double, width: Double, height: Double,
                          in extent: CGRect) -> CGRect {
        CGRect(
            x: x * extent.width,
            y: (1 - y - height) * extent.height,
            width: width * extent.width,
            height: height * extent.height)
    }
}
