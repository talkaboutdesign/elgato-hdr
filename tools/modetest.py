# Cycle the root helper through every P010 mode and measure delivered fps + audio. Run while no app client is connected.
import socket, struct, time, sys
SOCK="/tmp/elgato-uvc.sock"
modes=[tuple(float(x) if "." in x else int(x) for x in m.split("@")) for m in sys.argv[2].split(",")] if len(sys.argv)>2 else [(1,120),(1,60),(2,120),(2,60),(2,30),(3,60),(4,60),(4,30),(5,30),(5,29.97)]
secs=float(sys.argv[1]) if len(sys.argv)>1 else 3.0
print(f"{'frame':>5} {'req fps':>8} {'res':>10} {'frames':>6} {'fps':>6} {'audio s':>8}  status")
for frm,fps in modes:
    s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.settimeout(8)
    try: s.connect(SOCK)
    except Exception as e: print("connect failed:",e); break
    s.sendall(f"START 7 {frm} {fps}\n".encode())
    buf=bytearray(64*1024*1024)
    def rd(n):
        mv=memoryview(buf)[:n]; got=0
        while got<n:
            r=s.recv_into(mv[got:],n-got)
            if r<=0: return None
            got+=r
        return mv
    n=0; abytes=0; res="?"; t0=None; status="ok"; tstart=time.time()
    try:
        while True:
            h=rd(32)
            if h is None: status="stream ended" if n==0 else "ended early"; break
            magic=bytes(h[:4]); a,b,c,size=struct.unpack("<IIII",bytes(h[4:20]))
            if magic==b"UVCF":
                res=f"{a}x{b}"; rd(size)
                if t0 is None: t0=time.time()
                n+=1
            elif magic==b"UVCA": abytes+=size; rd(size)
            else: status="bad magic"; break
            if t0 and time.time()-t0>=secs: break
            if t0 is None and time.time()-tstart>5: status="NO VIDEO (audio only)"; break
    except socket.timeout: status="timeout (no data)"
    dt=(time.time()-t0) if t0 else 0
    print(f"{frm:>5} {fps:>8} {res:>10} {n:>6} {n/dt if dt else 0:>6.1f} {abytes/(48000*4):>8.1f}  {status}", flush=True)
    s.close(); time.sleep(1.5)  # let helper release/re-capture the device
