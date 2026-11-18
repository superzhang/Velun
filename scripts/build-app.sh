#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
# A stable certificate identity is required for Keychain access to survive updates.
# Ad-hoc signatures identify a build by cdhash and must not be used for this app.
SIGNING_IDENTITY="$(scripts/signing-identity.sh)"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="${LUMA_APP_OUTPUT:-../Velun.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Luma" "$APP/Contents/MacOS/Luma"
cp LICENSE THIRD_PARTY.md "$APP/Contents/Resources/"
if [ -d "$BIN_DIR/Luma_Luma.bundle" ]; then
    ditto "$BIN_DIR/Luma_Luma.bundle" "$APP/Contents/Resources/Luma_Luma.bundle"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Luma</string>
<key>CFBundleIdentifier</key><string>local.luma.player</string>
<key>NSLocalNetworkUsageDescription</key><string>连接 NAS 和媒体服务器，并自动发现局域网中的 SMB、WebDAV、NFS 和媒体服务器。</string>
<key>NSBonjourServices</key><array><string>_smb._tcp</string><string>_nfs._tcp</string><string>_webdav._tcp</string><string>_webdavs._tcp</string><string>_webdav-ssl._tcp</string><string>_jellyfin._tcp</string></array>
<key>CFBundleIconFile</key><string>Luma.icns</string>
<key>CFBundleName</key><string>Velun</string>
<key>CFBundleDisplayName</key><string>Velun</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.19.3</string>
<key>CFBundleVersion</key><string>29</string>
<key>LSMinimumSystemVersion</key><string>27.2</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Resources/ThirdParty/rclone"
install -m 755 /opt/homebrew/bin/rclone "$APP/Contents/Helpers/rclone"
cp /opt/homebrew/opt/rclone/COPYING "$APP/Contents/Resources/ThirdParty/rclone/COPYING"
codesign --force --sign - "$APP/Contents/Helpers/rclone"
install -m 755 /opt/homebrew/bin/ffmpeg "$APP/Contents/Helpers/ffmpeg"
install -m 755 /opt/homebrew/bin/ffprobe "$APP/Contents/Helpers/ffprobe"
# Compile the Icon Composer document so macOS chooses its own mask, scale and appearance.
ICON_INFO="$(mktemp -t luma-icon-info)"
xcrun actool "$PWD/Assets/Luma.icon" --compile "$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target 27.2 --app-icon Luma \
    --output-partial-info-plist "$ICON_INFO"
python3 - "$APP/Contents/Info.plist" "$ICON_INFO" <<'PYICON'
import plistlib, sys
from pathlib import Path
info = Path(sys.argv[1])
metadata = plistlib.loads(info.read_bytes())
metadata.update(plistlib.loads(Path(sys.argv[2]).read_bytes()))
info.write_bytes(plistlib.dumps(metadata))
PYICON
rm "$ICON_INFO"
python3 scripts/bundle-libs.py "$APP"
codesign --force --sign - "$APP/Contents/Helpers/ffmpeg"
codesign --force --sign - "$APP/Contents/Helpers/ffprobe"
codesign --force --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built: $APP"
