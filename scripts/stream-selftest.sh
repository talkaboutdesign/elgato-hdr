#!/bin/bash
# Verification tools only; the application never launches ffmpeg or reads a stream key from arguments.
set -euo pipefail
cd "$(dirname "$0")/.."
canvas="${1:-wide}"
case "$canvas" in wide|vertical) ;; *) echo 'usage: stream-selftest.sh wide|vertical'; exit 2;; esac
ffmpeg=/opt/homebrew/bin/ffmpeg
ffprobe=/opt/homebrew/bin/ffprobe
out="${SELFTEST_DIR:-$(mktemp -d /tmp/ehdr-stream.XXXXXX)}"
mkdir -p "$out"
app_pid= listener_pid=
cleanup() {
    if [[ -n "$app_pid" ]]; then kill "$app_pid" 2>/dev/null || true; fi
    if [[ -n "$listener_pid" ]]; then kill "$listener_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT
if [[ "${SELFTEST_SKIP_BUILD:-0}" != 1 ]]; then ./build.sh > "$out/build.log" 2>&1; fi
"$ffmpeg" -hide_banner -loglevel warning -y -listen 1 -i rtmp://127.0.0.1:1935/live/test -t 20 -c copy "$out/selftest.flv" > "$out/listener.log" 2>&1 &
listener_pid=$!
sleep 1
EHDR_STREAM_KEY=test "dist/Elgato HDR.app/Contents/MacOS/ElgatoHDR" \
    --demo-source "${SELFTEST_SOURCE:-2560x1440@60}" --demo-camera \
    -presentation "${SELFTEST_PRESENTATION:-game}" -streamURL rtmp://127.0.0.1:1935/live \
    -streamCanvas "$canvas" -streamBitrate 6000 --go-live-for 25 > "$out/app.log" 2>&1 &
app_pid=$!
# Bound failures (failed encoder, connection, or launch) instead of leaving a listener hanging forever.
for ((i=0;i<45;i++)); do
    if ! kill -0 "$app_pid" 2>/dev/null; then break; fi
    sleep 1
done
if kill -0 "$app_pid" 2>/dev/null; then echo 'FAIL: app did not terminate'; exit 1; fi
wait "$app_pid"; app_pid=
kill "$listener_pid" 2>/dev/null || true
wait "$listener_pid" || true
listener_pid=
"$ffprobe" -v error -count_frames -show_streams -show_format -of json "$out/selftest.flv" > "$out/probe.json"
"$ffmpeg" -hide_banner -i "$out/selftest.flv" -an -vf 'crop=iw:ih/20:0:ih*19/20,signalstats,metadata=print' -f null - > "$out/flash.log" 2>&1
# Both demo audio sources beep on the same host epoch; ignore AAC noise below -20 dB.
"$ffmpeg" -hide_banner -i "$out/selftest.flv" -vn -af 'silencedetect=noise=-20dB:d=0.1' -f null - > "$out/beep.log" 2>&1
python3 - "$out" "$canvas" <<'PY'
import json,pathlib,re,sys
p=pathlib.Path(sys.argv[1]); canvas=sys.argv[2]
d=json.loads((p/'probe.json').read_text())
v=next(s for s in d['streams'] if s['codec_type']=='video')
a=next(s for s in d['streams'] if s['codec_type']=='audio')
n,den=map(int,v['r_frame_rate'].split('/')); fps=n/den
duration=float(d['format']['duration'])
actual=int(v['nb_read_frames'])/duration
print(f"{canvas}: {v['codec_name']} {v['width']}x{v['height']} {fps:.3f} fps; {a['codec_name']} {a['sample_rate']} Hz {a['channels']} channels; duration={duration:.3f}s; decoded={actual:.2f} fps")
assert v['codec_name']=='h264' and (v['width'],v['height'])==((1920,1080) if canvas=='wide' else (1080,1920))
# Allow 5% arrival-time selection jitter; nominal metadata alone is not sufficient.
assert abs(actual-60)<=3 and abs(fps-60)<2 and a['codec_name']=='aac' and a['sample_rate']=='48000' and a['channels']==2
assert abs(duration-20)<1
# The bottom strip also encodes a binary counter. A flash is an isolated near-white peak, not just any rising bit.
frames=[]; time=None
for line in (p/'flash.log').read_text().splitlines():
    m=re.search(r'pts_time:([0-9.]+)',line)
    if m:time=float(m[1])
    m=re.search(r'lavfi.signalstats.YAVG=([0-9.]+)',line)
    if m and time is not None:frames.append((time,float(m[1])))
peak=max(y for _,y in frames)
flashes=[t for i,(t,y) in enumerate(frames) if 0<i<len(frames)-1 and y>peak*0.98 and y-frames[i-1][1]>20 and y-frames[i+1][1]>20]
beeps=[float(x) for x in re.findall(r'silence_end: ([0-9.]+)',(p/'beep.log').read_text())]
assert flashes and beeps, 'FAIL: no flash/beep detected'
flash=flashes[0]; beep=min(beeps,key=lambda t:abs(t-flash))
delta=(flash-beep)*1000
print(f"flash={flash:.6f}s beep={beep:.6f}s flash-minus-beep={delta:+.2f}ms")
assert abs(delta)<=45, 'FAIL: A/V sync exceeds ±45 ms'
print('PASS: codec, size, rate, duration and A/V sync')
print(f'Artifacts: {p}')
PY
