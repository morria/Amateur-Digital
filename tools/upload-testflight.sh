#!/usr/bin/env bash
#
# Upload Amateur Digital to TestFlight from the command line.
#
# Auth: uses the Xcode-signed-in Apple Developer account for team 7Q2SS8772K
#       (Xcode → Settings → Accounts). No API key / app-specific password needed.
#       -allowProvisioningUpdates auto-creates the iOS Distribution cert/profile.
#
# Prereqs (one-time):
#   1. Apple Developer membership with the current Program License Agreement
#      accepted at https://developer.apple.com/account. An unaccepted update blocks
#      uploads with "PLA Update available" and a misleading
#      "No signing certificate 'iOS Distribution' found" side effect.
#   2. Signed-in Xcode account for the team (or an ASC API key .p8).
#   3. An App Store Connect app record for com.w2asm.AmateurDigital
#      (only Apple's website can create this).
#
# NOTE: This repo's Xcode project is committed directly (NOT xcodegen-generated),
#       so there is no `xcodegen generate` step.
#
# Usage: tools/upload-testflight.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/AmateurDigital/AmateurDigital.xcodeproj"
SCHEME="AmateurDigital"
TEAM_ID="7Q2SS8772K"

BUILD="$(date +%Y%m%d%H%M)"            # unique, monotonic build number
ARCHIVE="/tmp/AmateurDigital-$BUILD.xcarchive"
EXPORT_DIR="/tmp/AmateurDigital-upload-$BUILD"
EXPORT_OPTS="/tmp/AmateurDigital-ExportOptions-$BUILD.plist"

cat > "$EXPORT_OPTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM_ID</string>
</dict>
</plist>
PLIST

echo "==> Archiving build $BUILD (Release)…"
xcodebuild archive \
  -project "$PROJECT" -scheme "$SCHEME" \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  -allowProvisioningUpdates -quiet

echo "==> Exporting + uploading to TestFlight…"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTS" \
  -allowProvisioningUpdates

echo "==> ** Done. ** Apple processes the build in ~5–15 min, then it appears in"
echo "    App Store Connect → TestFlight (build $BUILD)."
