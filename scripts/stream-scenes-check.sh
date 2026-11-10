#!/bin/bash
# Verification only: streams the demo source to two local listeners (16:9 and 9:16) while --scene-script switches
# scenes and the live zoom, then pulls frames from both received files before, during and after each scripted action
# and checks that both pictures changed. Usage:
#   scripts/stream-scenes-check.sh                      # default scenes, two switches and one punch-in
#   CHECK_SCENES=my-scenes.json CHECK_SCRIPT="9:scene=Overlays" CHECK_PROBES="10,11,12,13" scripts/stream-scenes-check.sh
# CHECK_SCENES is copied, never written. CHECK_ASSETS is the overlay asset folder (default: an empty one in the
# output folder). CHECK_PROBES are extra stream times (seconds) to extract frames at. CHECK_RECORD=<seconds> also
# records during the stream (from 4 s after launch). CHECK_LIVE_FOR is the stream length (default 25 s); CHECK_ARGS
# adds app arguments (for example --stream-restart-after 8, a capture restart while live). Ports
# default to 23935 (wide) and 23936 (vertical).
set -euo pipefail
cd "$(dirname "$0")/.."
ffmpeg=/opt/homebrew/bin/ffmpeg
ffprobe=/opt/homebrew/bin/ffprobe
out="${CHECK_DIR:-$(mktemp -d /tmp/ehdr-scenes.XXXXXX)}"
mkdir -p "$out/frames"
wide_port="${CHECK_WIDE_PORT:-23935}" tall_port="${CHECK_TALL_PORT:-23936}"
script="${CHECK_SCRIPT:-8:next,12:punch,16:next}"
live_for="${CHECK_LIVE_FOR:-25}"
extra=()
if [[ -n "${CHECK_ARGS:-}" ]]; then read -ra extra <<< "$CHECK_ARGS"; fi
pids=()
cleanup() { for p in ${pids[@]+"${pids[@]}"}; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT
if [[ "${CHECK_SKIP_BUILD:-0}" != 1 ]]; then ./build.sh > "$out/build.log" 2>&1; fi
for port in "$wide_port" "$tall_port"; do
    "$ffmpeg" -hide_banner -loglevel warning -y -listen 1 -i "rtmp://127.0.0.1:$port/live/test" -t $((live_for - 1)) -c copy "$out/out-$port.flv" > "$out/listener-$port.log" 2>&1 &
    pids+=($!)
done
sleep 1
scenes="$out/scenes.json"
if [[ -n "${CHECK_SCENES:-}" ]]; then cp "$CHECK_SCENES" "$scenes"; fi
cat > "$out/streaming.json" <<JSON
{"destinations":[
 {"id":"6D1A3F0E-5B7C-4C2A-9E61-0F3B8D2A7C41","service":"custom","name":"Local wide","url":"rtmp://127.0.0.1:$wide_port/live","canvas":"wide","enabled":true},
 {"id":"6D1A3F0E-5B7C-4C2A-9E61-0F3B8D2A7C42","service":"custom","name":"Local vertical","url":"rtmp://127.0.0.1:$tall_port/live","canvas":"vertical","enabled":true}],
 "settings":{"resolution":1080,"fps":60,"videoKbps":6000,"audioKbps":160,"micDelayMs":0}}
JSON
EHDR_STREAM_KEY=test EHDR_STREAMING_FILE="$out/streaming.json" EHDR_SCENES_FILE="$scenes" \
    EHDR_ASSETS_DIR="${CHECK_ASSETS:-$out/Assets}" "dist/Elgato HDR.app/Contents/MacOS/ElgatoHDR" \
    --demo-source "${CHECK_SOURCE:-2560x1440@60}" --demo-camera -presentation game -recordingsDir "$out/recordings" \
    ${CHECK_RECORD:+--record "$CHECK_RECORD"} --scene-script "$script" --go-live-for "$live_for" ${extra[@]+"${extra[@]}"} > "$out/app.log" 2>&1 &
app=$!; pids+=("$app")
for ((i=0;i<live_for+25;i++)); do kill -0 "$app" 2>/dev/null || break; sleep 1; done
if kill -0 "$app" 2>/dev/null; then echo 'FAIL: app did not terminate'; exit 1; fi
wait "$app" || true
for p in ${pids[@]+"${pids[@]}"}; do kill "$p" 2>/dev/null || true; done
pids=()
python3 - "$out" "$wide_port" "$tall_port" "${CHECK_PROBES:-}" <<'PY'
import json, pathlib, re, subprocess, sys
out = pathlib.Path(sys.argv[1]); ports = {sys.argv[2]: 'wide', sys.argv[3]: 'vertical'}
probes = [float(x) for x in sys.argv[4].split(',') if x]
ffmpeg, ffprobe = '/opt/homebrew/bin/ffmpeg', '/opt/homebrew/bin/ffprobe'
log = (out / 'app.log').read_text()
base = {m[1]: int(m[2]) for m in re.finditer(r'RTMP 127\.0\.0\.1:(\d+): stream time 0 is host (\d+) ns', log)}
actions = [(m[1], int(m[2])) for m in re.finditer(r'scene-script: (.+?) at host (\d+) ns', log)]
print('actions:', ', '.join(a for a, _ in actions) or 'none')
def frame(f, t, w, h):
    r = subprocess.run([ffmpeg, '-v', 'error', '-ss', f'{t:.3f}', '-i', str(f), '-frames:v', '1', '-vf', f'scale={w}:{h}',
                        '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'], capture_output=True)
    return r.stdout
def png(f, t, name):
    subprocess.run([ffmpeg, '-v', 'error', '-y', '-ss', f'{t:.3f}', '-i', str(f), '-frames:v', '1', str(out / 'frames' / name)], check=True)
def diff(a, b): return sum(abs(x - y) for x, y in zip(a, b)) / max(1, len(a))
ok = True
for port, canvas in ports.items():
    f = out / f'out-{port}.flv'
    p = json.loads(subprocess.run([ffprobe, '-v', 'error', '-count_frames', '-show_streams', '-show_format', '-of', 'json', str(f)], capture_output=True, text=True).stdout)
    v = next(s for s in p['streams'] if s['codec_type'] == 'video')
    print(f"{canvas} ({port}): {v['codec_name']} {v['width']}x{v['height']} frames={v['nb_read_frames']} duration={float(p['format']['duration']):.2f}s")
    if port not in base: print(f'FAIL: no stream time 0 line for {port}'); ok = False; continue
    w, h = (64, 36) if canvas == 'wide' else (36, 64)
    for n, (name, host) in enumerate(actions):
        t = (host - base[port]) / 1e9
        shots = {'before': t - 0.30, 'during-120ms': t + 0.12, 'during-200ms': t + 0.20, 'after': t + 0.90}
        raw = {k: frame(f, s, w, h) for k, s in shots.items()}
        slug = re.sub(r'[^A-Za-z0-9]+', '-', name).strip('-')
        for k, s in shots.items(): png(f, s, f'{canvas}-{n + 1}-{slug}-{k}.png')
        d_total, d_mid = diff(raw['before'], raw['after']), diff(raw['before'], raw['during-200ms'])
        changed = d_total > 4 and d_mid > 1
        ok &= changed
        print(f"  {name} at stream {t:6.3f}s: before→during {d_mid:5.1f}, before→after {d_total:5.1f} (mean |Δ| per channel) {'changed' if changed else 'FAIL: unchanged'}")
    for s in probes: png(f, s, f'{canvas}-probe-{s:05.2f}s.png')
print('PASS: both outputs show every scripted change' if ok else 'FAIL: see above')
print(f'Artifacts: {out}')
sys.exit(0 if ok else 1)
PY
