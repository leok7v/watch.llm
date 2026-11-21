#!/bin/sh
set -u
cd "$(dirname "$0")" || exit 1
app=io.github.leok7v.watch
out=tmp/check
mkdir -p "$out"

watch() {
    xcrun simctl list devices "$1" | grep "Apple Watch" | head -1 |
        sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'
}

xcodegen generate > "$out/gen.log" 2>&1 &&
xcodebuild -project Watch.xcodeproj -scheme Watch \
    -destination 'generic/platform=watchOS Simulator' \
    -derivedDataPath Build CODE_SIGNING_ALLOWED=NO build \
    > "$out/build.log" 2>&1 || { tail -30 "$out/build.log"; exit 1; }

device=$(watch booted)
if [ -z "$device" ]; then
    device=$(watch available)
    xcrun simctl boot "$device" || exit 1
    xcrun simctl bootstatus "$device" > /dev/null
fi
xcrun simctl install "$device" \
    Build/Products/Debug-watchsimulator/Watch.app || exit 1

failed=0
expect() {
    wanted=$1
    shift
    xcrun simctl launch --console-pty "$device" "$app" "$@" \
        mock=1 mute=1 exit=1 > "$out/run.log" 2>&1
    if grep -a -q "$wanted" "$out/run.log"; then
        echo "pass  $1"
    else
        echo "FAIL  $1  (wanted: $wanted)"
        grep -a "^watch: " "$out/run.log"
        failed=$((failed + 1))
    fi
}

expect "tool: get_time ok: It is " "text=What time is it?" fresh=1
expect "tool: set_timer ok: Timer set for 90 seconds." \
    "text=Set a timer for 90 seconds." fresh=1
expect "tool: set_timer ok: Timer set for 5 minutes." \
    "text=Set a timer for five minutes." fresh=1
expect "tool: get_time ok: It is " 'tool={"name":"get_time"}' fresh=1
expect "call: .*\"city\": \"Paris\"" \
    "text=What is the weather in Paris?" fresh=1
expect "reply: .*Paris" "text=What is the capital of France?" fresh=1
expect "open: .* [1-9][0-9]* tokens of talk kept" "text=Hello."
expect "speak: [1-9]" "text=Hello." fresh=1

echo "$failed failed"
[ "$failed" -eq 0 ]
