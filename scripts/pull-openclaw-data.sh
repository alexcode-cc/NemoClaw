#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Pull .openclaw-data/ from a running NemoClaw sandbox back to the host.
# Uses openshell sandbox download to fetch files from the writable
# /sandbox/.openclaw-data/ area without rebuilding the image.
#
# Usage:
#   ./scripts/pull-openclaw-data.sh [sandbox-name]
#
# Default sandbox name: my-assistant

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SANDBOX="${1:-my-assistant}"
SOURCE_DIR="/sandbox/.openclaw-data"
TARGET_DIR="${ROOT}/.openclaw-data"

# Check if sandbox is reachable
if ! openshell sandbox list 2>/dev/null | grep -q "$SANDBOX"; then
  echo "Error: Sandbox '${SANDBOX}' not found or not running."
  echo "Run 'nemoclaw ${SANDBOX} status' to check."
  exit 1
fi

mkdir -p "$TARGET_DIR"

echo "Pulling sandbox '${SANDBOX}' .openclaw-data/ → Host..."

# Known subdirectories in .openclaw-data (matching Dockerfile.base structure)
SUBDIRS=(agents extensions workspace skills hooks identity devices canvas cron)

count=0
for name in "${SUBDIRS[@]}"; do
  echo "  ↓ ${SOURCE_DIR}/${name}/ → ${TARGET_DIR}/${name}/"
  openshell sandbox download "$SANDBOX" "${SOURCE_DIR}/${name}/" "${TARGET_DIR}/${name}/" 2>/dev/null || true
  count=$((count + 1))
done

# Also pull any loose files (e.g. update-check.json)
echo "  ↓ ${SOURCE_DIR}/ (loose files)"
for f in $(openshell sandbox connect "$SANDBOX" -- find "$SOURCE_DIR" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null || true); do
  [ -z "$f" ] && continue
  echo "    ↓ ${f}"
  openshell sandbox download "$SANDBOX" "${SOURCE_DIR}/${f}" "${TARGET_DIR}/" 2>/dev/null || true
  count=$((count + 1))
done

echo "Done: ${count} item(s) pulled."
