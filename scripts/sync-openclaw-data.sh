#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Sync local .openclaw-data/ into a running NemoClaw sandbox.
# Uses openshell sandbox upload to push files into the writable
# /sandbox/.openclaw-data/ area without rebuilding the image.
#
# Usage:
#   ./scripts/sync-openclaw-data.sh [sandbox-name]
#
# Default sandbox name: my-assistant

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SANDBOX="${1:-my-assistant}"
SOURCE_DIR="${ROOT}/.openclaw-data"
TARGET_DIR="/sandbox/.openclaw-data"

if [ ! -d "$SOURCE_DIR" ]; then
  echo "Error: ${SOURCE_DIR} does not exist."
  echo "Create the directory and add files to sync."
  exit 1
fi

# Check if sandbox is reachable
if ! openshell sandbox list 2>/dev/null | grep -q "$SANDBOX"; then
  echo "Error: Sandbox '${SANDBOX}' not found or not running."
  echo "Run 'nemoclaw ${SANDBOX} status' to check."
  exit 1
fi

echo "Syncing .openclaw-data/ → sandbox '${SANDBOX}'..."

# Upload each top-level entry (file or directory) individually
# to preserve directory structure inside the sandbox.
count=0
for entry in "$SOURCE_DIR"/*; do
  [ -e "$entry" ] || continue
  name="$(basename "$entry")"
  if [ -d "$entry" ]; then
    echo "  ↑ ${name}/ → ${TARGET_DIR}/${name}/"
    openshell sandbox upload "$SANDBOX" "$entry/" "${TARGET_DIR}/${name}/"
  else
    echo "  ↑ ${name} → ${TARGET_DIR}/"
    openshell sandbox upload "$SANDBOX" "$entry" "${TARGET_DIR}/"
  fi
  count=$((count + 1))
done

if [ "$count" -eq 0 ]; then
  echo "  (empty — no files to sync)"
else
  echo "Done: ${count} item(s) synced."
fi
