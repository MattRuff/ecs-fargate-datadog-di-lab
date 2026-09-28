#!/usr/bin/env bash
# Thin wrapper so `scripts/loadgen.sh <url> [minutes]` just works.
set -euo pipefail
exec python3 "$(dirname "${BASH_SOURCE[0]}")/loadgen.py" "$@"
