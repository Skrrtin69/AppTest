#!/usr/bin/env bash
# Regenerates the tiny synthetic clips bundled for the built-in demo server.
# Everything comes from ffmpeg's built-in test sources (patterns + sine tones); nothing is
# downloaded. Output is committed to Resources/Media, so CI does not need ffmpeg.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=Resources/Media
mkdir -p "$OUT"
FF=${FFMPEG:-ffmpeg}
D=3

# WebM-only clips (VP8 + Vorbis, VP9 + Opus): exercise the web player with sound.
"$FF" -y -f lavfi -i "testsrc2=size=320x240:rate=24:duration=$D" -f lavfi -i "sine=frequency=440:duration=$D" \
  -c:v libvpx -b:v 300k -c:a libvorbis -q:a 2 -shortest "$OUT/clip1.webm"
"$FF" -y -f lavfi -i "mandelbrot=size=320x240:rate=24" -f lavfi -i "sine=frequency=550:duration=$D" -t $D \
  -c:v libvpx-vp9 -b:v 300k -c:a libopus -b:a 48k -shortest "$OUT/clip2.webm"
# MP4 (H.264 + AAC): native AVPlayer path with sound.
"$FF" -y -f lavfi -i "smptebars=size=320x240:rate=24:duration=$D" -f lavfi -i "sine=frequency=330:duration=$D" \
  -c:v libx264 -pix_fmt yuv420p -profile:v baseline -c:a aac -b:a 64k -movflags +faststart -shortest "$OUT/clip3.mp4"
# The same clip as both WebM and MP4: the adapter should pick the MP4.
"$FF" -y -f lavfi -i "testsrc=size=320x240:rate=24:duration=$D" -f lavfi -i "sine=frequency=660:duration=$D" \
  -c:v libvpx -b:v 300k -c:a libvorbis -q:a 2 -shortest "$OUT/clip4.webm"
"$FF" -y -f lavfi -i "testsrc=size=320x240:rate=24:duration=$D" -f lavfi -i "sine=frequency=660:duration=$D" \
  -c:v libx264 -pix_fmt yuv420p -profile:v baseline -c:a aac -b:a 64k -movflags +faststart -shortest "$OUT/clip4.mp4"
ls -la "$OUT"
