// Direct UVC capture for Elgato 4K X (bypasses AppleUSBVideo to reach the hidden P010 format).
// Needs root: libusb re-enumerates the device with capture flag to detach the kernel driver.
//
//   uvc_capture [--format 7] [--frame 5] [--fps 30] [--count N] [--out PATH|-] [--dump-prefix P]
//
// Output stream: per frame a 32-byte header {magic "UVCF", u32 width, u32 height, u32 fourcc, u32 size, u64 t_ns, u32 seq} + raw payload.
#include <libusb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>
#include <math.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <poll.h>

#define VID 0x0fd9
#define PID 0x009b
#define VS_IFACE 1
#define VC_IFACE 0
#define EP_IN 0x82
#define NUM_XFERS 16

static volatile int running = 1;
static volatile int quit_all = 0;
static void on_sig(int s){ (void)s; running = 0; quit_all = 1; }

static uint16_t le16(const uint8_t *p){return p[0]|(p[1]<<8);}
static uint32_t le32(const uint8_t *p){return p[0]|(p[1]<<8)|(p[2]<<16)|(p[3]<<24);}
static void put16(uint8_t *p,uint16_t v){p[0]=v;p[1]=v>>8;}
static void put32(uint8_t *p,uint32_t v){p[0]=v;p[1]=v>>8;p[2]=v>>16;p[3]=v>>24;}
static uint64_t now_ns(void){struct timespec ts; clock_gettime(CLOCK_UPTIME_RAW,&ts); return (uint64_t)ts.tv_sec*1000000000ull+ts.tv_nsec;}

// Descriptor lookup: find width/height/fourcc for a format/frame index.
typedef struct { int fmt, frm, w, h; char fourcc[5]; uint32_t dflt_interval; int n_intervals; uint32_t intervals[16]; } FrameInfo;
static int lookup_frame(libusb_device *dev, int fmt, int frm, FrameInfo *out){
    struct libusb_config_descriptor *cfg; if(libusb_get_active_config_descriptor(dev,&cfg)) return -1;
    int found=0;
    for(int k=0;k<cfg->bNumInterfaces && !found;k++){
        const struct libusb_interface_descriptor *id=&cfg->interface[k].altsetting[0];
        if(id->bInterfaceClass!=0x0e||id->bInterfaceSubClass!=2) continue;
        const uint8_t *p=id->extra; int len=id->extra_length; int cur_fmt=-1; char fcc[5]="????";
        while(len>=3){ int bl=p[0],bt=p[1],st=p[2]; if(bl<3||bl>len)break;
            if(bt==0x24){
                if(st==0x04||st==0x10){cur_fmt=p[3]; memcpy(fcc,p+5,4); fcc[4]=0;}
                else if(st==0x06){cur_fmt=p[3]; strcpy(fcc,"MJPG");}
                else if((st==0x05||st==0x07||st==0x11) && cur_fmt==fmt && p[3]==frm){
                    out->fmt=fmt; out->frm=frm; out->w=le16(p+5); out->h=le16(p+7); strcpy(out->fourcc,fcc);
                    int fb = (st==0x11); // frame-based layout differs slightly
                    out->dflt_interval = le32(p+(fb?17:21)); int n = p[fb?21:25]; const uint8_t *iv = p+26;
                    out->n_intervals=0;
                    for(int i=0;i<n && i<16 && iv+4*i+4<=p+bl;i++) out->intervals[out->n_intervals++]=le32(iv+4*i);
                    found=1; break;
                }
            }
            p+=bl; len-=bl; }
    }
    libusb_free_config_descriptor(cfg); return found?0:-1;
}

// UVC 1.0 probe/commit control is 26 bytes.
#define PROBE_LEN 26
static int vs_ctrl(libusb_device_handle *h, int set, int selector, uint8_t *buf, int len){
    // set: 1 = SET_CUR(0x01), 0 = GET_CUR(0x81)
    return libusb_control_transfer(h, set?0x21:0xA1, set?0x01:0x81, selector<<8, VS_IFACE, buf, len, 1000);
}
static void print_probe(const char *tag,const uint8_t *b){
    fprintf(stderr,"%s: hint=%04x fmt=%d frm=%d interval=%u (%.2ffps) maxFrameSize=%u maxPayload=%u\n",
        tag, le16(b), b[2], b[3], le32(b+4), le32(b+4)?10000000.0/le32(b+4):0, le32(b+18), le32(b+22));
}

// Stream state
static int out_fd = 1;
static FrameInfo fi;
static uint32_t frame_size, max_payload;
static uint8_t *frame_buf; static uint32_t frame_fill = 0; static int cur_fid = -1;
static uint32_t seq = 0, frames_ok = 0, frames_bad = 0, want_count = 0;
static const char *dump_prefix = NULL;
static uint64_t t_start;
static volatile uint64_t video_bytes_seen=0;
static int au_enabled;
static void audio_flush(void);
static int use_shm;
static uint8_t *shm_slot(uint32_t n);
// Per-frame USB timing: first payload byte -> end of frame (how long the card takes to deliver one frame).
static uint64_t t_first = 0, t_report = 0, t_prev_eof = 0;
static double xfer_sum = 0, xfer_max = 0, gap_sum = 0; static uint32_t xfer_n = 0;

static int write_all(int fd,const void *p,size_t n){ const uint8_t *b=p; while(n){ ssize_t w=write(fd,b,n); if(w<0){ if(errno==EINTR)continue; return -1;} b+=w; n-=w;} return 0; }

static void emit_frame(void){
    int exact = frame_fill == frame_size;
    if(exact) frames_ok++; else frames_bad++;
    uint64_t t = now_ns();
    if((frames_ok+frames_bad)%30==1 || !exact)
        fprintf(stderr,"[%6.2fs] frame %u: %u bytes %s (ok=%u bad=%u)\n",(t-t_start)/1e9,seq,frame_fill,exact?"exact":"SHORT/LONG",frames_ok,frames_bad);
    if(!exact) return; // drop incomplete frames
    if(t_first){
        double d=(t-t_first)/1e6; xfer_sum+=d; if(d>xfer_max) xfer_max=d; xfer_n++;
        if(t_prev_eof && t_first>t_prev_eof) gap_sum+=(t_first-t_prev_eof)/1e6;
    }
    t_prev_eof=t; t_first=0;
    if(t-t_report>=1000000000ull){
        if(xfer_n) fprintf(stderr,"usb timing: first byte -> end of frame %.1f ms avg / %.1f max, idle between frames %.1f ms avg (%u frames)\n",xfer_sum/xfer_n,xfer_max,gap_sum/xfer_n,xfer_n);
        xfer_sum=0; xfer_max=0; gap_sum=0; xfer_n=0; t_report=t;
    }
    if(au_enabled) audio_flush();
    if(dump_prefix){
        char name[512]; snprintf(name,sizeof name,"%s.frame%04u.bin",dump_prefix,seq);
        int fd=open(name,O_WRONLY|O_CREAT|O_TRUNC,0644); if(fd>=0){write_all(fd,frame_buf,frame_fill); close(fd);}
    } else {
        uint8_t hdr[32]={0}; memcpy(hdr,use_shm?"UVCS":"UVCF",4); put32(hdr+4,fi.w); put32(hdr+8,fi.h); memcpy(hdr+12,fi.fourcc,4); put32(hdr+16,frame_size);
        memcpy(hdr+20,&t,8); put32(hdr+28,seq);
        if(use_shm){
            if(write_all(out_fd,hdr,32)){ fprintf(stderr,"output closed\n"); running=0; }
            frame_buf = shm_slot(seq+1);   // next frame lands in the next slot; client reads slot seq%3
        } else if(write_all(out_fd,hdr,32)||write_all(out_fd,frame_buf,frame_fill)){ fprintf(stderr,"output closed\n"); running=0; }
    }
    seq++;
    if(want_count && frames_ok>=want_count) running=0;
}



// ---- Shared-memory frame ring (zero-copy delivery to the client) ----
#define SHM_NAME "/elgato-uvc-frames"
#define SHM_SLOTS 3
#define SHM_SLOT_BYTES 24883200u   // 3840x2160 P010; multiple of 4096
static uint8_t *shm_base = NULL;
static int shm_setup(void){
    int fd = shm_open(SHM_NAME, O_CREAT|O_RDWR, 0666);
    if(fd<0){ perror("shm_open"); return -1; }
    fchmod(fd, 0666);
    size_t total = (size_t)SHM_SLOTS*SHM_SLOT_BYTES;
    struct stat st; if(fstat(fd,&st)==0 && (size_t)st.st_size < total){ if(ftruncate(fd,total)){ perror("ftruncate"); close(fd); return -1; } }
    shm_base = mmap(NULL,total,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
    close(fd);
    if(shm_base==MAP_FAILED){ perror("mmap"); shm_base=NULL; return -1; }
    fprintf(stderr,"shared frame ring %s: %d x %u bytes\n",SHM_NAME,SHM_SLOTS,SHM_SLOT_BYTES);
    return 0;
}
static uint8_t *shm_slot(uint32_t n){ return shm_base + (size_t)(n%SHM_SLOTS)*SHM_SLOT_BYTES; }

// ---- Audio (UAC1: iso IN EP 0x83, 48 kHz stereo 16-bit) ----
#define AU_IFACE 3
#define AU_EP 0x83
#define AU_PKT 208
#define AU_PKTS_PER_XFER 8
#define NUM_AU_XFERS 16
#define AU_FLUSH_BYTES 1920   // 10 ms of 48k stereo s16
static uint8_t au_buf[65536]; static uint32_t au_fill=0, au_seq=0;
static uint64_t au_bytes_total=0;
static void audio_flush(void){
    if(!au_fill || dump_prefix) { au_fill=0; return; }
    uint8_t hdr[32]={0}; memcpy(hdr,"UVCA",4); put32(hdr+4,48000); put32(hdr+8,2); put32(hdr+12,16); put32(hdr+16,au_fill);
    uint64_t t=now_ns(); memcpy(hdr+20,&t,8); put32(hdr+28,au_seq++);
    if(write_all(out_fd,hdr,32)||write_all(out_fd,au_buf,au_fill)){ fprintf(stderr,"output closed (audio)\n"); running=0; }
    au_bytes_total+=au_fill; au_fill=0;
}
static void LIBUSB_CALL audio_cb(struct libusb_transfer *t){
    if(t->status==LIBUSB_TRANSFER_COMPLETED){
        for(int i=0;i<t->num_iso_packets;i++){
            struct libusb_iso_packet_descriptor *d=&t->iso_packet_desc[i];
            if(d->status!=LIBUSB_TRANSFER_COMPLETED||d->actual_length==0) continue;
            uint8_t *p=libusb_get_iso_packet_buffer_simple(t,i);
            uint32_t n=d->actual_length & ~3u; // whole stereo s16 frames
            if(au_fill+n>sizeof au_buf) audio_flush();
            memcpy(au_buf+au_fill,p,n); au_fill+=n;
        }
        if(au_fill>=AU_FLUSH_BYTES) audio_flush();
    } else if(t->status!=LIBUSB_TRANSFER_CANCELLED) fprintf(stderr,"audio transfer status %d\n",t->status);
    if(running && t->status!=LIBUSB_TRANSFER_CANCELLED){ if(libusb_submit_transfer(t)){ fprintf(stderr,"audio resubmit failed\n"); } }
}
static int audio_start(libusb_device_handle *h, struct libusb_transfer **xf){
    int r;
    if(libusb_kernel_driver_active(h,AU_IFACE)==1){ r=libusb_detach_kernel_driver(h,AU_IFACE); fprintf(stderr,"detach audio iface: %s\n",r?libusb_error_name(r):"ok"); }
    r=libusb_claim_interface(h,AU_IFACE); if(r){ fprintf(stderr,"claim audio iface: %s\n",libusb_error_name(r)); return -1; }
    r=libusb_set_interface_alt_setting(h,AU_IFACE,1); if(r){ fprintf(stderr,"audio alt 1: %s\n",libusb_error_name(r)); return -1; }
    uint8_t freq[3]={0x80,0xBB,0x00}; // 48000
    r=libusb_control_transfer(h,0x22,0x01,0x0100,AU_EP,freq,3,1000); fprintf(stderr,"audio SET_CUR sampling freq: %d\n",r);
    for(int i=0;i<NUM_AU_XFERS;i++){
        xf[i]=libusb_alloc_transfer(AU_PKTS_PER_XFER);
        uint8_t *b=malloc(AU_PKT*AU_PKTS_PER_XFER);
        libusb_fill_iso_transfer(xf[i],h,AU_EP,b,AU_PKT*AU_PKTS_PER_XFER,AU_PKTS_PER_XFER,audio_cb,NULL,0);
        libusb_set_iso_packet_lengths(xf[i],AU_PKT);
        if((r=libusb_submit_transfer(xf[i]))){ fprintf(stderr,"audio submit %d: %s\n",i,libusb_error_name(r)); return -1; }
    }
    au_fill=0; au_seq=0; au_bytes_total=0; au_enabled=1;
    fprintf(stderr,"audio streaming 48k stereo s16\n");
    return 0;
}
static void audio_stop(libusb_device_handle *h, struct libusb_transfer **xf, libusb_context *ctx){
    if(!au_enabled) return;
    for(int i=0;i<NUM_AU_XFERS;i++) if(xf[i]) libusb_cancel_transfer(xf[i]);
    for(int k=0;k<10;k++){ struct timeval tv={0,50000}; libusb_handle_events_timeout_completed(ctx,&tv,NULL); }
    for(int i=0;i<NUM_AU_XFERS;i++) if(xf[i]){ free(xf[i]->buffer); libusb_free_transfer(xf[i]); xf[i]=NULL; }
    libusb_set_interface_alt_setting(h,AU_IFACE,0);
    libusb_release_interface(h,AU_IFACE); libusb_attach_kernel_driver(h,AU_IFACE);
    fprintf(stderr,"audio stopped (%.1f s delivered)\n",au_bytes_total/(48000.0*4));
    au_enabled=0;
}

// Parse one bulk transfer buffer: sequence of payloads, each = header + data, size = min(max_payload, what remains in frame).
static void parse_transfer(const uint8_t *buf, int len){
    int off=0;
    while(off<len){
        int hl=buf[off];
        if(hl<2||hl>12||off+hl>len){ fprintf(stderr,"bad header len %d at %d/%d\n",hl,off,len); frames_bad++; frame_fill=0; return; }
        uint8_t flags=buf[off+1];
        int fid=flags&1, eof=(flags>>1)&1, err=(flags>>6)&1;
        if(cur_fid<0) cur_fid=fid;
        if(fid!=cur_fid){ // frame boundary without EOF
            if(frame_fill) emit_frame();
            frame_fill=0; cur_fid=fid;
        }
        int avail=len-off-hl;
        int want=(int)max_payload-hl; if(want>avail) want=avail;
        uint32_t remain = frame_size>frame_fill ? frame_size-frame_fill : 0;
        if((uint32_t)want>remain) want=remain;
        if(err){ frame_fill=0; t_first=0; }
        else if(want>0){ if(!frame_fill) t_first=now_ns(); memcpy(frame_buf+frame_fill,buf+off+hl,want); frame_fill+=want; }
        off += hl + want;
        if(eof || frame_fill>=frame_size){ emit_frame(); frame_fill=0; cur_fid=-1; }
        // If the payload was shorter than max_payload (short packet), the transfer ended here.
        if(hl+want < (int)max_payload) break;
    }
}

static void LIBUSB_CALL xfer_cb(struct libusb_transfer *t){
    if(t->status==LIBUSB_TRANSFER_COMPLETED){ if(t->actual_length>0){ video_bytes_seen+=t->actual_length; parse_transfer(t->buffer,t->actual_length); } }
    else if(t->status!=LIBUSB_TRANSFER_CANCELLED){ fprintf(stderr,"transfer status %d\n",t->status); }
    if(running && t->status!=LIBUSB_TRANSFER_CANCELLED){ if(libusb_submit_transfer(t)){ fprintf(stderr,"resubmit failed\n"); running=0; } }
}


// Run one capture session: open device, detach, probe/commit, stream to out_fd until output closes or running=0.
static int run_session(int fmt, int frm, double fps, int nofps, int want_audio){
    struct libusb_transfer *au_xf[NUM_AU_XFERS]={0};
    libusb_context *ctx; if(libusb_init(&ctx)){fprintf(stderr,"libusb_init failed\n");return 1;}
    libusb_device_handle *h=libusb_open_device_with_vid_pid(ctx,VID,PID);
    if(!h){fprintf(stderr,"Elgato 4K X not found / open failed\n");libusb_exit(ctx);return 1;}
    libusb_device *dev=libusb_get_device(h);
    if(lookup_frame(dev,fmt,frm,&fi)){fprintf(stderr,"format %d frame %d not in descriptors\n",fmt,frm);libusb_close(h);libusb_exit(ctx);return 1;}
    fprintf(stderr,"Selected format %d (%s) frame %d: %dx%d\n",fmt,fi.fourcc,frm,fi.w,fi.h);
    int r, rc=1;
    for(int iface=0; iface<=1; iface++){
        if(libusb_kernel_driver_active(h,iface)==1){
            r=libusb_detach_kernel_driver(h,iface);
            fprintf(stderr,"detach kernel driver iface %d: %s\n",iface,r?libusb_error_name(r):"ok");
            if(r && iface==VS_IFACE){ fprintf(stderr,"Cannot detach AppleUSBVideo. Run as root (sudo).\n"); goto out_close; }
        }
    }
    r=libusb_claim_interface(h,VC_IFACE); fprintf(stderr,"claim VC iface: %s\n",r?libusb_error_name(r):"ok");
    r=libusb_claim_interface(h,VS_IFACE); fprintf(stderr,"claim VS iface: %s\n",r?libusb_error_name(r):"ok");
    if(r){ fprintf(stderr,"claim failed: %s\n",libusb_error_name(r)); goto out_close; }
    {
    uint8_t pb[PROBE_LEN]={0};
    uint32_t interval = (uint32_t)(10000000.0/fps + 0.5);
    if(fi.n_intervals){ // device requires an exact match against its descriptor table
        uint32_t best=fi.intervals[0]; double bd=1e18;
        for(int i=0;i<fi.n_intervals;i++){ double d=fabs((double)fi.intervals[i]-interval); if(d<bd){bd=d;best=fi.intervals[i];} }
        if(best!=interval) fprintf(stderr,"fps %.2f -> using descriptor interval %u (%.3f fps)\n",fps,best,10000000.0/best);
        interval=best;
    }
    struct libusb_transfer *xf[NUM_XFERS]={0};
    int xfer_len=0, attempt, started=0;
    for(attempt=1; attempt<=4 && running; attempt++){
        if(attempt>1){ fprintf(stderr,"no video data, retry %d: resetting endpoint and re-committing\n",attempt); usleep(300000*attempt); }
        r=libusb_clear_halt(h,EP_IN); if(r) fprintf(stderr,"clear halt: %s\n",libusb_error_name(r));
        libusb_set_interface_alt_setting(h,VS_IFACE,0);
        // Probe / commit
        memset(pb,0,sizeof pb); put16(pb,0x0001); pb[2]=fmt; pb[3]=frm; put32(pb+4,nofps?0:interval);
        r=vs_ctrl(h,1,1,pb,PROBE_LEN); if(r<0){ fprintf(stderr,"probe set failed: %s\n",libusb_error_name(r)); continue; }
        memset(pb,0,sizeof pb);
        r=vs_ctrl(h,0,1,pb,PROBE_LEN); if(r<0){ fprintf(stderr,"probe get failed: %s\n",libusb_error_name(r)); continue; }
        if(pb[2]!=fmt||pb[3]!=frm){
            fprintf(stderr,"device rejected fmt/frame at interval %u (got %d/%d); retrying with default interval %u\n",interval,pb[2],pb[3],fi.dflt_interval);
            memset(pb,0,sizeof pb); put16(pb,0x0001); pb[2]=fmt; pb[3]=frm; put32(pb+4,fi.dflt_interval);
            r=vs_ctrl(h,1,1,pb,PROBE_LEN); memset(pb,0,sizeof pb); r=vs_ctrl(h,0,1,pb,PROBE_LEN);
            if(r<0||pb[2]!=fmt||pb[3]!=frm){ fprintf(stderr,"device rejected fmt/frame (got %d/%d)\n",pb[2],pb[3]); goto out_release; }
        }
        print_probe("probe result",pb);
        r=vs_ctrl(h,1,2,pb,PROBE_LEN); if(r<0){ fprintf(stderr,"commit failed: %s\n",libusb_error_name(r)); continue; }
        memset(pb,0,sizeof pb); r=vs_ctrl(h,0,2,pb,PROBE_LEN); if(r>0) print_probe("commit readback",pb);
        frame_size=le32(pb+18); max_payload=le32(pb+22);
        uint32_t expect = (uint32_t)fi.w*fi.h*3;
        if(!strcmp(fi.fourcc,"P010") && frame_size!=expect) fprintf(stderr,"note: maxFrameSize %u != w*h*3 %u\n",frame_size,expect);
        if(!strcmp(fi.fourcc,"P010")) frame_size=expect;
        if(frame_size==0||max_payload==0){ fprintf(stderr,"bad probe values\n"); continue; }
        if(use_shm && shm_base && frame_size<=SHM_SLOT_BYTES){ frame_buf=shm_slot(0); } else { use_shm=0; static uint8_t *own=NULL; own=realloc(own,frame_size); frame_buf=own; }
        frame_fill=0; cur_fid=-1; seq=0; frames_ok=0; frames_bad=0; video_bytes_seen=0;
        t_first=0; t_prev_eof=0; t_report=0; xfer_sum=0; xfer_max=0; gap_sum=0; xfer_n=0;

        xfer_len = (int)max_payload*64;
        for(int i=0;i<NUM_XFERS;i++){
            if(!xf[i]) xf[i]=libusb_alloc_transfer(0);
            if(!xf[i]->buffer) xf[i]->buffer=malloc(xfer_len);
            libusb_fill_bulk_transfer(xf[i],h,EP_IN,xf[i]->buffer,xfer_len,xfer_cb,NULL,0);
            if((r=libusb_submit_transfer(xf[i]))){ fprintf(stderr,"submit %d: %s\n",i,libusb_error_name(r)); }
        }
        t_start=now_ns();
        // Wait up to 1.5 s for the first video payload.
        while(running && video_bytes_seen==0 && now_ns()-t_start<1500000000ull){ struct timeval tv={0,50000}; libusb_handle_events_timeout_completed(ctx,&tv,NULL); }
        if(video_bytes_seen>0){ started=1; break; }
        for(int i=0;i<NUM_XFERS;i++) libusb_cancel_transfer(xf[i]);
        for(int k=0;k<10;k++){ struct timeval tv={0,50000}; libusb_handle_events_timeout_completed(ctx,&tv,NULL); }
    }
    if(!started){ fprintf(stderr,"device never started streaming after %d attempts\n",attempt-1); for(int i=0;i<NUM_XFERS;i++) if(xf[i]){ free(xf[i]->buffer); libusb_free_transfer(xf[i]); } goto out_release; }
    fprintf(stderr,"streaming %dx%d %s, frame=%u bytes payload=%u, %d x %d-byte transfers in flight (attempt %d)\n",fi.w,fi.h,fi.fourcc,frame_size,max_payload,NUM_XFERS,xfer_len,attempt);
    if(want_audio) audio_start(h,au_xf);
    while(running){ struct timeval tv={0,100000}; libusb_handle_events_timeout_completed(ctx,&tv,NULL); }
    fprintf(stderr,"stopping (ok=%u bad=%u)\n",frames_ok,frames_bad);
    audio_stop(h,au_xf,ctx);
    for(int i=0;i<NUM_XFERS;i++) libusb_cancel_transfer(xf[i]);
    for(int k=0;k<20;k++){ struct timeval tv={0,50000}; libusb_handle_events_timeout_completed(ctx,&tv,NULL); }
    for(int i=0;i<NUM_XFERS;i++){ free(xf[i]->buffer); libusb_free_transfer(xf[i]); }
    // Bulk UVC devices are told to stop streaming with CLEAR_FEATURE(HALT) on the streaming endpoint (what Windows does).
    r=libusb_clear_halt(h,EP_IN); fprintf(stderr,"clear halt EP 0x82 (stop streaming): %s\n",r?libusb_error_name(r):"ok");
    libusb_set_interface_alt_setting(h,VS_IFACE,0);
    double dt=(now_ns()-t_start)/1e9; fprintf(stderr,"done: %u good frames in %.2fs (%.2f fps)\n",frames_ok,dt,dt>0?frames_ok/dt:0);
    rc=0;
    }
out_release:
    libusb_release_interface(h,VS_IFACE); libusb_release_interface(h,VC_IFACE);
    libusb_attach_kernel_driver(h,VS_IFACE); libusb_attach_kernel_driver(h,VC_IFACE);
out_close:
    libusb_close(h); libusb_exit(ctx);
    return rc;
}

// Daemon mode: accept one client at a time on a Unix socket. Client sends "START fmt frm fps\n"; frames stream back
// until the client disconnects. Exits after idle timeout with no client.
static int serve(const char *path, int idle_secs){
    unlink(path);
    int s=socket(AF_UNIX,SOCK_STREAM,0); if(s<0){perror("socket");return 1;}
    struct sockaddr_un sa={0}; sa.sun_family=AF_UNIX; strncpy(sa.sun_path,path,sizeof(sa.sun_path)-1);
    if(bind(s,(struct sockaddr*)&sa,sizeof sa)){perror("bind");return 1;}
    chmod(path,0666);
    listen(s,1);
    shm_setup();
    fprintf(stderr,"serving on %s (pid %d)\n",path,getpid());
    while(!quit_all){
        struct pollfd pfd={s,POLLIN,0};
        int pr=poll(&pfd,1,idle_secs*1000);
        if(pr==0){ fprintf(stderr,"idle timeout, exiting\n"); break; }
        if(pr<0){ if(errno==EINTR) continue; break; }
        int c=accept(s,NULL,NULL); if(c<0) continue;
        char line[128]={0}; int n=0;
        while(n<(int)sizeof(line)-1){ ssize_t r=read(c,line+n,1); if(r<=0||line[n]=='\n') break; n++; }
        int fmt=7,frm=5; double fps=30; char flag[16]={0};
        if(sscanf(line,"START %d %d %lf %15s",&fmt,&frm,&fps,flag)<2){ fprintf(stderr,"bad command: %s\n",line); close(c); continue; }
        use_shm = (!strcmp(flag,"SHM") && shm_base!=NULL);
        fprintf(stderr,"client: fmt=%d frm=%d fps=%g shm=%d\n",fmt,frm,fps,use_shm);
        { int sz=8*1024*1024; setsockopt(c,SOL_SOCKET,SO_SNDBUF,&sz,sizeof sz); }
        out_fd=c; running=1; want_count=0; dump_prefix=NULL;
        run_session(fmt,frm,fps,0,1);
        close(c); out_fd=1;
    }
    close(s); unlink(path); return 0;
}

int main(int argc,char **argv){
    int fmt=7, frm=5; double fps=30.0; const char *out_path="-"; int nofps=0; const char *serve_path=NULL; int idle=15; int audio_flag=0;
    for(int i=1;i<argc;i++){
        if(!strcmp(argv[i],"--format")) fmt=atoi(argv[++i]);
        else if(!strcmp(argv[i],"--frame")) frm=atoi(argv[++i]);
        else if(!strcmp(argv[i],"--fps")) fps=atof(argv[++i]);
        else if(!strcmp(argv[i],"--count")) want_count=atoi(argv[++i]);
        else if(!strcmp(argv[i],"--out")) out_path=argv[++i];
        else if(!strcmp(argv[i],"--dump-prefix")) dump_prefix=argv[++i];
        else if(!strcmp(argv[i],"--nofps")) nofps=1;
        else if(!strcmp(argv[i],"--audio")) audio_flag=1;
        else if(!strcmp(argv[i],"--serve")) serve_path=argv[++i];
        else if(!strcmp(argv[i],"--idle")) idle=atoi(argv[++i]);
        else { fprintf(stderr,"unknown arg %s\n",argv[i]); return 2; }
    }
    signal(SIGINT,on_sig); signal(SIGTERM,on_sig); signal(SIGPIPE,SIG_IGN);
    if(serve_path) return serve(serve_path,idle);
    if(strcmp(out_path,"-")){ out_fd=open(out_path,O_WRONLY); if(out_fd<0){perror("open out");return 1;} }
    return run_session(fmt,frm,fps,nofps,audio_flag);
}
