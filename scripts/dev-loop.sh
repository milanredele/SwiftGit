#!/bin/bash
# Development helper: lets Claude trigger builds/tests on this Mac while you watch.
#
# It only ever does one of these fixed actions, requested by writing
# "<id> <action>" into .dev/request:
#   build    – swift build (debug) + bundle build/SwiftGit.app
#   run      – build, then (re)launch build/SwiftGit.app
#   release  – release build + bundle + relaunch
#   test     – swift test (headless: offscreen windows, snapshots in .dev/snapshots)
#   measure  – memory footprint of the running SwiftGit into .dev/footprint.log
#   commit   – git add -A && git commit -F .dev/commit-msg (your git identity)
# Output goes to .dev/*.log and .dev/done gets "<id> <exit-code>".
# Stop it any time with Ctrl-C.
cd "$(dirname "$0")/.."
mkdir -p .dev
echo "SwiftGit dev loop watching $(pwd)/.dev/request — Ctrl-C to stop."
{ sw_vers; echo; swift --version; echo; xcode-select -p; } > .dev/toolchain.log 2>&1

while true; do
    if [ -s .dev/request ]; then
        read -r ID ACTION < .dev/request
        : > .dev/request
        echo "$(date '+%H:%M:%S') request $ID: $ACTION"
        CODE=0
        case "$ACTION" in
            build)
                scripts/build-app.sh debug > .dev/build.log 2>&1 || CODE=$?
                ;;
            run)
                scripts/build-app.sh debug > .dev/build.log 2>&1 || CODE=$?
                if [ $CODE -eq 0 ]; then
                    pkill -x SwiftGit 2>/dev/null; sleep 0.5
                    open build/SwiftGit.app
                fi
                ;;
            release)
                scripts/build-app.sh release > .dev/build.log 2>&1 || CODE=$?
                if [ $CODE -eq 0 ]; then
                    pkill -x SwiftGit 2>/dev/null; sleep 0.5
                    open build/SwiftGit.app
                fi
                ;;
            test)
                rm -rf .dev/snapshots
                mkdir -p .dev/snapshots
                swift test > .dev/test.log 2>&1 || CODE=$?
                ;;
            measure)
                PID=$(pgrep -x SwiftGit | head -1)
                if [ -n "$PID" ]; then
                    footprint -p "$PID" > .dev/footprint.log 2>&1 || CODE=$?
                    vmmap --summary "$PID" >> .dev/footprint.log 2>&1 || true
                else
                    echo "SwiftGit is not running" > .dev/footprint.log; CODE=1
                fi
                ;;
            commit)
                { git add -A && git commit -F .dev/commit-msg; } > .dev/commit.log 2>&1 || CODE=$?
                ;;
            *)
                echo "unknown action: $ACTION" > .dev/build.log; CODE=2
                ;;
        esac
        echo "$ID $CODE" > .dev/done
        echo "$(date '+%H:%M:%S') request $ID finished with $CODE"
    fi
    sleep 1
done
