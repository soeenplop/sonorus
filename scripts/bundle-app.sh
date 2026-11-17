#!/bin/sh
set -eu

build_dir=${1:?Usage: bundle-app.sh BUILD_DIR}
binary_dir=$(swift build --scratch-path "$build_dir" --cache-path "$build_dir/cache/packages" --disable-sandbox --show-bin-path)
app_dir="$build_dir/Sonorus.app"
mkdir -p "$app_dir/Contents/MacOS"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp "$binary_dir/Sonorus" "$app_dir/Contents/MacOS/Sonorus"
plutil -lint "$app_dir/Contents/Info.plist"
codesign --force --sign - "$app_dir"
printf 'App: %s\n' "$app_dir"
