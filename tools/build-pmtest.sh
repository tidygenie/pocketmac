#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 Shared/*.swift tools/pmtest/main.swift -o build/pmtest
echo "Built: build/pmtest"
