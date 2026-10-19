#!/usr/bin/env bash
# Regenerates the tiny synthetic video clips bundled for the built-in mock server.
# All content is generated from ffmpeg's built-in test sources; nothing is downloaded.
# Output is committed to Resources/Media, so CI does not need ffmpeg.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=Resources/Media
mkdir -p "$OUT"
FF=${FFMPEG:-ffmpeg}

# Two WebM clips (VP8 and VP9) -> exercises the WebM fallback player.
"$FF" -y -f lavfi -i "testsrc2=size=320x240:rate=24:duration=3" \
  -c:v libvpx -b:v 300k -an "$OUT/clip1.webm"
"$FF" -y -f lavfi -i "mandelbrot=size=320x240:rate=24" -t 3 \
  -c:v libvpx-vp9 -b:v 300k -an "$OUT/clip2.webm"
# One MP4 (H.264) -> exercises the native AVPlayer path.
"$FF" -y -f lavfi -i "smptebars=size=320x240:rate=24:duration=3" \
  -c:v libx264 -pix_fmt yuv420p -profile:v baseline -movflags +faststart -an "$OUT/clip3.mp4"
ls -la "$OUT"
