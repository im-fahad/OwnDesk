#!/usr/bin/env bash
# End-to-end test of the iPhone app in the Simulator, against a real host on this Mac.
#
#   scripts/test-ios-simulator.sh                 on the first available iPhone simulator
#   DEVICE="iPhone 17" scripts/test-ios-simulator.sh
#   SCREENSHOTS=/tmp/shots scripts/test-ios-simulator.sh    also save the screens there
#
# Starts the headless owndesk-agent with a 1920x1080 synthetic screen and --print-input, so no
# permission is needed and nothing on this Mac moves. Full size on purpose: at 1280x720 the picture
# arrives as H.264 whatever level the iPhone offers, so the codec check would prove nothing.
#
# Three stages, each with its own pairing window, since a window lasts only 120 seconds:
#   home      the home screen and the pairing sheet, no host needed
#   session   pairs, opens the Mac's screen, drives the gestures and keys; the host then says
#             whether each one arrived as the right input
#   terminal  pairs, asks the host to allow the iPhone's terminal key (answered yes here), then opens
#             a terminal on a private sshd (this Mac's own, run as you on a spare port, never the
#             Remote Login setting) with no host key question, and runs a command that writes a file
#
# No Apple ID or certificate is involved: Simulator builds are signed for this Mac only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-47610}"
WORK="$(mktemp -d -t owndesk-ios-e2e)"
LOG="$WORK/agent.log"
FIFO="$WORK/agent.in"
AGENT_PID=""
APP_LOG_PID=""
SSHD_PID=""

cleanup() {
  [[ -n "$AGENT_PID" ]] && kill "$AGENT_PID" 2>/dev/null || true
  [[ -n "$APP_LOG_PID" ]] && kill "$APP_LOG_PID" 2>/dev/null || true
  [[ -n "$SSHD_PID" ]] && kill "$SSHD_PID" 2>/dev/null || true
  exec 3>&- 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

if [[ -z "${DEVICE:-}" ]]; then
  DEVICE="$(xcrun simctl list devices available | grep -m1 -oE 'iPhone[^(]*' | sed 's/ *$//' || true)"
fi
if [[ -z "$DEVICE" ]]; then
  echo "No iPhone simulator is installed. Install one with: xcodebuild -downloadPlatform iOS" >&2
  exit 1
fi
echo "simulator: $DEVICE"

echo "building owndesk-agent"
(cd "$ROOT/apps/mac-agent" && swift build --product owndesk-agent >/dev/null)
AGENT="$ROOT/apps/mac-agent/.build/debug/owndesk-agent"

# Everything slow happens before a pairing window opens.
echo "building the iPhone app and its UI tests"
xcodebuild build-for-testing -project "$ROOT/apps/ios/OwnDesk.xcodeproj" -scheme OwnDesk \
  -destination "platform=iOS Simulator,name=$DEVICE" -derivedDataPath "$WORK/dd" >"$WORK/build.log" 2>&1 \
  || { grep -E "error:" "$WORK/build.log" >&2; exit 1; }
echo "starting the simulator"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null

# The agent takes commands on stdin. A FIFO opened read-write keeps it open without blocking.
mkfifo "$FIFO"
exec 3<>"$FIFO"
mkdir -p "$WORK/sshd"
"$AGENT" --name "Test Mac" --port "$PORT" --data-dir "$WORK/host" --file-identity \
  --synthetic-screen --synthetic-size 1920x1080 --print-input --no-bonjour \
  --authorized-keys "$WORK/sshd/authorized_keys" --ssh-host-keys "$WORK/sshd" <&3 >"$LOG" 2>&1 &
AGENT_PID=$!
for _ in $(seq 1 100); do grep -q "listening on port" "$LOG" 2>/dev/null && break; sleep 0.1; done
grep -q "listening on port" "$LOG" || { echo "the agent did not start:" >&2; cat "$LOG" >&2; exit 1; }

# The terminal's server: this Mac's sshd as you, on a spare port, with its own host key and an
# authorized_keys that starts empty. The agent, below, installs the app's key there when asked and
# vouches for this server's host key, exactly as OwnDesk.app does with ~/.ssh and /etc/ssh.
SSHD_DIR="$WORK/sshd"
mkdir -p "$SSHD_DIR"
ssh-keygen -q -t ed25519 -N "" -f "$SSHD_DIR/ssh_host_ed25519_key"
: >"$SSHD_DIR/authorized_keys"
SSH_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
cat >"$SSHD_DIR/sshd_config" <<EOF
Port $SSH_PORT
ListenAddress 127.0.0.1
HostKey $SSHD_DIR/ssh_host_ed25519_key
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

# The app's own log, for when something goes wrong: it says what it tried and what answered.
xcrun simctl spawn "$DEVICE" log stream --level info --style compact \
  --predicate 'subsystem BEGINSWITH "owndesk"' >"$WORK/app.log" 2>&1 &
APP_LOG_PID=$!

run_tests() {
  xcodebuild test-without-building \
    -project "$ROOT/apps/ios/OwnDesk.xcodeproj" -scheme OwnDesk \
    -destination "platform=iOS Simulator,name=$DEVICE" -derivedDataPath "$WORK/dd" \
    -only-testing:"$1" 2>&1 | tee -a "$WORK/xcodebuild.log" | grep -E "Test Case|error:|\*\* TEST"
  return "${PIPESTATUS[0]}"
}

# Opens a pairing window just before the test that uses it, and approves the request when it comes.
# On a real Mac a person compares the fingerprints first; here there is nothing to compare against.
open_pairing() {
  local before
  before=$(grep -c '^{"' "$LOG" || true)
  echo pair >&3
  for _ in $(seq 1 50); do [[ $(grep -c '^{"' "$LOG" || true) -gt $before ]] && break; sleep 0.1; done
  CODE="$(grep '^{"' "$LOG" | tail -1 | base64 | tr '+/' '-_' | tr -d '=\n')"
  local requests
  requests=$(grep -c "PAIRING REQUEST" "$LOG" || true)
  (
    for _ in $(seq 1 1200); do
      if [[ $(grep -c "PAIRING REQUEST" "$LOG" || true) -gt $requests ]]; then echo y >&3; exit 0; fi
      sleep 0.1
    done
  ) &
}

[[ -n "${SCREENSHOTS:-}" ]] && mkdir -p "$SCREENSHOTS"
set +e
echo "running the home screen UI tests"
run_tests OwnDeskUITests/HomeScreenUITests
STATUS=$?

echo "running the session UI test"
open_pairing
TEST_RUNNER_OWNDESK_PAIR_CODE="$CODE" TEST_RUNNER_OWNDESK_SCREENSHOTS="${SCREENSHOTS:-}" \
  run_tests OwnDeskUITests/SessionUITests || STATUS=1

echo "running the terminal UI test"
MARKER="$WORK/terminal-marker"
(
  # Allows the app's terminal key when the host asks, as a person at the Mac would.
  for _ in $(seq 1 1800); do
    if grep -q "TERMINAL KEY REQUEST" "$LOG" 2>/dev/null; then echo "key y" >&3; exit 0; fi
    sleep 0.1
  done
) &
open_pairing
TEST_RUNNER_OWNDESK_PAIR_CODE="$CODE" TEST_RUNNER_OWNDESK_SCREENSHOTS="${SCREENSHOTS:-}" \
TEST_RUNNER_OWNDESK_SSH_PORT="$SSH_PORT" TEST_RUNNER_OWNDESK_SSH_USER="$(whoami)" \
TEST_RUNNER_OWNDESK_MARKER="$MARKER" TEST_RUNNER_OWNDESK_AGENT_PORT="$PORT" \
  run_tests OwnDeskUITests/TerminalUITests || STATUS=1
set -e

echo
echo "what the host received:"
{ grep -E "PAIRING REQUEST|paired|connected|session ended|^input" "$LOG" | grep -v "mouse_move " | uniq -c | sed 's/^/  /'; } || true

check() {
  if grep -qE "$1" "$LOG"; then echo "  ok   $2"; else echo "  FAIL $2"; STATUS=1; fi
}
echo
check '\(ios\)' "paired as an iPhone"
check '^input mouse_move 0\.(4[89]|5[01])[0-9]* 0\.(4[89]|5[01])' "a tap at the centre put the pointer at the centre"
check '^input mouse_down left' "a tap is a left click"
check '^input mouse_down right' "a two-finger tap or a hold is a right click"
check '^input mouse_move_rel [1-9]' "trackpad mode moves the pointer relatively"
check '^input text [0-9]+ characters' "typing arrives as text"
check '^input key_down Escape' "the key bar sends Escape"
check '^input key_down KeyC meta' "⌘ then c sends Command-C"
if [[ "$(cat "$MARKER" 2>/dev/null)" == "owndesk-terminal-42" ]]; then
  echo "  ok   a command typed in the terminal ran on this Mac"
else
  echo "  FAIL a command typed in the terminal ran on this Mac"; STATUS=1
fi
if grep -q "Accepted publickey for $(whoami)" "$SSHD_DIR/sshd.log"; then
  echo "  ok   the terminal logged in with the iPhone's key"
else
  echo "  FAIL the terminal logged in with the iPhone's key"; STATUS=1
fi
check 'terminal key of "iPhone 17[^"]*": installed' "the host installed the key only after it was allowed"
if grep -qE '^ecdsa-sha2-nistp256 [A-Za-z0-9+/=]+ owndesk-[0-9a-f]{16} ' "$SSHD_DIR/authorized_keys"; then
  echo "  ok   the key line was written by the host, tagged with the device"
else
  echo "  FAIL the key line was written by the host, tagged with the device"; STATUS=1
fi
if [[ "$STATUS" != 0 ]]; then
  echo
  echo "the host's log ended with:"
  tail -25 "$LOG" | grep -v '^{"' | sed 's/^/  /'
  echo
  echo "the SSH server's log ended with:"
  tail -15 "$SSHD_DIR/sshd.log" | sed 's/^/  /'
  echo
  echo "the app's log ended with:"
  grep "owndesk" "$WORK/app.log" | tail -25 | sed 's/^/  /'
fi
exit "$STATUS"
