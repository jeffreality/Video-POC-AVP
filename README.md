# Video POC for Apple Vision Pro

A visionOS proof of concept exploring three independent approaches to spatial video presentation:

1. **Temporal Echo** — a delayed, layered video effect that responds to viewer movement.
2. **Spatial Subtitles** — multilingual SRT subtitles that remain in the viewer’s lower field of view.
3. **Transparent Video** — offline chroma-key processing followed by HEVC-with-alpha playback on a RealityKit plane.

Each demo has its own media assets, coordinator, playback path, and immersive scene behavior. Opening one demo does not initialize the resources used by the other two.

## Demo overview

| Demo | Source assets | Key behavior |
| --- | --- | --- |
| Temporal Echo | `mockthru.mp4` | Plays one primary video plus seven delayed, muted echo layers. |
| Spatial Subtitles | `02b.mp4` and localized `02b.<language>.srt` files | Keeps the video anchored in the room while subtitles follow the viewer’s lower field of view. |
| Transparent Video | `Green-Screen-Sample.mp4` | Converts green-screen footage into a cached HEVC-with-alpha movie and displays it on a transparent 3D plane. |

## Requirements

- Xcode with the visionOS SDK
- An Apple Vision Pro for accurate tracking and playback testing
- Swift concurrency enabled
- RealityKit, ARKit, AVFoundation, Core Image, Core Media, and Core Video
- **visionOS 26 or later for transparent-video processing**

The temporal-echo and subtitle demos use established AVFoundation and RealityKit playback APIs. The chroma-key processor uses the newer asynchronous `AVAssetReader` provider and `AVAssetWriter` receiver APIs, which are runtime-gated to visionOS 26.

The Vision Pro Simulator may be useful for basic UI validation, but device testing is recommended for head tracking, immersive placement, HEVC-with-alpha encoding, transparency, depth behavior, and performance.

## Running the app

The main volumetric window presents three independent feature buttons:

- **Temporal Echo**
- **Spatial Subtitles**
- **Transparent Video**

Selecting a feature opens the shared mixed immersive space and loads only that feature’s view and coordinator. Feature buttons remain disabled until the current immersive demo closes.

The main window provides **Close Current Demo** while an immersive feature is open. The subtitle and transparent-video control panels also include an **X** button that stops their playback or processing and dismisses the immersive space.

---

## Temporal Echo

### Purpose

Temporal Echo creates a layered visual trail from one video. The front layer shows the current frame while seven additional layers play progressively older moments from the same source.

### Source

```text
Resources/mockthru.mp4
```

### How it works

The coordinator creates:

- one audible `AVQueuePlayer` for the current video;
- seven muted `AVQueuePlayer` instances for delayed echoes;
- one `AVPlayerLooper` per player; and
- one persistent RealityKit `VideoMaterial` per video layer.

The delayed players use these offsets:

```text
0.09, 0.17, 0.27, 0.40, 0.57, 0.78, and 1.04 seconds
```

The effect updates entity transforms rather than rebuilding textures.

### Motion behavior

The echo spread responds to:

- the viewer’s position relative to the video;
- recent viewer movement velocity;
- a smoothed motion value to reduce jitter;
- progressively larger offsets for older layers; and
- subtle per-layer movement and scale variation.

The players are periodically checked for drift. An echo player is only seek-corrected when it differs from its intended delay by more than the configured threshold.

### Current limitations

- Each echo is still a separately decoded video player, so the effect is not free.
- The exact appearance depends on video frame rate, source compression, and device load.
- This POC does not currently expose temporal-echo tuning controls in the interface.

Most visual tuning values are near the top of:

```text
Coordinators/TemporalEchoCoordinator.swift
```

---

## Spatial Subtitles

### Purpose

Spatial Subtitles separates the video from its captions:

- the video remains anchored in the room; and
- the subtitles remain available in the viewer’s lower field of view, even when the viewer turns away from the video.

This allows the content to feel spatially placed without forcing the viewer to keep looking directly at the screen to follow dialogue.

### Sources

```text
Resources/02b.mp4
Resources/02b.ar.srt
Resources/02b.de.srt
Resources/02b.en.srt
Resources/02b.fr.srt
Resources/02b.ja.srt
Resources/02b.ko.srt
Resources/02b.zh.srt
```

### Supported languages

| Code | Language |
| --- | --- |
| `en` | English |
| `ar` | العربية |
| `de` | Deutsch |
| `fr` | Français |
| `ja` | 日本語 |
| `ko` | 한국어 |
| `zh` | 中文 |

The language menu only shows subtitle languages whose SRT files were found and parsed successfully.

### Controls

The control capsule below the video includes:

- play or pause;
- a globe menu for subtitle language selection; and
- an X button to close the demo and return to the main menu.

Changing languages updates the current subtitle immediately without restarting the video.

### Subtitle placement

The video is initially positioned about 1.3 meters in front of the viewer. The subtitle attachment is independently updated to remain approximately:

- 0.78 meters in front of the viewer; and
- 0.17 meters below eye level.

Position smoothing reduces visible vibration from small tracking changes. A RealityKit `BillboardComponent` keeps the subtitle card facing the viewer.

Arabic automatically switches the SwiftUI layout direction to right-to-left.

### SRT support

The parser supports:

- UTF-8 files;
- an optional byte-order mark;
- Windows, Unix, and classic Mac line endings;
- comma or period millisecond separators;
- optional numeric cue identifiers;
- multiline cue text; and
- automatic sorting by cue start time.

Malformed or empty cue blocks are skipped rather than terminating playback.

### Relevant files

```text
Coordinators/SpatialSubtitlesCoordinator.swift
Models/SubtitleModels.swift
Services/SRTParser.swift
Views/SpatialSubtitlesVideoPanelView.swift
Views/Subviews/SpatialSubtitleControlsView.swift
```

---

## Transparent Video

### Purpose

The Transparent Video demo converts conventional green-screen footage into a reusable movie with an alpha channel, then displays the keyed subject as a texture on a RealityKit plane.

The conversion happens before transparent playback. It is not a live chroma-key shader applied to every frame during display.

### Source

```text
Resources/Green-Screen-Sample.mp4
```

The configured source name is defined in:

```swift
static let sourceResourceName = "Green-Screen-Sample"
```

The coordinator accepts either an `.mp4` or `.mov` file with that base name.

### POC defaults

The defaults are tuned for the current `Green-Screen-Sample.mp4` footage:

| Setting | Default | Recommended slider range |
| --- | ---: | ---: |
| Tolerance | `0.28` | `0.03...0.53` |
| Edge softness | `0.25` | `0.01...0.49` |
| Green spill | `1.00` | `0.00...1.00` |

These tolerance and edge-softness ranges place the tuned values near the middle of their sliders, leaving room to make the key either stricter or more aggressive.

Green-spill suppression remains capped at `1.0` because the processor clamps it to the meaningful `0...1` range. Values above `1.0` would not produce an additional effect.

The same defaults should be kept in both:

```text
Coordinators/TransparentVideoCoordinator.swift
Models/ChromaKeySettings.swift
```

### Controls

The transparent-video panel includes:

- play or pause;
- processing status;
- **Process Again**;
- an X button to close the demo;
- tolerance;
- edge softness; and
- green-spill suppression.

While processing, the progress bar appears below the primary button row so it does not compress the status text or cause **Process Again** to wrap.

Slider changes do not alter the currently playing movie in real time. After changing settings, select **Process Again** to produce and load a new keyed version.

### Processing pipeline

The processor:

1. Loads `Green-Screen-Sample.mp4` with `AVURLAsset`.
2. Reads the source video as BGRA pixel buffers using `AVAssetReader`.
3. Creates a reusable 64×64×64 Core Image color cube.
4. Compares normalized color proportions to the configured green key color.
5. Generates a soft alpha transition using tolerance and edge-softness values.
6. Reduces green contamination in partially transparent edge pixels.
7. Renders premultiplied-alpha BGRA frames.
8. Writes the result as HEVC with alpha in a `.mov` container.
9. Passes through the source audio track when one is present.
10. Validates the staged movie before promoting it to the cache.

Normalized chromaticity is used instead of brightness-dependent raw chroma. This allows darker and brighter areas of the same green screen to be treated as the same background color more consistently.

### Safe writer sequencing

The AVFoundation writer is started in this order:

1. `writer.start()`
2. `writer.startSession(atSourceTime: .zero)`
3. `reader.start()`
4. begin video and audio receiver tasks

No video or audio sample is appended before the writer’s media timeline has started.

### Cache and reprocessing behavior

Processed movies are stored in the app’s caches directory. The cache filename includes:

- processing-pipeline version;
- source file size;
- source modification date;
- tolerance;
- edge softness; and
- spill suppression.

Changing the source or any processing value therefore creates a distinct cache result.

The processor writes to a unique staging file first. The final cache file is replaced only after the staged movie has been validated as playable and confirmed to contain:

- a valid video track;
- a usable duration; and
- an audio track when the source included audio.

Selecting **Process Again** does not delete or detach the last successful movie before the new result is ready. The previous result can remain visible and audible during conversion. If conversion fails, the previous successful cache remains intact.

### RealityKit playback behavior

The transparent result is displayed using `VideoMaterial` on a RealityKit plane.

The plane and material are configured to avoid two common transparent-video problems:

- the plane is oriented toward the viewer and material face culling is disabled; and
- transparent pixels do not write an invisible rectangle into the scene depth buffer.

### Tuning tradeoffs

The current defaults are intentionally aggressive enough to clean up the green-screen edges in the sample. As a result, similarly colored or partially green subject details—such as portions of a jacket—may become partially transparent.

General guidance:

- Increase **Tolerance** to remove more green, at the risk of removing subject colors.
- Increase **Edge softness** to smooth the matte, at the risk of thinning fine detail.
- Increase **Green spill** to neutralize green edges without directly increasing transparency.

This is a POC-wide key rather than a production rotoscoping system. A production implementation may need per-shot settings, garbage mattes, edge-aware refinement, color-space handling, or a learned segmentation model.

### Relevant files

```text
Coordinators/TransparentVideoCoordinator.swift
Models/ChromaKeySettings.swift
Services/ChromaKeyVideoProcessor.swift
Views/TransparentVideoPanelView.swift
Views/Subviews/TransparentVideoControlsView.swift
```

---

## Architecture

### App state and navigation

`AppModel` tracks:

- the selected feature;
- the shared immersive-space identifier; and
- whether the immersive space is closed, transitioning, or open.

`Video_POCApp` opens one mixed immersive space and selects the appropriate feature view based on `AppModel.selectedFeature`.

### Feature isolation

Each demo owns a separate coordinator:

```text
TemporalEchoCoordinator
SpatialSubtitlesCoordinator
TransparentVideoCoordinator
```

The feature’s coordinator is created only when its SwiftUI panel view is active. Leaving the immersive space pauses playback, cancels update or processing tasks, and releases the feature view.

### RealityView attachments

The subtitle and transparent-video interfaces use SwiftUI views rendered as RealityKit `ViewAttachmentEntity` instances.

Because the attachment’s natural visible face is opposite the local face produced by the panel’s `look(at:)` transform, the control attachments are rotated 180 degrees around their vertical axis so their buttons face the viewer.

The subtitle text is not a child of the video panel. It is attached to the root scene so it can move independently with the viewer.

## Troubleshooting

### A video or subtitle file is reported missing

- Confirm the exact filename and extension.
- Confirm target membership.
- Check **Copy Bundle Resources**.
- Clean the build folder and reinstall the app.
- Check whether the resource was copied inside `Resources` or flattened into the bundle root; the code supports both.

### The subtitle language does not appear

- Confirm the file follows the `02b.<code>.srt` naming convention.
- Confirm the language code exists in `SubtitleLanguage`.
- Confirm the file is valid UTF-8 and contains at least one valid cue.
- Check the Xcode console for an SRT parsing message.

### Transparent video processing is unavailable

The processor requires visionOS 26 or later. On an older runtime, the feature reports that transparent-video preparation is unsupported.

### Processing completes but the transparent video is invisible

Confirm that the transparent-video coordinator still:

- rotates the generated plane toward the viewer;
- sets `VideoMaterial.faceCulling = .none`; and
- sets `VideoMaterial.writesDepth = false`.

Hearing audio with no visible plane usually indicates a geometry orientation, face-culling, or material-display issue rather than an audio or reader failure.

### Process Again produces a black or silent result

Confirm that the current implementation:

- writes to a staging file;
- preserves the previous player during processing;
- validates the output before publishing it; and
- replaces the cache only after successful completion.

Do not delete the currently playing cache file before the replacement is ready.

### Green remains around the subject

Increase tolerance or edge softness, then select **Process Again**. The current sample defaults are:

```text
Tolerance:     0.28
Edge softness: 0.25
Green spill:   1.00
```

### Parts of the subject become transparent

The key is overlapping the subject’s colors. Reduce tolerance first, then reduce edge softness if necessary. Strong green-spill suppression can remain enabled because it primarily adjusts color contamination rather than alpha.

### Temporal Echo remains expensive

The revised implementation avoids per-frame texture creation, but it still decodes eight synchronized video streams. Reduce the number of echo delays or use a smaller source video when testing performance limits.

## Current POC limitations

- The temporal-echo effect has fixed tuning values and no in-scene controls.
- Subtitle filenames are tied to the `02b` sample naming convention.
- Transparent-video processing is offline rather than real-time.
- Chroma-key settings apply to the entire movie rather than varying by shot or frame.
- The key color is fixed to pure green in the UI.
- HEVC-with-alpha support and performance must be validated on the target device.
- Aggressive chroma-key settings can remove subject pixels that resemble the background.
- The app is intended as a focused technical demonstration, not a production media authoring workflow.

## Possible next steps

- Add temporal-echo intensity and delay controls.
- Allow users to select video and subtitle assets from Files or Photos.
- Discover subtitle tracks dynamically instead of relying on a fixed base filename.
- Add subtitle size, vertical offset, background opacity, and accessibility controls.
- Add a chroma-key color picker and live still-frame preview.
- Save named chroma-key presets per source video.
- Move chroma keying to a real-time Metal shader for interactive adjustment.
- Add person segmentation or edge refinement to protect clothing and fine details.
- Add automated tests for SRT parsing, cache signatures, output validation, and chroma-cube generation.

## Notes

This project is a proof of concept for evaluating spatial presentation techniques on Apple Vision Pro. Each experiment is deliberately isolated so its technical approach, performance, usability, and visual effect can be assessed independently.
