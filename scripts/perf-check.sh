#!/bin/bash
#
# Phase gate: build Release, launch Sistem in the background (menu bar only, no
# window, no focus change), let it settle, then measure it with perfcheck and fail
# if any budget is exceeded.
#
#   scripts/perf-check.sh                 # 60 s, Phase 0 budgets
#   SECONDS_TO_MEASURE=600 scripts/perf-check.sh
#   BUDGET_CPU=0.3 BUDGET_MEM=35 BUDGET_WAKEUPS=2 scripts/perf-check.sh
#   WINDOW=ram BUDGET_CPU=4 BUDGET_MEM=80 BUDGET_WAKEUPS=10 scripts/perf-check.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MEASURE="${SECONDS_TO_MEASURE:-60}"
WARMUP="${WARMUP:-10}"
# Phase 0 gate: an app that does nothing yet must cost (almost) nothing.
BUDGET_CPU="${BUDGET_CPU:-0.1}"
BUDGET_MEM="${BUDGET_MEM:-25}"
BUDGET_WAKEUPS="${BUDGET_WAKEUPS:-2}"

echo "▸ Release derleniyor…"
xcodebuild -project Sistem.xcodeproj -scheme Sistem -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath build build -quiet 2>&1 | grep -vE 'appintentsmetadataprocessor|IDERunDestination' || true
swift build -c release --package-path Packages/SystemKit --product perfcheck -q
PERFCHECK="$(swift build -c release --package-path Packages/SystemKit --show-bin-path)/perfcheck"
APP="build/Build/Products/Release/Sistem.app"

# Only ever stop a copy started from this build folder, never an installed one.
pkill -f "$APP/Contents/MacOS/Sistem" 2>/dev/null || true

# WINDOW=<page> (e.g. cpu, ram) measures with the main window open
# on that page — built off-screen, so it never appears or takes focus.
"$APP/Contents/MacOS/Sistem" ${WINDOW:+--measure-window "$WINDOW"} >/dev/null 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT

echo "▸ Sistem çalışıyor (pid $PID)"
"$PERFCHECK" "$PID" --warmup "$WARMUP" --seconds "$MEASURE" \
    --cpu "$BUDGET_CPU" --mem "$BUDGET_MEM" --wakeups "$BUDGET_WAKEUPS"
