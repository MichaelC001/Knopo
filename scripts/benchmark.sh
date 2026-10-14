#!/bin/zsh
# Opt-in AppKit benchmarks use the test harness for access to app internals.
set -e
cd "$(dirname "$0")/.."
KNOPO_BENCH=1 KNOPO_SIDEBAR_BENCH=1 ./scripts/test.sh -c release \
  --filter 'EditCostBenchmark|SidebarOpenBenchmark' "$@"
