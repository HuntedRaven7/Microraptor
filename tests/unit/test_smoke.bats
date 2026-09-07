#!/usr/bin/env bash
# Basic smoke tests for fsdk-it element graph and file presence.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Test 1: project.conf exists and has release-version
if ! grep -q 'release-version:' "$ROOT/project.conf"; then
  echo "FAIL: project.conf missing release-version"
  exit 1
fi
echo "PASS: project.conf has release-version"

# Test 2: freedesktop-sdk.bst exists
if [ ! -f "$ROOT/elements/freedesktop-sdk.bst" ]; then
  echo "FAIL: freedesktop-sdk.bst missing"
  exit 1
fi
echo "PASS: freedesktop-sdk.bst exists"

# Test 3: os-stack.bst includes network-manager
if ! grep -q 'network-manager.bst' "$ROOT/elements/bluefin-server/os-stack.bst"; then
  echo "FAIL: os-stack.bst missing network-manager.bst"
  exit 1
fi
echo "PASS: os-stack.bst includes network-manager.bst"

# Test 4: repart.d configs exist
for f in 10-esp.conf 20-root-a.conf 30-var.conf; do
  if [ ! -f "$ROOT/files/installer/repart.d/$f" ]; then
    echo "FAIL: $f missing"
    exit 1
  fi
done
echo "PASS: repart.d configs exist"

# Test 5: skills index exists
if [ ! -f "$ROOT/docs/skills/index.md" ]; then
  echo "FAIL: docs/skills/index.md missing"
  exit 1
fi
echo "PASS: docs/skills/index.md exists"

echo "All smoke tests passed."
