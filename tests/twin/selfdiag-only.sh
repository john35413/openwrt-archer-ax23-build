#!/usr/bin/env bash
# TWIN_TESTS entry: boot the twin, run only T01/T02 and S06 (self-diagnostic side-effect check).
exec "$(cd "$(dirname "$0")" && pwd)/twin-tests.sh" "$1" "$2" selfdiag-only
