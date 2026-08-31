# CensorKit

Cover faces, whole people, matching text and fixed regions in images and video — on device, on Apple's frameworks, and never in place.

```swift
import CensorKit

let reference = try References.embedding(fromImageAt: me)
let outcome = try await VideoCensor.censor(
    videoAt: clip,
    target: .faces(except: [reference], only: []),
    style: CoverStyle(mode: .emoji, emoji: "🎉"),
    to: output, dryRun: false)
```

## What it does

- **Faces** — detected per sampled frame (in DISPLAY orientation, so rotated phone footage registers correctly), associated into tracks, smoothed, and held briefly past a missed detection so covers do not flicker — a hold on a moving subject slides along their exit instead of freezing mid-air, and decays at the frame edge. Covers take the whole HEAD, not Vision's eyes-nose-mouth box (1.6× wide, 2.2× tall, biased above for hair — measured on real footage where the tight box left the person identifiable), and blur strength scales with the cover so 4K anonymizes as thoroughly as 1080p. Covers are blur, pixelate, or an emoji; `outline` mode draws the detection and cover boxes instead — registration made visible.
- **Selective faces** — `except`/`only` take reference embeddings; a face matching a reference is spared (or is the only one covered). Identity is a feature print of the face crop — Apple ships no public recognition API — using swift-photo-index's measured calibration: the same person's crops sit 0.19–0.59 apart, different people never came closer than 1.1, and the 0.8 threshold sits in the gap. The library's test proves it to the pixel: with a reference from a *different shoot*, the referenced person's half of the canvas is untouched, byte for byte.
- **People** — whole silhouettes via person-instance masks (`only` picks the Nth largest on stills; video covers everyone by segmentation).
- **Text** — recognized lines containing a pattern, covered as softened rectangles.
- **Regions** — `x,y,w,h` as fractions of the frame, optionally time-limited on video.

## Measured (M-series, Release)

| Case | Result |
|---|---|
| 10 s 1080p30 video, faces, any mode | 2.3–2.5 s wall (~4× realtime), 300/300 frames covered |
| 12 s 4K24 iPhone HDR (HEVC 10-bit HLG, 31 Mb/s), faces | 10.9 s end to end — analysis and render |
| Stills with one face | ~26 images/s |
| Region `@2-6` on a 30 fps clip | exactly 121 of 300 frames covered |
| Audio | float32 LPCM 22050 Hz passed through bit-format-identical |

## The contract

- Output is always a new file; the engine never opens an original for writing. Video lands in `.mov` (the container the audio passthrough guarantees), stills keep their format and color space; orientation is baked in on load.
- **Quality parity**: the writer is configured from the source — same codec (HEVC in, HEVC out), bitrate never below the source's estimate, 10-bit stays 10-bit (HEVC Main10), color tags copied whole (iPhone HDR stays BT.2020/HLG), frame rate and rotation preserved, and audio plus timed-metadata tracks pass through untouched. Verified on a real iPhone 4K HDR clip: the censored copy's format story matches the source field for field. The one honest exception: Dolby Vision dynamic metadata does not survive any re-encode — output remains correct HLG/HDR10-style HDR, without the per-scene Dolby layer.
- `SCAGate` wraps Apple's SensitiveContentAnalysis (images and, on this SDK, video files). It judges whole files only and answers only where its policy allows; everything else reports that honestly rather than guessing.
- **What this cannot do**: no Apple API localizes body parts, so there is no automatic NSFW-region covering — the honest workflow is SCA's whole-file flag plus person/region covers.

## Requirements

- macOS 26+, Apple silicon
- Swift 6.2
- Frameworks: Vision, CoreImage, AVFoundation, ImageIO, SensitiveContentAnalysis, Accelerate — nothing third-party

## License

MIT — see [LICENSE](LICENSE).
