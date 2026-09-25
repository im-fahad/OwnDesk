#!/usr/bin/env bash
# End-to-end test of the iPhone app in the Simulator, against a real host on this Mac.
#
#   scripts/test-ios-simulator.sh                 on the first available iPhone simulator
#   DEVICE="iPhone 17" scripts/test-ios-simulator.sh
#   SCREENSHOTS=/tmp/shots scripts/test-ios-simulator.sh    also save the session's screens there
#
# Starts the headless owndesk-agent with a 1920x1080 synthetic screen and --print-input, so no
# permission is needed and nothing on this Mac moves. Full size on purpose: at 1280x720 the picture
# arrives as H.264 whatever level the iPhone offers, so the codec check would prove nothing. Opens a pairing window, hands the code to the UI test,
# approves the request when it arrives, runs the UI tests, then checks that the host received each
# gesture as the right input. No Apple ID or certificate is involved: Simulator builds are signed
# for this Mac only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-47610}"
WORK="$(mktemp -d -t owndesk-ios-e2e)"
LOG="$WORK/agent.log"
FIFO="$WORK/agent.in"
AGENT_PID=""

APP_LOG_PID=""

cleanup() {
  [[ -n "$AGENT_PID" ]] && kill "$AGENT_PID" 2>/dev/null || true
  [[ -n "$APP_LOG_PID" ]] && kill "$APP_LOG_PID" 2>/dev/null || true
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

# Everything slow happens before the pairing window opens, because the window lasts 120 seconds.
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
"$AGENT" --name "Test Mac" --port "$PORT" --data-dir "$WORK/host" --file-identity \
  --synthetic-screen --synthetic-size 1920x1080 --print-input --no-bonjour <&3 >"$LOG" 2>&1 &
AGENT_PID=$!

for _ in $(seq 1 100); do grep -q "listening on port" "$LOG" 2>/dev/null && break; sleep 0.1; done
grep -q "listening on port" "$LOG" || { echo "the agent did not start:" >&2; cat "$LOG" >&2; exit 1; }

run_tests() {
  xcodebuild test-without-building \
    -project "$ROOT/apps/ios/OwnDesk.xcodeproj" -scheme OwnDesk \
    -destination "platform=iOS Simulator,name=$DEVICE" -derivedDataPath "$WORK/dd" \
    -only-testing:"$1" 2>&1 | tee -a "$WORK/xcodebuild.log" | grep -E "Test Case|error:|\*\* TEST"
  return "${PIPESTATUS[0]}"
}

set +e
echo "running the home screen UI tests"
run_tests OwnDeskUITests/HomeScreenUITests
STATUS=$?

# The pairing window opens only now, just before the test that uses it: it lasts 120 seconds, and
# the home screen tests alone take about that long.
echo pair >&3
for _ in $(seq 1 50); do grep -q '^{"' "$LOG" && break; sleep 0.1; done
CODE_JSON="$(grep -m1 '^{"' "$LOG")"
CODE="$(printf %s "$CODE_JSON" | base64 | tr '+/' '-_' | tr -d '=\n')"

# Approve the pairing request as soon as the iPhone sends it. On a real Mac a person compares the
# fingerprints first; here there is nothing to compare against.
(
  for _ in $(seq 1 1200); do
    if grep -q "PAIRING REQUEST" "$LOG"; then echo y >&3; exit 0; fi
    sleep 0.1
  done
) &

# The app's own log, for when something goes wrong: it says what it tried and what answered.
xcrun simctl spawn "$DEVICE" log stream --level info --style compact \
  --predicate 'subsystem BEGINSWITH "owndesk"' >"$WORK/app.log" 2>&1 &
APP_LOG_PID=$!

echo "running the session UI test"
[[ -n "${SCREENSHOTS:-}" ]] && mkdir -p "$SCREENSHOTS"
TEST_RUNNER_OWNDESK_PAIR_CODE="$CODE" TEST_RUNNER_OWNDESK_SCREENSHOTS="${SCREENSHOTS:-}" \
  run_tests OwnDeskUITests/SessionUITests || STATUS=1
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
if [[ "$STATUS" != 0 ]]; then
  echo
  echo "the host's log ended with:"
  tail -25 "$LOG" | grep -v '^{"' | sed 's/^/  /'
  echo
  echo "the app's log ended with:"
  grep "owndesk" "$WORK/app.log" | tail -25 | sed 's/^/  /'
fi
exit "$STATUS"
