#!/bin/sh
# Builds the Now Playing bridge and places it in the app's resources.
# Run this after changing NowPlayingBridge.m; the built file is checked in.
#
# arm64e is required: on Apple silicon /usr/bin/perl runs as arm64e and can only
# load libraries with that slice. x86_64 covers Intel Macs.
set -eu
cd "$(dirname "$0")"
out="../DynamicMenu/Resources/NowPlayingBridge.bin"
mkdir -p "$(dirname "$out")"
clang -fobjc-arc -O2 -dynamiclib \
    -arch arm64e -arch x86_64 \
    -mmacosx-version-min=13.0 \
    -framework Foundation \
    -o "$out" NowPlayingBridge.m
echo "Built $out ($(lipo -archs "$out"))"
