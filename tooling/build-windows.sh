#!/usr/bin/env bash
# Builds the Windows desktop client. Unlike the phone app this build always
# uses the remote-only entry point: no on-device engine, no Android channels.
#
#   tooling/build-windows.sh                        release, x86_64
#   tooling/build-windows.sh --debug                debug, x86_64
#   tooling/build-windows.sh --dry-run              print the command, build nothing
#   tooling/build-windows.sh -- --dart-define=K=V  extra flags for `flutter build windows`
#
# The server URL and Basic credentials are entered by the user in the app's
# HTTP host form; they are never baked into the build or read from the environment.
set -euo pipefail

ROOT=$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
APP="$ROOT/app"
TARGET='lib/main_desktop.dart'
mode=release
dry=0
extra=()
while (($#)); do
  case "$1" in
    --release | --debug | --profile) mode=${1#--}; shift ;;
    --dry-run) dry=1; shift ;;
    --) shift; extra+=("$@"); break ;;
    *) echo "build-windows: unknown argument: $1" >&2; exit 1 ;;
  esac
done

cmd=(flutter build windows "--$mode" -t "$TARGET" "${extra[@]}")
if (( dry )); then
  echo "(cd '$APP' && ${cmd[*]})"
  exit 0
fi
cd "$APP"
"${cmd[@]}"
