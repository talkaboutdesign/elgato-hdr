#!/bin/bash
# A bounded 60-second two-lane + HEVC recording measurement, using only isolated demo inputs and local receivers.
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
cd "$(dirname "$0")/.."
out="${LOAD_DIR:-$(mktemp -d /tmp/ehdr-load.XXXXXX)}"
mkdir -p "$out"
app="${LOAD_APP:-dist/Elgato HDR.app/Contents/MacOS/ElgatoHDR}"
wide="${LOAD_WIDE_PORT:-26401}" tall="${LOAD_TALL_PORT:-26402}"
[[ "$wide" -gt 25000 && "$tall" -gt 25000 && "$wide" != "$tall" ]]
if [[ "${LOAD_SKIP_BUILD:-0}" != 1 ]]; then ./build.sh debug > "$out/build.log" 2>&1; fi
pids=()
cleanup() { for p in ${pids[@]+"${pids[@]}"}; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT
uptime | tee "$out/load.txt"
cat > "$out/streaming.json" <<JSON
{"destinations":[
{"id":"6D1A3F0E-5B7C-4C2A-9E61-0F3B8D2A7C41","service":"custom","name":"Local wide","url":"rtmp://127.0.0.1:$wide/live","canvas":"wide","enabled":true},
{"id":"6D1A3F0E-5B7C-4C2A-9E61-0F3B8D2A7C42","service":"custom","name":"Local vertical","url":"rtmp://127.0.0.1:$tall/live","canvas":"vertical","enabled":true}],
"settings":{"resolution":1080,"fps":60,"videoKbps":6000,"audioKbps":160,"micDelayMs":0}}
JSON
for port in "$wide" "$tall"; do
    /opt/homebrew/bin/ffmpeg -hide_banner -loglevel warning -y -listen 1 -i "rtmp://127.0.0.1:$port/live/test" -t 64 -c copy "$out/out-$port.flv" > "$out/listener-$port.log" 2>&1 &
    pids+=($!)
done
sleep 1
EHDR_STREAM_KEY=test EHDR_STREAMING_FILE="$out/streaming.json" EHDR_SCENES_FILE="$out/scenes.json" EHDR_ASSETS_DIR="$out/Assets" \
    "$app" --demo-source 2560x1440@60 --demo-camera -presentation game -recordingsDir "$out/recordings" \
    --record 60 --go-live-for 65 --scene-script '8:next,12:punch,16:next' > "$out/app.log" 2>&1 &
app_pid=$!; pids+=("$app_pid")
for ((i=0;i<90;i++)); do kill -0 "$app_pid" 2>/dev/null || break; sleep 1; done
if kill -0 "$app_pid" 2>/dev/null; then echo 'FAIL: app did not terminate'; exit 1; fi
wait "$app_pid"
uptime | tee -a "$out/load.txt"
python3 - "$out" <<'PY'
import pathlib,re,statistics,sys
p=pathlib.Path(sys.argv[1]); log=(p/'app.log').read_text()
for lane in ['wide','vertical']:
    fps=[float(v) for v in re.findall(r'stream '+lane+r': ([\d.]+) fps',log)]
    assert len(fps)>6, 'FAIL: missing lane statistics'
    print(f'{lane}: steady fps={statistics.mean(fps[2:-4]):.3f}')
for line in log.splitlines():
    if line.startswith(('encoder summary','program ' ,'saved game.mov')): print(line)
cost=[(int(a),int(n)) for a,n in re.findall(r'reader cost: program outputs (\d+) µs avg / \d+ max \((\d+)\) per frame \(2 lanes\)',log)]
assert cost, 'FAIL: no reader measurements'
print(f'reader cost (both lanes): {sum(a*n for a,n in cost)/sum(n for a,n in cost):.1f} µs/frame')
lat=[line for line in log.splitlines() if 'helper->screen' in line and 'helper->screen 0.0' not in line]
print('window first: '+(lat[0] if lat else 'no presented-frame samples'))
print('window last: '+(lat[-1] if lat else 'no presented-frame samples'))
print(f'Artifacts: {p}')
sys.path.insert(0,'scripts')
from stream_checks import check_drops
check_drops(log)
PY
