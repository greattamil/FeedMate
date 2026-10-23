#!/usr/bin/env bash
# Uploads the Android APK and Windows zip to the R2 bucket that
# downloads.<domain> serves from.
#
# Required env vars:
#   R2_BUCKET    e.g. feedmate-downloads
#
# Usage:
#   R2_BUCKET=feedmate-downloads ./upload-downloads.sh \
#     path/to/app-release.apk path/to/FeedMate-Windows.zip

set -euo pipefail

: "${R2_BUCKET:?Set R2_BUCKET}"

APK_PATH="${1:?Usage: $0 <apk-path> <windows-zip-path>}"
ZIP_PATH="${2:?Usage: $0 <apk-path> <windows-zip-path>}"

echo "Uploading $APK_PATH -> $R2_BUCKET/feedmate.apk ..."
wrangler r2 object put "$R2_BUCKET/feedmate.apk" \
  --file="$APK_PATH" --content-type=application/vnd.android.package-archive --remote

echo "Uploading $ZIP_PATH -> $R2_BUCKET/FeedMate-Windows.zip ..."
wrangler r2 object put "$R2_BUCKET/FeedMate-Windows.zip" \
  --file="$ZIP_PATH" --content-type=application/zip --remote

echo "Done."
