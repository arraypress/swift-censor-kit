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

- **Faces** — detected per sampled frame (in DISPLAY orientation, so rotated phone footage registers correctly), with a full-frame pass PLUS an overlapping tiled pass on large stills — Vision's detector has an effective minimum face size, and a 6000px wedding group went from 6 found faces to 10 with tiles (`thorough` adds the tiled pass to video sampling too). Detections are associated into tracks, smoothed, and held briefly past a missed detection so covers do not flicker — a hold on a moving subject slides along their exit instead of freezing mid-air, and decays at the frame edge.
- **Covers are the MEASURED head, not a guessed multiple.** No single multiplier of Vision's eyes-nose-mouth box is right — 2.2× tall left big curly hair outside on one clip and read comically oversized on a close-up — so the default cover is the person-mask component around each detection, cut off below the chin so torsos never join, with a whisker of margin on stills (1.06×) and a motion-leading margin on video (1.18×). Where segmentation has nothing to say (tiny tiled-pass faces, edge profiles) the 1.6×/2.2× multiplier fallback takes over. Blur strength scales with the cover so 4K anonymizes as thoroughly as 1080p; the user's padding is a multiplier with a floor of 1, applied exactly once in the renderer — it used to stack a further +25% on top of the geometry, which is how a specced 2.2× cover rendered at 2.75×. Covers are blur, pixelate, or an emoji; `outline` mode draws the raw detection, the final cover and each face's reading-order number instead — registration and selection made visible.
- **Selective faces** — ``FaceSelection`` composes reference photos with the numbers the outline draws: `onlyNumbers`/`skipNumbers` pick faces by reading order (left to right, ties top to bottom — `FaceOrdering`, pinned), images only. `except`/`only` take reference embeddings; a face matching a reference is spared (or is the only one covered). Identity is a feature print of the face crop — Apple ships no public recognition API — using swift-photo-index's measured calibration: the same person's crops sit 0.19–0.59 apart, different people never came closer than 1.1, and the 0.8 threshold sits in the gap. The library's test proves it to the pixel: with a reference from a *different shoot*, the referenced person's half of the canvas is untouched, byte for byte.
- **People** — whole silhouettes via person-instance masks (`only` picks the Nth largest on stills; video covers everyone by segmentation).
- **Text** — recognized lines containing a pattern, covered as softened rectangles.
- **Regions** — `x,y,w,h` as fractions of the frame, optionally time-limited on video.
- **Coverage gaps** — a video outcome names the windows the tool cannot vouch for: a track lost MID-FRAME (not out an edge) and never re-acquired nearby is reported as `[start, end]` seconds for human review, rather than guessed at. Pure over the track data (`TrackMath.gaps`), pinned.

## Measured (M-series, Release)

| Case | Result |
|---|---|
| 10 s 1080p30 video, faces, any mode | 2.3–2.5 s wall (~4× realtime), 300/300 frames covered |
| 12 s 4K24 iPhone HDR (HEVC 10-bit HLG, 31 Mb/s), faces | 16.3 s end to end — adaptive head sizing runs at every 0.25 s sample |
| The same clip, `thorough` (tiled samples) | 20.5 s, and it found a second small face |
| 6000×3376 group still, tiled by default | ~2.1 s — 10 faces covered where the full-frame pass alone finds 6 |
| Region `@2-6` on a 30 fps clip | exactly 121 of 300 frames covered |
| Audio | float32 LPCM 22050 Hz passed through bit-format-identical |

## The contract

- Output is always a new file; the engine never opens an original for writing. Video lands in `.mov` (the container the audio passthrough guarantees), stills keep their format and color space; orientation is baked in on load.
- **Quality parity**: the writer is configured from the source — same codec (HEVC in, HEVC out), bitrate never below the source's estimate, 10-bit stays 10-bit (HEVC Main10), color tags copied whole (iPhone HDR stays BT.2020/HLG), frame rate and rotation preserved, and audio plus timed-metadata tracks pass through untouched. The settings and the deadlock-free writer feeding are [swift-video-forge](https://github.com/arraypress/swift-video-forge)'s `WriterSettings` and `WriterPump` (moved there in 2.4.0, so `vid` and this library write the same way); the codec rule — HEVC stays HEVC, 10-bit is always HEVC Main 10, anything else H.264 — and the RGB frame formats Vision needs are this library's. Measured after the move: `redact region` on 8-bit H.264 + AAC, 10-bit HLG HEVC and a noise clip gave decoded frames and audio identical to 2.3.1's. Verified on a real iPhone 4K HDR clip: the censored copy's format story matches the source field for field. The one honest exception: Dolby Vision dynamic metadata does not survive any re-encode — output remains correct HLG/HDR10-style HDR, without the per-scene Dolby layer.
- `SCAGate` wraps Apple's SensitiveContentAnalysis (images and, on this SDK, video files). It judges whole files only and answers only where its policy allows; everything else reports that honestly rather than guessing.
- **What this cannot do**: no Apple API localizes body parts, so there is no automatic NSFW-region covering — the honest workflow is SCA's whole-file flag plus person/region covers.

## Requirements

- macOS 26+, Apple silicon
- Swift 6.2
- Frameworks: Vision, CoreImage, AVFoundation, ImageIO, SensitiveContentAnalysis, Accelerate; fleet packages only — swift-video-forge, and through it swift-image-forge, swift-video-grade and swift-subtitle-kit — nothing third-party

## License

MIT — see [LICENSE](LICENSE).
