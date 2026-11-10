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
port="${SELFTEST_PORT:-1948}"
app_pid= listener_pid=
cleanup() {
    if [[ -n "$app_pid" ]]; then kill "$app_pid" 2>/dev/null || true; fi
    if [[ -n "$listener_pid" ]]; then kill "$listener_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT
if [[ "${SELFTEST_SKIP_BUILD:-0}" != 1 ]]; then ./build.sh > "$out/build.log" 2>&1; fi
"$ffmpeg" -hide_banner -loglevel warning -y -listen 1 -i rtmp://127.0.0.1:$port/live/test -t 20 -c copy "$out/selftest.flv" > "$out/listener.log" 2>&1 &
listener_pid=$!
sleep 1
EHDR_STREAM_KEY=test "dist/Elgato HDR.app/Contents/MacOS/ElgatoHDR" \
    --demo-source "${SELFTEST_SOURCE:-2560x1440@60}" --demo-camera \
    -presentation "${SELFTEST_PRESENTATION:-game}" -streamURL rtmp://127.0.0.1:$port/live \
    -recordingsDir "$out/recordings" ${SELFTEST_RECORD:+--record "$SELFTEST_RECORD"} \
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
"$ffprobe" -v error -select_streams v:0 -show_entries frame=best_effort_timestamp_time -of json "$out/selftest.flv" > "$out/pts.json"
# Separate the 1 kHz game and 2 kHz mic markers before measuring every onset.
"$ffmpeg" -hide_banner -i "$out/selftest.flv" -vn -af 'bandpass=f=1000:width_type=h:w=200,silencedetect=noise=-30dB:d=0.1' -f null - > "$out/beep.log" 2>&1
"$ffmpeg" -hide_banner -i "$out/selftest.flv" -vn -af 'bandpass=f=2000:width_type=h:w=200,silencedetect=noise=-30dB:d=0.1' -f null - > "$out/mic.log" 2>&1
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
pts=[float(f['best_effort_timestamp_time']) for f in json.loads((p/'pts.json').read_text())['frames']]
gaps=[b-a for a,b in zip(pts,pts[1:]) if a>=pts[0]+1]
print(f"maximum video PTS gap after first second: {max(gaps)*1000:.3f} ms")
assert max(gaps)<=1.5/60, 'FAIL: video stutter'
drops=re.findall(r'dropped render=(\d+) encoder=(\d+)',(p/'app.log').read_text())
assert drops and all(int(r)==0 and int(e)==0 for r,e in drops), 'FAIL: render/encoder drops'
print('render drops=0 encoder drops=0')
assert abs(actual-60)<=0.5 and abs(fps-60)<2 and a['codec_name']=='aac' and a['sample_rate']=='48000' and a['channels']==2
assert abs(duration-20)<1
# The bottom strip also encodes a binary counter; identify the periodic flash from video alone.
frames=[]; time=None
for line in (p/'flash.log').read_text().splitlines():
    m=re.search(r'pts_time:([0-9.]+)',line)
    if m:time=float(m[1])
    m=re.search(r'lavfi.signalstats.YAVG=([0-9.]+)',line)
    if m and time is not None:frames.append((time,float(m[1])))
peak=max(y for _,y in frames)
flashes=[t for t,y in frames if y>peak*0.98]
assert flashes, 'FAIL: no flashes detected'
# All eight counter bits also turn white every 256 frames. The actual flash repeats at one second;
# determine its phase from video alone, then require every expected flash (never fit to audio).
def phase_distance(a,b): return abs((a-b+0.5)%1-0.5)
anchor=max(flashes,key=lambda f:sum(phase_distance(f,t)<0.03 for t in flashes))
phase=anchor%1
expected=[phase+i for i in range(int(duration)) if 0.1<phase+i<duration-0.1]
flashes=[min(flashes,key=lambda t:abs(t-e)) for e in expected]
assert all(abs(t-e)<0.03 for t,e in zip(flashes,expected)), 'FAIL: missing video flash'
assert len(flashes)>=18 and all(abs(b-a-1)<0.05 for a,b in zip(flashes,flashes[1:])), 'FAIL: missing video flash'
for source, filename in [('game','beep.log'),('mic','mic.log')]:
    beeps=[float(x) for x in re.findall(r'silence_end: ([0-9.]+)',(p/filename).read_text())]
    assert beeps, f'FAIL: no {source} beep detected'
    pairs=[(f,min(beeps,key=lambda t:abs(t-f))) for f in flashes]
    deltas=[(f-b)*1000 for f,b in pairs]
    assert len(set(b for f,b in pairs))==len(pairs), 'FAIL: missing beep'
    print(f"{source} A/V pairs={len(deltas)} min/mean/max={min(deltas):+.2f}/{sum(deltas)/len(deltas):+.2f}/{max(deltas):+.2f} ms")
    assert all(abs(d)<=45 for d in deltas), f'FAIL: {source} A/V sync exceeds ±45 ms'
print('PASS: codec, size, rate, duration and A/V sync')
print(f'Artifacts: {p}')
PY
