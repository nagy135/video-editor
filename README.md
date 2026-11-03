# Video Editor

A native macOS video editor for trimming the start/end of a clip and creating smooth playback-speed curves from **1× to 10×**. Includes a player, immediate scrubbing, live edited duration, and actual output size calculated by a background render. Original files are preserved.

Requires macOS 15+ and Xcode 16+ / Swift 6+. Uses AppKit, SwiftUI, and AVFoundation; no third-party runtime dependencies.

## Install

```sh
git clone git@github.com:nagy135/video-editor.git
cd video-editor
./scripts/install.sh
```

This builds and installs `/Applications/Video Editor.app` with its own filmstrip-and-speed-curve icon. It does not launch the app. Close the editor before updating. Local builds are ad-hoc signed by default; set `SIGNING_IDENTITY` to use an existing certificate. Downloaded builds may need Developer ID signing and notarization for distribution; building locally is supported.

## Open a video

```sh
"/Applications/Video Editor.app/Contents/MacOS/VideoEditor" "/path/to/video.mp4"
```

A bare path is the normal command-line interface. `--edit-video /path/to/video.mp4` also works. Multiple paths open multiple windows. Launching the app from Applications or running it without arguments opens a start window: drop a video anywhere in it, click **Open Video…** (or the background) for the Finder picker, or click **Paste** / press ⌘V. Paste accepts videos copied in Finder, local file paths (including spaces and `~`), and `file://` URLs. The app also appears in Finder’s **Open With** menu for videos. Closing an editor leaves the app running without reopening the start window; that window appears only on a launch without a file argument. Use ⌘O to open another clip and ⌘W to close a window. Press Q to show “Press Q again to discard and quit”; press Q again to quit or Esc to cancel. A quick QQ quits directly without flashing the prompt. ⌘Q also quits.

Other apps can locate bundle identifier `com.nagy135.video-editor` with `NSWorkspace` and launch it using `NSWorkspace.OpenConfiguration.arguments = [video.path]`. Use `createsNewApplicationInstance = true` to pass new command-line arguments even when an editor is already open. [Mac Screen Recorder](https://github.com/nagy135/mac-screen-recorder) uses this interface for its ⌘⌥⇧T shortcut.

## Editing

- Drag either filmstrip handle to trim. Drag inside the filmstrip to scrub the preview.
- Click **Add Cut** at the bottom left or press **C** to split the blue filmstrip at the playhead. A new split removes no footage. Drag its left handle left to shorten the preceding piece, or its right handle right to shorten the following piece. The gap shows footage that playback and export skip; drag handles back toward the split to restore it. Select a split handle and click the adjacent undo icon or press **U** to rejoin it; with none selected, undo rejoins the most recently added split.
- Click the graph to add speed points, then drag them to shape a smooth curve. The first and last points hold their speed out to the clip edges. Add 1× points around a faster section to return to normal playback. Select a point and use the trash icon to remove it.
- Scroll down over the speed graph to zoom its Y axis toward 1× for precise lower rates; scroll up to zoom out. Pinch also works. The selected speed is shown to three decimal places.
- Scroll over the filmstrip to zoom in time around the pointer. Pan using horizontal scrolling, Shift-scroll, or the scrollbar. The reset-zoom icon restores both views without changing edits; the reset-edits icon clears trimming, speed points, and cuts.
- Click the centered play/pause icon or press Space to preview continuously across splits and trimmed gaps. The smaller button to its left starts playback from the first remaining frame. Playback stops at the end of the whole edit. Preview uses a continuous composition with gaps already removed, so crossing a cut does not issue a seek. The time readout shows source position / edited duration. The right readout shows actual rendered file size, or “Calculating…” while rendering.
- Click **Save…** or press ⌘S when rendering finishes. Save writes that exact rendered MP4; the original recording cannot be overwritten. Closing an unsaved edit keeps the original video and discards the edit.

Exports render at 30 fps. Audio follows speed, including pitch changes. Smoothstep interpolation joins speed points without overshoot; duration and export share the same 100 ms source slices with constant-rate coalescing. Background rendering is cancelled and restarted after edits. Zoom only changes the view.

## Develop and verify

```sh
swift test
./scripts/build.sh
"dist/Video Editor.app/Contents/MacOS/VideoEditor" --help
./scripts/test-video-editor.sh
```

The last command requires ffmpeg only to generate test fixtures. It exercises video with audio, silent video, and delayed audio, each at 1×, constant 10×, a smooth speed ramp, and a ramp with overlapping cuts. Checks cover duration, decodable frames, track counts, and preservation of source bytes. Playback tests additionally check continuous cut joins without player time jumps, restart, and paused scrubbing. Quit-shortcut tests cover confirmation, cancellation, and quick QQ. The media and playback tests are skipped by `swift test` unless `VIDEO_EDITOR_TEST_FIXTURE` points to a six-second 640×360 fixture.

GitHub Actions tests and builds the app on macOS, then uploads a zipped app artifact. The package has a UI executable (`VideoEditor`) and a media/model library (`VideoEditorCore`).
