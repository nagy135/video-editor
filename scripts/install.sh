#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
destination='/Applications/Video Editor.app'
if [ -L "$destination" ]; then
    printf 'Refusing to replace a symbolic link at %s.\n' "$destination" >&2
    exit 1
fi
if [ -e "$destination" ]; then
    installed_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")"
    if [ "$installed_id" != 'com.nagy135.video-editor' ]; then
        printf 'Refusing to replace a different app.\n' >&2
        exit 1
    fi
fi
if pgrep -u "$(id -u)" -f '/VideoEditor([[:space:]]|$)' >/dev/null; then
    printf 'Close Video Editor before installing an update.\n' >&2
    exit 1
fi
./scripts/build.sh
staging_directory="$(mktemp -d '/Applications/.video-editor-install.XXXXXX')"
cleanup() {
    result=$?
    if [ "$result" -ne 0 ] && [ -d "$staging_directory/previous.app" ]; then
        if [ -e "$destination" ]; then mv "$destination" "$staging_directory/failed.app"; fi
        mv "$staging_directory/previous.app" "$destination"
    fi
    rm -rf "$staging_directory"
}
trap cleanup EXIT
ditto 'dist/Video Editor.app' "$staging_directory/Video Editor.app"
codesign --verify --strict "$staging_directory/Video Editor.app"
if [ -e "$destination" ]; then mv "$destination" "$staging_directory/previous.app"; fi
mv "$staging_directory/Video Editor.app" "$destination"
codesign --verify --strict "$destination"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$destination"
printf '\nInstalled %s\n' "$destination"
