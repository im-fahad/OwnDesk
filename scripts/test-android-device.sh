#!/usr/bin/env bash
# End-to-end test of the Android app on a real phone, against a real host on this Mac.
#
#   scripts/test-android-device.sh                      the only phone adb sees, or the first
#   ANDROID_SERIAL=<serial> scripts/test-android-device.sh
#   SKIP_BUILD=1 scripts/test-android-device.sh         reuse the APK and agent already built
#   SCREENSHOTS=/tmp/shots scripts/test-android-device.sh
#
# The phone must be connected over adb (USB, or wireless debugging) with a debug build allowed, and
# on the same network as this Mac. Nothing on either device is left changed: the host is a headless
# agent with a throwaway identity, the SSH server is this Mac's own sshd run as you on a spare port
# with a key file of its own, and the phone forgets the test host at the end.
#
# Two stages, each with the phone driven by the debug build's intent extras:
#   session   pairs, opens the host's screen (a synthetic 1920x1080 pattern) and taps it; the host
#             prints the input instead of injecting it, so nothing on this Mac moves
#   terminal  asks the host to allow the phone's terminal key (answered yes here, as a person would),
#             then opens a terminal with no host key question and runs a command that writes a file
#
# The SSH server listens on this Mac's local address only, takes no passwords, and lets in only the
# key the phone asked for, for as long as the test runs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-47620}"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB_BIN="$SDK/platform-tools/adb"
APP="io.github.im_fahad.owndesk"
WORK="$(mktemp -d -t owndesk-android-e2e)"
LOG="$WORK/agent.log"
FIFO="$WORK/agent.in"
AGENT_PID=""
SSHD_PID=""
HOST_FP=""

# A wireless-debugging serial contains spaces, so the phone is addressed by transport id instead.
if [[ -n "${ANDROID_SERIAL:-}" ]]; then
  TRANSPORT="$("$ADB_BIN" devices -l | grep -F "$ANDROID_SERIAL" | sed -n 's/.*transport_id:\([0-9]*\).*/\1/p' | head -1)"
else
  TRANSPORT="$("$ADB_BIN" devices -l | grep -E ' device ' | sed -n 's/.*transport_id:\([0-9]*\).*/\1/p' | head -1)"
fi
[[ -n "$TRANSPORT" ]] || { echo "No phone over adb. Connect one with USB debugging on, or set ANDROID_SERIAL." >&2; exit 1; }
adb() { "$ADB_BIN" -t "$TRANSPORT" "$@"; }
phone_log() { adb logcat -d -s 'OwnDesk:*' 2>/dev/null | grep -v '^---' || true; }
# Waits until the phone's log matches, up to $2 seconds.
wait_phone() {
  for _ in $(seq 1 $(( $2 * 2 ))); do phone_log | grep -qE "$1" && return 0; sleep 0.5; done
  return 1
}
# Which screen is in front on the phone, as "ClassName".
front() { adb shell dumpsys window | sed -n 's/.*mCurrentFocus=.*\/[^ ]*\.\([A-Za-z]*\)}.*/\1/p' | head -1; }
# Types into the phone as one argument, and only into OwnDesk's terminal: keys sent to any other
# screen could act on a real Mac, so anything else stops the run. Spaces become %s; the single
# quotes keep the phone's shell out.
type_text() {
  local where; where="$(front)"
  if [[ "$where" != "TerminalActivity" ]]; then
    echo "  stopped: the terminal is not in front (the phone shows $where), so nothing was typed" >&2
    return 1
  fi
  adb shell "input text '${1// /%s}'"; adb shell input keyevent 66
}
snap() { [[ -n "${SCREENSHOTS:-}" ]] && adb exec-out screencap -p >"$SCREENSHOTS/$1.png" || true; }

cleanup() {
  if [[ -n "$HOST_FP" ]]; then
    adb shell am force-stop "$APP" >/dev/null 2>&1 || true
    adb shell am start -n "$APP/.ui.MainActivity" --es forget "$HOST_FP" >/dev/null 2>&1 || true
    sleep 2
    adb shell am force-stop "$APP" >/dev/null 2>&1 || true
  fi
  [[ -n "$AGENT_PID" ]] && kill "$AGENT_PID" 2>/dev/null || true
  [[ -n "$SSHD_PID" ]] && kill "$SSHD_PID" 2>/dev/null || true
  exec 3>&- 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "phone: $(adb shell getprop ro.product.model | tr -d '\r'), Android $(adb shell getprop ro.build.version.release | tr -d '\r')"
PHONE_IP="$(adb shell ip -4 addr show wlan0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)"
[[ -n "$PHONE_IP" ]] || { echo "The phone has no Wi-Fi address. Put it on the same network as this Mac." >&2; exit 1; }
MAC_IP="$(route -n get "$PHONE_IP" 2>/dev/null | sed -n 's/.*interface: //p' | xargs -I{} ipconfig getifaddr {} || true)"
[[ -n "$MAC_IP" ]] || { echo "No local address on this Mac reaches $PHONE_IP." >&2; exit 1; }
echo "phone at $PHONE_IP, this Mac at $MAC_IP"

if [[ -z "${SKIP_BUILD:-}" ]]; then
  echo "building owndesk-agent"
  (cd "$ROOT/apps/mac-agent" && swift build --product owndesk-agent >/dev/null)
  echo "building the Android app"
  (cd "$ROOT/apps/android" && ANDROID_HOME="$SDK" ./gradlew -q :app:assembleDebug >/dev/null)
fi
AGENT="$ROOT/apps/mac-agent/.build/debug/owndesk-agent"
echo "installing it (some phones want Install tapped on the screen)"
adb install -r -t "$ROOT/apps/android/app/build/outputs/apk/debug/app-debug.apk" >/dev/null

# The terminal's server: this Mac's sshd as you, on a spare port, with its own host key and an
# authorized_keys that starts empty. The agent installs the phone's key there when asked, and
# vouches for this server's host key, exactly as OwnDesk.app does with ~/.ssh and /etc/ssh.
SSHD_DIR="$WORK/sshd"
mkdir -p "$SSHD_DIR"
# Both of the types every Mac has: the Android app's SSH library takes ECDSA but not ed25519.
ssh-keygen -q -t ed25519 -N "" -f "$SSHD_DIR/ssh_host_ed25519_key"
ssh-keygen -q -t ecdsa -b 256 -N "" -f "$SSHD_DIR/ssh_host_ecdsa_key"
: >"$SSHD_DIR/authorized_keys"
SSH_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("0.0.0.0",0)); print(s.getsockname()[1])')"
cat >"$SSHD_DIR/sshd_config" <<EOF
Port $SSH_PORT
ListenAddress $MAC_IP
HostKey $SSHD_DIR/ssh_host_ed25519_key
HostKey $SSHD_DIR/ssh_host_ecdsa_key
AuthorizedKeysFile $SSHD_DIR/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PerSourcePenalties no
PidFile $SSHD_DIR/sshd.pid
EOF
/usr/sbin/sshd -D -e -f "$SSHD_DIR/sshd_config" </dev/null >"$SSHD_DIR/sshd.log" 2>&1 &
SSHD_PID=$!

# The agent takes commands on stdin. A FIFO opened read-write keeps it open without blocking.
mkfifo "$FIFO"
exec 3<>"$FIFO"
"$AGENT" --name "Test Mac" --port "$PORT" --data-dir "$WORK/host" --file-identity \
  --synthetic-screen --synthetic-size 1920x1080 --print-input --no-bonjour \
  --authorized-keys "$SSHD_DIR/authorized_keys" --ssh-host-keys "$SSHD_DIR" <&3 >"$LOG" 2>&1 &
AGENT_PID=$!
for _ in $(seq 1 100); do grep -q "listening on port" "$LOG" 2>/dev/null && break; sleep 0.1; done
grep -q "listening on port" "$LOG" || { echo "the agent did not start:" >&2; cat "$LOG" >&2; exit 1; }
HOST_FP="$(sed -n 's/^  fingerprint  *//p' "$LOG" | head -1 | tr -d '[:space:]')"
# An empty prefix matches every paired Mac, real ones included; never go on without it.
[[ "$HOST_FP" =~ ^[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}$ ]] || { echo "could not read the test host's fingerprint" >&2; exit 1; }

[[ -n "${SCREENSHOTS:-}" ]] && mkdir -p "$SCREENSHOTS"
STATUS=0
set +e

echo "pairing"
echo pair >&3
for _ in $(seq 1 50); do grep -q '^{"' "$LOG" && break; sleep 0.1; done
CODE="$(grep '^{"' "$LOG" | tail -1 | tr -d '\n' | base64 | tr '+/' '-_' | tr -d '=\n')"
( for _ in $(seq 1 600); do grep -q "PAIRING REQUEST" "$LOG" && { echo y >&3; exit 0; }; sleep 0.1; done ) &
adb shell am force-stop "$APP"
adb logcat -c
adb shell am start -n "$APP/.ui.MainActivity" --es pairing_code_b64 "$CODE" >/dev/null
wait_phone "paired with Test Mac" 60 || echo "  the phone did not report pairing"

echo "running the session stage"
adb logcat -c
adb shell am start -n "$APP/.ui.MainActivity" --es connect "$HOST_FP" >/dev/null
for _ in $(seq 1 60); do grep -q '"[^"]*" connected' "$LOG" && break; sleep 0.5; done
sleep 3
# Tapped only when the session is this test's: the host here says connected and the phone shows it.
if grep -q '"[^"]*" connected' "$LOG" && [[ "$(front)" == "SessionActivity" ]]; then
  # The session screen turns sideways; "cur=" is the screen's size as it is turned now.
  SIZE="$(adb shell dumpsys window displays | sed -n 's/.*cur=\([0-9]*\)x\([0-9]*\).*/\1 \2/p' | head -1)"
  read -r W H <<<"$SIZE"
  adb shell input tap $(( W / 2 )) $(( H / 2 ))
  sleep 2
  snap session
else
  echo "  the session did not open with the test host, so nothing was tapped"
fi
adb shell am force-stop "$APP"
sleep 2

echo "running the terminal stage"
MARKER="$WORK/terminal-marker"
( for _ in $(seq 1 1800); do grep -q "TERMINAL KEY REQUEST" "$LOG" && { echo "key y" >&3; exit 0; }; sleep 0.1; done ) &
adb logcat -c
adb shell am start -n "$APP/.ui.MainActivity" --es terminal_ask "$HOST_FP" --ei ssh_port "$SSH_PORT" >/dev/null
wait_phone "added this phone's key|already had this phone's key|did not answer|said no" 150
adb logcat -c
adb shell am start -n "$APP/.ui.MainActivity" --es terminal "$HOST_FP" >/dev/null
wait_phone "terminal open on|Not connected|Nothing answered|refused" 30
sleep 1
phone_log | grep -q "terminal open on Test Mac" || echo "  the terminal did not open: $(phone_log | grep -E 'Not connected|Nothing answered|refused|closed' | tail -1 | sed 's/.*OwnDesk : //')"
adb shell uiautomator dump /sdcard/owndesk-e2e.xml >/dev/null 2>&1
adb pull /sdcard/owndesk-e2e.xml "$WORK/screen.xml" >/dev/null 2>&1
adb shell rm -f /sdcard/owndesk-e2e.xml
if type_text "echo owndesk-android-42 > $MARKER"; then
  for _ in $(seq 1 30); do [[ -s "$MARKER" ]] && break; sleep 0.5; done
  snap terminal
  type_text "exit" || true
  sleep 2
fi
set -e

check() {
  if eval "$1"; then echo "  ok   $2"; else echo "  FAIL $2"; STATUS=1; fi
}
echo
check 'grep -q "PAIRING REQUEST" "$LOG"' "the phone asked to pair, and it was approved"
check 'grep -qE "\"[^\"]*\" connected" "$LOG"' "the phone opened the host's screen"
check 'grep -q "^input mouse_down left" "$LOG"' "a tap on the picture is a left click"
check 'grep -qE "terminal key of \"[^\"]*\": installed" "$LOG"' "the host installed the key only after it was allowed"
check 'grep -qE "^ecdsa-sha2-nistp256 [A-Za-z0-9+/=]+ owndesk-[0-9a-f]{16} " "$SSHD_DIR/authorized_keys"' \
  "the key line was written by the host, tagged with the phone"
check '! grep -q "text=\"Trust" "$WORK/screen.xml"' "no host key question: the host vouched for its key"
check 'grep -q "Accepted publickey for $(whoami)" "$SSHD_DIR/sshd.log"' "the terminal logged in with the phone's key"
check '[[ "$(cat "$MARKER" 2>/dev/null)" == "owndesk-android-42" ]]' "a command typed on the phone ran on this Mac"

if [[ "$STATUS" != 0 ]]; then
  echo
  echo "the host's log ended with:"
  tail -25 "$LOG" | grep -v '^{"' | sed 's/^/  /'
  echo
  echo "the SSH server's log ended with:"
  tail -10 "$SSHD_DIR/sshd.log" | sed 's/^/  /'
  echo
  echo "the phone's log ended with:"
  phone_log | tail -15 | sed 's/^/  /'
fi
exit "$STATUS"
