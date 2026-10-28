# CensorKit

Cover faces, whole people, matching text and fixed regions in images and video — on device, on Apple's frameworks, and never in place.

```swift
import CensorKit

let reference = try await References.embedding(fromImageAt: me)
let outcome = try await VideoCensor.censor(
    videoAt: clip,
    target: .faces(FaceSelection(except: [reference])),
    style: CoverStyle(mode: .emoji, emoji: "🎉"),
    to: output, dryRun: false)

// Who is in it — a sheet of faces, numbered — then cover by number.
let listed = try await VideoCensor.people(videoAt: clip, to: sheet)      // listed.people
_ = try await VideoCensor.censor(videoAt: clip, target: .faces(FaceSelection(skipNumbers: [2])),
                                 style: CoverStyle(), to: output, dryRun: false)

// Covered stills from across the clip, without the render.
_ = try await VideoCensor.preview(videoAt: clip, target: .faces(FaceSelection()),
                                  style: CoverStyle(), to: previewSheet)
```

## What it does

- **Faces** — detected per sampled frame by **two detectors, merged** (3.0): Vision's revision 3 and, on macOS 27, revision 4, which exists only in the Swift Vision API. Measured on 734 frames of a feature film: revision 4 found faces in 27 frames revision 3 missed (small, dark, half behind a rifle scope; about 3 were not faces) and missed faces in 4 frames revision 3 found (profiles). A missed face is the failure that matters, so both run, concurrently. Detection is in DISPLAY orientation, so rotated phone footage registers correctly, with a full-frame pass PLUS an overlapping tiled pass on large stills — Vision's detector has an effective minimum face size, and a 6000px wedding group went from 6 found faces to 10 with tiles (`thorough` adds the tiled pass to video sampling too). Detections are associated into tracks, smoothed, and held briefly past a missed detection so covers do not flicker — a hold on a moving subject slides along their exit instead of freezing mid-air, and decays at the frame edge.
- **Tracks follow faces, shot by shot** (3.0). Video tracks the *face* box and draws the head-sized cover after: two people shoulder to shoulder have overlapping heads (their person masks join), and tracking the head boxes swapped them sample after sample. Within a sample the closest face-and-track pair is joined first. No track runs across a shot change (swift-video-forge's `Scenes`, read alongside the sampling): the next shot's face in the same place used to continue the last shot's track, averaging two people's identity and sliding a cover between them. A cover now starts a sample before a face is first seen and its hold ends at the cut, so it neither leaves the first quarter-second of a face uncovered nor smudges the next shot.
- **Covers are the MEASURED head, not a guessed multiple.** No single multiplier of Vision's eyes-nose-mouth box is right — 2.2× tall left big curly hair outside on one clip and read comically oversized on a close-up — so the default cover is the person-mask component around each detection, cut off below the chin so torsos never join, with a whisker of margin on stills (1.06×) and a motion-leading margin on video (1.18×). Where segmentation has nothing to say (tiny tiled-pass faces, edge profiles) the 1.6×/2.2× multiplier fallback takes over. Blur strength scales with the cover so 4K anonymizes as thoroughly as 1080p; the user's padding is a multiplier with a floor of 1, applied exactly once in the renderer — it used to stack a further +25% on top of the geometry, which is how a specced 2.2× cover rendered at 2.75×. Covers are blur, pixelate, or an emoji; `outline` mode draws the raw detection, the final cover and each face's reading-order number instead — registration and selection made visible.
- **Selective faces** — ``FaceSelection`` composes reference photos with the numbers the outline draws: `onlyNumbers`/`skipNumbers` pick faces by reading order on a still (left to right, ties top to bottom — `FaceOrdering`, pinned) and people on a video (below). `except`/`only` take reference embeddings; a face matching a reference is spared (or is the only one covered). Identity is a feature print of the face crop — Apple ships no public recognition API — using swift-photo-index's measured calibration: the same person's crops sit 0.19–0.59 apart, different people never came closer than 1.1, and the 0.8 threshold sits in the gap. The library's test proves it to the pixel: with a reference from a *different shoot*, the referenced person's half of the canvas is untouched, byte for byte.
- **The people in a video** (3.0, macOS 27) — `VideoCensor.people` writes a sheet of everyone found, each one's clearest face numbered by first appearance (left to right on a tie), with when they are on screen; `onlyNumbers`/`skipNumbers` then cover by those numbers. Grouping is Apple's own — MediaIntelligence's `FaceGroupAnalyzer`, the people grouping Photos does — over a crop of each track about once a second. Measured on 734 frames of a film: 460 faces into 37 groups, every group one actor, never two actors in one group; an actor in dark scenes can come out as two or three groups, the safe way round (pick both numbers). Where a track's crops change group the track is split — on a film scene two men crossing swapped tracks while the grouping was right about every crop — and a crop alone in its group across the whole video splits nothing (a face half behind a shoulder did). The numbers come from the same analysis a covering run does, so they hold for a later run over the same video with the same options; a number the video has no person for is refused. The framework prints to both standard streams, so it runs silenced (swift-stdout-silencer).
- **Preview** (3.0) — `VideoCensor.preview` writes a sheet of covered stills from across the clip (16 by default, `previewFrames`) instead of the video: the same analysis, the same covers drawn by the same renderer, each still labelled with its time and cover count. Any target — faces, people, text, regions.
- **Whole people** — whole silhouettes via person-instance masks (`only` picks the Nth largest on stills; video covers everyone by segmentation).
- **Text** — recognized lines containing a pattern, covered as softened rectangles.
- **Regions** — `x,y,w,h` as fractions of the frame, optionally time-limited on video.
- **Coverage gaps** — a video outcome names the windows the tool cannot vouch for: a track lost MID-FRAME (not out an edge) and never re-acquired nearby is reported as `[start, end]` seconds for human review, rather than guessed at. Pure over the track data (`TrackMath.gaps`), pinned.

## Measured (M-series, Release)

3.0, on Tears of Steel (Blender Foundation, CC BY 3.0, 1920×800 24 fps), M3 Max, nothing else running:

| Case | Result |
|---|---|
| 25 s scene, faces, rendered | 7.7 s — 2.4.0 took 6.7 s; the second detector and the shot scan cost 15 % |
| The same scene, `preview` (12 stills) | 5.6 s |
| The same scene, `people` | 7.8 s — 6 people, each a different actor |
| The whole film (12:14), `people` | 120 s (6× realtime) — 42 people; each lead has one number holding most of their screen time (28–84 s), and the same actors come back under extra numbers in dark or side-on shots; a few tiles are not faces (a vent, a robot) |
| `skipNumbers: [2]` on the scene | person 2 visible in every still, the other five covered; audio passed through, 25.0 s in and out |

Earlier releases:

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

- macOS 26+, Apple silicon; macOS 27 for the second face detector and for numbering the people in a video (`people`, numbers on video) — on 26 those throw `CensorError.unavailable` and everything else works
- Swift 6.2
- Frameworks: Vision, MediaIntelligence, CoreImage, AVFoundation, ImageIO, SensitiveContentAnalysis, Accelerate; fleet packages only — swift-video-forge (and through it swift-video-grade and swift-subtitle-kit), swift-image-forge (the contact sheets) and swift-stdout-silencer — nothing third-party

## License

MIT — see [LICENSE](LICENSE).
