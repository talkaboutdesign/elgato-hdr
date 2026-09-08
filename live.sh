#!/bin/zsh
# Live HDR view from Elgato 4K X via direct UVC (P010). Usage: ./live.sh [1080p|4k] [fps] [--hlg|--sdr]
cd "$(dirname "$0")/tools"
mode=${1:-4k}; fps=${2:-30}; color=${3:---pq}
case $mode in 4k) frame=5;; 1080p) frame=2;; 1440p) frame=4;; *) frame=$mode;; esac
sudo ./uvc_capture --format 7 --frame $frame --fps $fps | ./hdrview $color --title "Elgato 4K X P010"
