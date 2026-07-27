#!/usr/bin/env bash
# Example CI script run inside the project worktree.
set -euo pipefail
echo "WatchCI CI example"
echo "project=${WATCHCI_PROJECT:-} kind=${WATCHCI_KIND:-} ref=${WATCHCI_REF:-} sha=${WATCHCI_SHA:-}"
echo "pwd=$(pwd)"
git rev-parse --short HEAD 2>/dev/null || true
echo "OK"
