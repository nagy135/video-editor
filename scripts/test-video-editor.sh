#!/bin/bash
# ffmpeg is a test-fixture generator only; the app uses native AVFoundation.
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_directory="$(mktemp -d)"
trap 'rm -rf "$fixture_directory"' EXIT
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i testsrc2=size=640x360:rate=30 \
    -f lavfi -i sine=frequency=440:sample_rate=48000 \
    -t 6 -c:v libx264 -pix_fmt yuv420p -c:a aac "$fixture_directory/audio.mp4"
ffmpeg -hide_banner -loglevel error -y -i "$fixture_directory/audio.mp4" \
    -an -c:v copy "$fixture_directory/silent.mp4"
ffmpeg -hide_banner -loglevel error -y -i "$fixture_directory/audio.mp4" \
    -itsoffset 0.7 -i "$fixture_directory/audio.mp4" \
    -map 0:v -map 1:a -c copy "$fixture_directory/delayed-audio.mp4"
for fixture in audio silent delayed-audio; do
    VIDEO_EDITOR_TEST_FIXTURE="$fixture_directory/$fixture.mp4" swift test
done
