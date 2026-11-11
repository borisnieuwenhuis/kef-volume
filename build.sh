#!/bin/sh
# Signs with a fixed certificate so macOS keeps the Local Network permission across rebuilds.
set -e
cd "$(dirname "$0")"
pkill -x KEFVolume || true
swiftc -parse-as-library -O KEFVolume.swift -o "KEF Volume.app/Contents/MacOS/KEFVolume"
codesign --force --sign "KEF Volume Local Signing" --identifier local.boris.kefvolume "KEF Volume.app"
open "KEF Volume.app"
