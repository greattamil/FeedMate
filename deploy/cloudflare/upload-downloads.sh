#!/usr/bin/env bash
# Uploads the Android APK and Windows zip to the R2 bucket that
# downloads.<domain> serves from, and publishes version.json alongside
# them — the small static manifest apps/flutter/lib/core/app_update_service.dart
# polls to drive the in-app "Update available" prompt. Pure static
# metadata, no auth, no backend involvement — it lives next to the file it
# describes, same as the APK/zip themselves.
#
# Required env vars:
#   R2_BUCKET    e.g. feedmate-downloads
#
# Optional env vars (version.json fields):
#   VERSION_NAME    defaults to the version before '+' in
#                    apps/flutter/pubspec.yaml's `version:` line
#   VERSION_CODE    defaults to the build number after '+' in the same line
#   RELEASE_NOTES   defaults to empty (dialog just shows the version)
#   MIN_SUPPORTED_VERSION_CODE   optional; omitted (null) if unset — see
#                    app_update_service.dart's UpdateInfo doc comment on
#                    why this isn't enforced yet
#
# Usage:
#   R2_BUCKET=feedmate-downloads ./upload-downloads.sh \
#     path/to/app-release.apk path/to/FeedMate-Windows.zip

set -euo pipefail

: "${R2_BUCKET:?Set R2_BUCKET}"

APK_PATH="${1:?Usage: $0 <apk-path> <windows-zip-path>}"
ZIP_PATH="${2:?Usage: $0 <apk-path> <windows-zip-path>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBSPEC="$SCRIPT_DIR/../../apps/flutter/pubspec.yaml"

if [ -z "${VERSION_NAME:-}" ] || [ -z "${VERSION_CODE:-}" ]; then
  PUBSPEC_VERSION="$(grep -m1 '^version:' "$PUBSPEC" | sed 's/version:[[:space:]]*//')"
  VERSION_NAME="${VERSION_NAME:-${PUBSPEC_VERSION%+*}}"
  VERSION_CODE="${VERSION_CODE:-${PUBSPEC_VERSION#*+}}"
fi
RELEASE_NOTES="${RELEASE_NOTES:-}"

echo "Uploading $APK_PATH -> $R2_BUCKET/feedmate.apk ..."
wrangler r2 object put "$R2_BUCKET/feedmate.apk" \
  --file="$APK_PATH" --content-type=application/vnd.android.package-archive --remote

echo "Uploading $ZIP_PATH -> $R2_BUCKET/FeedMate-Windows.zip ..."
wrangler r2 object put "$R2_BUCKET/FeedMate-Windows.zip" \
  --file="$ZIP_PATH" --content-type=application/zip --remote

# An explicit path in the script's own directory, not mktemp — mktemp's
# path has repeatedly proven unreliable across Git-Bash-vs-native-Windows-
# binary boundaries in this project (wrangler.exe and python3.exe each
# silently resolving a POSIX-style /c/... path differently, or not at
# all). This file is never committed — deploy/.gitignore excludes it —
# and is removed at the end regardless. Built with plain bash/sed, not
# Python, for the same cross-runtime-path reason.
VERSION_JSON_PATH="$SCRIPT_DIR/.version.json.tmp"
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' '; }
MIN_SUPPORTED_JSON=""
if [ -n "${MIN_SUPPORTED_VERSION_CODE:-}" ]; then
  MIN_SUPPORTED_JSON=",\"min_supported_version_code\":$MIN_SUPPORTED_VERSION_CODE"
fi
printf '{"latest_version_code":%s,"latest_version_name":"%s","apk_url":"https://downloads.ramadas.me/feedmate.apk","release_notes":"%s"%s}' \
  "$VERSION_CODE" "$(json_escape "$VERSION_NAME")" "$(json_escape "$RELEASE_NOTES")" "$MIN_SUPPORTED_JSON" \
  > "$VERSION_JSON_PATH"
echo "Uploading version.json (v$VERSION_NAME, build $VERSION_CODE) -> $R2_BUCKET/version.json ..."
wrangler r2 object put "$R2_BUCKET/version.json" \
  --file="$VERSION_JSON_PATH" --content-type=application/json --remote
rm -f "$VERSION_JSON_PATH"

echo "Done."
