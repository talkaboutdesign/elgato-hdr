#!/bin/zsh
# Grab 5 raw P010 frames and decode frame 0 to PNG (SDR preview) + a 2s HDR10 HEVC clip for verification.
cd "$(dirname "$0")/tools"; mode=${1:-1080p}; case $mode in 4k) frame=5; w=3840; h=2160;; *) frame=2; w=1920; h=1080;; esac
rm -f /tmp/elg.frame*.bin
sudo ./uvc_capture --format 7 --frame $frame --fps 30 --count 5 --dump-prefix /tmp/elg
ls -la /tmp/elg.frame*.bin
ffmpeg -y -hide_banner -loglevel error -f rawvideo -pix_fmt p010le -s ${w}x${h} -i /tmp/elg.frame0000.bin -vf "zscale=t=linear:npl=1000,tonemap=hable,zscale=p=709:t=709:m=709,format=yuv420p" /tmp/elg_frame0_tonemapped.png && echo "wrote /tmp/elg_frame0_tonemapped.png"
