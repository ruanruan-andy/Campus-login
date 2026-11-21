#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
build_dir="$(mktemp -d)"
mount_path=""
cleanup() {
    if [[ -n "$mount_path" ]]; then
        hdiutil detach "$mount_path" -quiet || true
    fi
    rm -rf "$build_dir"
}
trap cleanup EXIT
app="$build_dir/Campus Login.app"
for architecture in arm64 x86_64; do
    swiftc -parse-as-library -target "$architecture-apple-macos13.0" -O CampusLogin.swift -o "$build_dir/$architecture"
done
mkdir -p "$build_dir/Campus Login.app/Contents/MacOS" "$build_dir/Campus Login.app/Contents/Resources"
lipo -create "$build_dir/arm64" "$build_dir/x86_64" -output "$build_dir/Campus Login.app/Contents/MacOS/CampusLogin"
cp Info.plist "$build_dir/Campus Login.app/Contents/Info.plist"
cp portal.py AppIcon.icns "$build_dir/Campus Login.app/Contents/Resources/"
codesign --force --sign - "$build_dir/Campus Login.app"
codesign --verify --deep --strict "$build_dir/Campus Login.app"
mkdir -p dist

installer_dir="$build_dir/installer"
mkdir -p "$installer_dir"
ditto "$app" "$installer_dir/Campus Login.app"
ln -s /Applications "$installer_dir/Applications"
mkdir -p "$installer_dir/.background"
swift packaging/background.swift "$installer_dir/.background/background.png"

tools_python=".build/dmg-tools/bin/python3"
if [[ ! -x "$tools_python" ]]; then
    python3 -m venv .build/dmg-tools
fi
if ! "$tools_python" -c 'import ds_store, mac_alias' 2>/dev/null; then
    .build/dmg-tools/bin/pip install ds-store==1.3.1 mac-alias==2.2.2
fi
hdiutil create -volname "校园网登录" -srcfolder "$installer_dir" -fs HFS+ -format UDRW "$build_dir/installer.dmg"
mount_path="$build_dir/volume"
mkdir -p "$mount_path"
hdiutil attach "$build_dir/installer.dmg" -mountpoint "$mount_path" -nobrowse -noautoopen -quiet
swift packaging/bookmark.swift "$mount_path/.background/background.png" "$mount_path/.background/bookmark"
"$tools_python" packaging/layout.py "$mount_path"
hdiutil detach "$mount_path" -quiet
mount_path=""
hdiutil convert "$build_dir/installer.dmg" -o "$build_dir/final.dmg" -format UDZO
mv -f "$build_dir/final.dmg" "dist/Campus Login.dmg"
printf 'Installer %s\n' "$PWD/dist/Campus Login.dmg"
