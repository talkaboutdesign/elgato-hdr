# Wrap raw P010 frames from stdin into the UVCF stream format hdrview expects.
import sys, struct, time
w, h, fps = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3])
size = w*h*3; seq = 0
inp, out = sys.stdin.buffer, sys.stdout.buffer
while True:
    d = inp.read(size)
    if len(d) < size: break
    out.write(b"UVCF" + struct.pack("<IIi", w, h, 0) [:8] + b"P010" + struct.pack("<IQI", size, time.monotonic_ns(), seq)); out.write(d); out.flush()
    seq += 1; time.sleep(1.0/fps)
