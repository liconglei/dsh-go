#!/usr/bin/env bash
# arm64 release build with a monotonic internal build number.
#
#   tooling/release-arm64.sh                    # versionCode = last + 1
#   tooling/release-arm64.sh --build-name 1.2.0 # only when the user decides
#   tooling/release-arm64.sh --dry-run          # print, write nothing
#
# Rules this script enforces:
#   * The internal code (versionCode) goes up by exactly one per package.
#     A failed build still consumes its number: never reuse one.
#   * The name users see (versionName) changes only when --build-name is given;
#     otherwise app/pubspec.yaml's version is used unchanged.
#   * Debug builds are not counted.
#
# The counter lives in tooling/.release-build-number (not committed). Without
# it the script starts from 0, so seed it once with the last shipped code.
set -euo pipefail

ROOT="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/app"
COUNTER="$ROOT/tooling/.release-build-number"

name=''
dry=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-name)
      name=${2:?--build-name needs a value}
      shift 2
      ;;
    --dry-run)
      dry=1
      shift
      ;;
    -h | --help)
      sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "release-arm64: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

pub_name=$(sed -n 's/^version: \([^+]*\).*/\1/p' "$APP/pubspec.yaml" | head -1)
[[ -n $name ]] || name=$pub_name
[[ -n $name ]] || {
  echo "release-arm64: no version name in $APP/pubspec.yaml" >&2
  exit 1
}

last=0
if [[ -f $COUNTER ]]; then
  last=$(tr -dc '0-9' <"$COUNTER" || true)
fi
last=${last:-0}
next=$((last + 1))

echo "release-arm64: $name+$next (previous $last)"
if [[ $dry == 1 ]]; then
  echo "  dry run: nothing written, nothing built"
  exit 0
fi

# Written before the build: a number is spent even if Gradle fails.
printf '%s\n' "$next" >"$COUNTER"

cd "$APP"
PUB_CACHE=${PUB_CACHE:-D:/pub-cache} flutter build apk \
  --release \
  --flavor arm64 \
  --target-platform android-arm64 \
  --build-name "$name" \
  --build-number "$next" \
  --dart-define="DSH_APP_VERSION=$name+$next" \
  --android-skip-build-dependency-validation

apk="$APP/build/app/outputs/flutter-apk/app-arm64-release.apk"
echo
echo "release-arm64: $apk"
ls -la "$apk" | awk '{printf "  size:   %.1f MB\n", $5/1048576}'
sha256sum "$apk" | awk '{print "  sha256: " $1}'
