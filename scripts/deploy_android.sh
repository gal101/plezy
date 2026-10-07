#!/usr/bin/env bash
# Build (optionally) and install the GalTV APK onto the connected Android
# devices — the TV and the phone — picking the right ABI per device.
#
# Why per-device ABIs: the Google TV Streamer is **32-bit only**
# (`ro.product.cpu.abilist = armeabi-v7a,armeabi`, `ro.zygote = zygote32`), so an
# arm64-only APK installs and then dies on its first frame, looking for
# `libflutter.so` in `armeabi-v7a`. The phone (Honor Magic V5) is arm64. The
# release APK is therefore built `--split-per-abi` and this script picks the file
# that matches each device's own `abilist`.
#
# Usage:
#   scripts/deploy_android.sh                     # install to every ready device
#   scripts/deploy_android.sh --build             # build first, then install
#   scripts/deploy_android.sh --device 192.168.100.154:5555
#   scripts/deploy_android.sh --connect 192.168.100.154:5555   # adb connect first
#   scripts/deploy_android.sh --force             # install even if unchanged
#   scripts/deploy_android.sh --list              # show what it would do
#
# The TV's address is DHCP; reserve it on the router (see
# `docs/server-setup-guide.md` §4). The pairing key lives on the device, so a
# code is only needed once — after a TV reboot, re-run with `--connect`.
#
# Tool paths: this box has `adb` from a WinGet package and Flutter in a twin SDK,
# and the shell it runs in may see either Windows-style (`/c/...`) or WSL-style
# (`/mnt/c/...`) paths with a different PATH. So both are resolved below, and an
# `.exe` adb gets native Windows paths (WSL does not translate arguments for you).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APK_DIR="$REPO_ROOT/build/app/outputs/flutter-apk"
STATE_DIR="$REPO_ROOT/build/.deploy_state"

build=false
force=false
list_only=false
device_filter=""
connect_to=""

while [ $# -gt 0 ]; do
  case "$1" in
    --build) build=true ;;
    --force) force=true ;;
    --list) list_only=true ;;
    --device) device_filter="${2:-}"; shift ;;
    --connect) connect_to="${2:-}"; shift ;;
    -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# First existing candidate wins: explicit env override, then PATH, then the
# known install locations in both path flavours.
resolve_tool() {
  local override="$1"; shift
  if [ -n "$override" ] && [ -x "$override" ]; then printf '%s' "$override"; return; fi
  local name="$1"; shift
  local on_path
  on_path="$(command -v "$name" 2>/dev/null || true)"
  if [ -n "$on_path" ]; then printf '%s' "$on_path"; return; fi
  local candidate
  for candidate in "$@"; do
    if [ -x "$candidate" ]; then printf '%s' "$candidate"; return; fi
  done
  printf ''
}

ADB="$(resolve_tool "${ADB:-}" adb \
  "${LOCALAPPDATA:-/nonexistent}/Microsoft/WinGet/Packages/Google.PlatformTools_"*/platform-tools/adb.exe \
  "${LOCALAPPDATA:-/nonexistent}/Android/sdk/platform-tools/adb.exe" \
  /c/Users/*/AppData/Local/Microsoft/WinGet/Packages/Google.PlatformTools_*/platform-tools/adb.exe \
  /mnt/c/Users/*/AppData/Local/Microsoft/WinGet/Packages/Google.PlatformTools_*/platform-tools/adb.exe \
  /c/Users/*/AppData/Local/Android/sdk/platform-tools/adb.exe \
  /mnt/c/Users/*/AppData/Local/Android/sdk/platform-tools/adb.exe)"
if [ -z "$ADB" ]; then
  echo "adb not found — set ADB=/path/to/adb" >&2
  exit 1
fi

FLUTTER_BIN="$(resolve_tool "${FLUTTER:-}" flutter \
  /c/Users/*/Desktop/Workspace/toolchains/flutter-*/bin/flutter.bat \
  /mnt/c/Users/*/Desktop/Workspace/toolchains/flutter-*/bin/flutter.bat \
  /c/Users/*/Desktop/Workspace/toolchains/flutter-*/bin/flutter \
  /mnt/c/Users/*/Desktop/Workspace/toolchains/flutter-*/bin/flutter)"

# A Windows adb.exe needs Windows paths; WSL does not translate for us.
native_path() {
  case "$ADB" in
    *.exe) if command -v wslpath >/dev/null 2>&1; then wslpath -w "$1"; else printf '%s' "$1"; fi ;;
    *)     printf '%s' "$1" ;;
  esac
}

if [ "$build" = true ]; then
  if [ -z "$FLUTTER_BIN" ]; then
    echo "flutter not found — set FLUTTER=/path/to/flutter" >&2
    exit 1
  fi
  echo "==> building release APKs (split per ABI)"
  "$FLUTTER_BIN" build apk --release --split-per-abi \
    --target-platform android-arm --target-platform android-arm64
fi

"$ADB" start-server >/dev/null 2>&1 || true
if [ -n "$connect_to" ]; then
  echo "==> adb connect $connect_to"
  "$ADB" connect "$connect_to" || true
fi

# `ro.product.cpu.abilist` decides which APK a device can actually run.
apk_for_abilist() {
  case "$1" in
    *arm64-v8a*)   echo "app-arm64-v8a-release.apk" ;;
    *armeabi-v7a*) echo "app-armeabi-v7a-release.apk" ;;
    *)             echo "" ;;
  esac
}

found=0
seen_devices=""
while read -r serial; do
  [ -n "$serial" ] || continue
  if [ -n "$device_filter" ] && [ "$serial" != "$device_filter" ]; then
    continue
  fi

  # One device can be reachable over several transports at once (the TV shows up
  # as both `192.168.100.154:5555` and its mDNS `…_adb-tls-connect._tcp` name),
  # so install once per physical device.
  hardware="$("$ADB" -s "$serial" shell getprop ro.serialno 2>/dev/null | tr -d '\r')"
  [ -n "$hardware" ] || hardware="$serial"
  case " $seen_devices " in
    *" $hardware "*) continue ;;
  esac
  seen_devices="$seen_devices $hardware"
  found=$((found + 1))

  abilist="$("$ADB" -s "$serial" shell getprop ro.product.cpu.abilist 2>/dev/null | tr -d '\r')"
  model="$("$ADB" -s "$serial" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
  apk_name="$(apk_for_abilist "$abilist")"

  if [ -z "$apk_name" ]; then
    echo "!! $serial ($model): abilist '$abilist' matches no shipped ABI — skipping"
    continue
  fi
  apk="$APK_DIR/$apk_name"
  if [ ! -f "$apk" ]; then
    echo "!! $serial ($model): $apk_name is missing — run with --build"
    continue
  fi

  hash="$(md5sum "$apk" | cut -d' ' -f1)"
  state_file="$STATE_DIR/$(printf '%s' "$hardware" | tr -c 'A-Za-z0-9._-' '_').md5"
  installed="$(cat "$state_file" 2>/dev/null || true)"

  echo "==> $serial ($model)"
  echo "    abilist $abilist -> $apk_name ($(du -h "$apk" | cut -f1))"

  if [ "$list_only" = true ]; then continue; fi

  if [ "$force" != true ] && [ "$hash" = "$installed" ]; then
    echo "    up to date ($hash) — skipped; use --force to reinstall"
    continue
  fi

  "$ADB" -s "$serial" install -r "$(native_path "$apk")"
  mkdir -p "$STATE_DIR"
  printf '%s' "$hash" > "$state_file"
  echo "    installed $hash"
done <<< "$("$ADB" devices | tr -d '\r' | awk 'NR>1 && $2 == "device" {print $1}')"

if [ "$found" -eq 0 ]; then
  echo "no ready device. TV: re-run with --connect 192.168.100.154:5555 (see docs/server-setup-guide.md §4)" >&2
  exit 1
fi
