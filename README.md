# Video Editor

A native macOS video editor for trimming the start/end of a clip and creating smooth playback-speed curves from **1× to 10×**. Includes a player, immediate scrubbing, live edited duration, an audio waveform for finding speech, and an instant estimated output size. Original files are preserved.

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
- Click **Add Cut** at the bottom left or press **C** to split the blue filmstrip at the playhead. A new split removes no footage and focuses only the segment to its right. Drag its left handle left to shorten the preceding piece, or its right handle right to shorten the following piece. Only visible segment boundaries have handles; restoring a boundary into a gap cannot reveal old split seams inside that gap. The gap shows footage that playback and export skip; drag handles back toward the split to restore it. Gaps cannot be moved. Hover or click a gap to reveal one join button: it restores the removed footage and joins the surrounding segments. This action is undoable with U. Only the focused segment has a green outline and green boundary handles; click another segment to move focus, then press **D** or **X** (or click the trash button) to delete that segment. Click the undo icon or press **U** to undo the latest edit. Splits, deletions, handle drags, speed changes, and resets share one chronological undo history; a drag counts as one step.
- Click the graph to add speed points, then drag them to shape a smooth curve. The first and last points hold their speed out to the clip edges. Add 1× points around a faster section to return to normal playback. Select a point and use the trash icon to remove it.
- Scroll down over the speed graph to zoom its Y axis toward 1× for precise lower rates; scroll up to zoom out. Pinch also works. The selected speed is shown to three decimal places.
- Scroll over the filmstrip to zoom in time around the pointer. Pan using horizontal scrolling, Shift-scroll, or the scrollbar. The reset-zoom icon restores both views without changing edits; the reset-edits icon clears trimming, speed points, and cuts.
- Click the centered play/pause icon or press Space to preview continuously across splits and trimmed gaps. The smaller button to its left starts playback from the first remaining frame. Playback stops at the end of the whole edit. Preview uses a continuous composition with gaps already removed, so crossing a cut does not issue a seek. The time readout shows source position / edited duration. The right readout shows an approximate file size immediately, then the exact size after export.
- Use the bottom-right **folder** button to export beside the original, reveal the video in Finder, and close the editor. The **clipboard** button copies the exported video file for pasting into other apps and closes the editor. Both create a lasting `-edited.mp4` file beside the original, adding a number if that name is taken.
- The upper **1×–10× speed curve** starts folded. Click the **speaker** button below the file-size readout to smoothly expand or fold that section. The teal audio waveform stays visible above the filmstrip and shows louder sections and pauses. Click or drag it to scrub; it stays aligned with the video when zooming or panning. Removed sections are dimmed. Clips without audio show “No audio”.
- Audio starts muted, with only a small speaker icon to the left of the audio track. Click to unmute, then hover over the icon to reveal a volume slider over the waveform. Moving away hides the slider without reserving timeline space. Click the icon again to mute; unmuting restores the previous level. Changes apply live to playback and to saved/exported videos. Muted exports contain no audio track. Volume changes share the U undo history.
- Click **Save…** or press ⌘S to choose a new save location and keep editing. Save renders the current edit to MP4; the original recording cannot be overwritten. Closing an edit without exporting or saving keeps the original video and discards the edit.

Exports render at 30 fps. Audio follows speed, including pitch changes. Smoothstep interpolation joins speed points without overshoot; duration and export share the same 100 ms source slices with constant-rate coalescing. Video is rendered only when saving or exporting, so size estimation never blocks these actions. Zoom only changes the view.

## Develop and verify

```sh
swift test
./scripts/build.sh
"dist/Video Editor.app/Contents/MacOS/VideoEditor" --help
./scripts/test-video-editor.sh
```

The last command requires ffmpeg only to generate test fixtures. It exercises video with audio, silent video, and delayed audio, each at 1×, constant 10×, a smooth speed ramp, and a ramp with overlapping cuts. Checks cover duration, decodable frames, track counts, and preservation of source bytes. Playback tests additionally check continuous cut joins without player time jumps, restart, and paused scrubbing. Quit-shortcut tests cover confirmation, cancellation, and quick QQ. The media and playback tests are skipped by `swift test` unless `VIDEO_EDITOR_TEST_FIXTURE` points to a six-second 640×360 fixture.

GitHub Actions tests and builds the app on macOS, then uploads a zipped app artifact. The package has a UI executable (`VideoEditor`) and a media/model library (`VideoEditorCore`).
