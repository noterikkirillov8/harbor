#!/usr/bin/env bash
# Builds Harbor (Release, signed with Erik's local certificate) and makes it the only Harbor:
# installed in /Applications and started.
#
#   ./scripts/install.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${HOME}/Library/Developer/Xcode/DerivedData/HarborRel"
BUILT="${DERIVED}/Build/Products/Release/Harbor.app"
TARGET="/Applications/Harbor.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

# Erik's local identity when present; ad-hoc signing for everyone else.
IDENTITY="Erik Local Signing"
security find-identity -v -p codesigning | grep -q "$IDENTITY" || IDENTITY="-"

echo "Building (Release)..."
cd "${REPO_ROOT}/Harbor"
xcodegen >/dev/null
xcodebuild -scheme Harbor -configuration Release -derivedDataPath "${DERIVED}" CODE_SIGN_IDENTITY="${IDENTITY}" -quiet build

if [ -z "${NO_OPEN:-}" ]; then
echo "Quitting Harbor..."
osascript -e 'tell application id "com.erikkirillov.Harbor" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do pgrep -x Harbor >/dev/null || break; sleep 1; done
pkill -x Harbor 2>/dev/null || true
fi

echo "Installing in ${TARGET}..."
rm -rf "${TARGET}"
ditto "${BUILT}" "${TARGET}"
"${LSREGISTER}" -u "${BUILT}" >/dev/null 2>&1 || true
"${LSREGISTER}" -f "${TARGET}" >/dev/null 2>&1 || true

if [ -z "${NO_OPEN:-}" ]; then
    open "${TARGET}"
    echo "Harbor is running from ${TARGET}."
else
    echo "Installed ${TARGET} (NO_OPEN set: not started)."
fi
