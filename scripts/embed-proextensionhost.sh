#!/bin/bash
# Xcode post-build phase: copies ProExtensionHost.framework into the extension
# bundle when PRO_EXTENSION_HOST_FRAMEWORK is set (see configure-workflow-sdk.sh).
set -euo pipefail
if [ -z "${PRO_EXTENSION_HOST_FRAMEWORK:-}" ] || [ ! -d "${PRO_EXTENSION_HOST_FRAMEWORK}" ]; then
  echo "note: ProExtensionHost.framework not configured; timeline integration will be unavailable in this build."
  exit 0
fi
dest="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
mkdir -p "$dest"
rsync -a --delete "${PRO_EXTENSION_HOST_FRAMEWORK}" "$dest/"
if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --options runtime --timestamp=none \
    "$dest/$(basename "${PRO_EXTENSION_HOST_FRAMEWORK}")"
fi
echo "Embedded $(basename "${PRO_EXTENSION_HOST_FRAMEWORK}")"
