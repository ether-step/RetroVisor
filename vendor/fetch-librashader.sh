#!/bin/sh
# fetch-librashader.sh - get librashader's macOS library and header for the
# RetroArch preset shader. Run once after cloning; build.sh needs the files.
set -e
V=${1:-v0.12.0}
cd "$(dirname "$0")"
mkdir -p librashader && cd librashader
curl -fsSL -o lr.zip "https://github.com/SnowflakePowered/librashader/releases/download/librashader-$V/librashader-aarch64-macos-$V-optimized.zip"
unzip -q -o lr.zip && rm lr.zip
ls -l librashader.a librashader.dylib librashader.h
