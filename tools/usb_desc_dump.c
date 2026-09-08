// Dump UVC VideoControl / VideoStreaming class-specific descriptors for Elgato 4K X.
// No root needed: libusb reads cached config descriptors.
#include <libusb.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>

#define VID 0x0fd9
#define PID 0x009b

static uint16_t le16(const uint8_t *p){return p[0]|(p[1]<<8);}
static uint32_t le32(const uint8_t *p){return p[0]|(p[1]<<8)|(p[2]<<16)|(p[3]<<24);}
static void guid_str(const uint8_t *g, char *out){ // FourCC lives in first 4 bytes for UVC uncompressed GUIDs
    int printable=1; for(int i=0;i<4;i++) if(g[i]<32||g[i]>126) printable=0;
    if(printable) snprintf(out,64,"%c%c%c%c",g[0],g[1],g[2],g[3]);
    else { char *o=out; for(int i=0;i<16;i++) o+=sprintf(o,"%02x",g[i]); }
}
static void dump_vs(const uint8_t *p, int len){
    while(len>=3){
        int bl=p[0], bt=p[1], st=p[2];
        if(bl<3||bl>len) break;
        if(bt==0x24){
            switch(st){
            case 0x01: printf("  VS_INPUT_HEADER: numFormats=%d totalLen=%d endpoint=0x%02x info=0x%02x\n",p[3],le16(p+4),p[6],p[7]); break;
            case 0x04: { char g[64]; guid_str(p+5,g); printf("  FORMAT_UNCOMPRESSED idx=%d numFrames=%d guid=%s bpp=%d defaultFrame=%d\n",p[3],p[4],g,p[21],p[22]); } break;
            case 0x10: { char g[64]; guid_str(p+5,g); printf("  FORMAT_FRAME_BASED idx=%d numFrames=%d guid=%s bpp=%d defaultFrame=%d\n",p[3],p[4],g,p[21],p[22]); } break;
            case 0x06: printf("  FORMAT_MJPEG idx=%d numFrames=%d defaultFrame=%d\n",p[3],p[4],p[6]); break;
            case 0x05: case 0x07: case 0x11: {
                int w=le16(p+5),h=le16(p+7);
                uint32_t dflt=le32(p+ (st==0x11?17:21));
                int n = p[st==0x11?21:25];
                const uint8_t *iv = p + (st==0x11?26:26);
                printf("    FRAME idx=%d %dx%d cap=0x%02x maxBuf=%u default=%.2ffps intervals:",p[3],w,h,p[4],le32(p+ (st==0x11?13:17)),10000000.0/dflt);
                if(n==0) printf(" continuous");
                for(int i=0;i<n && (iv+4*i+4)<=p+bl;i++) printf(" %.2f",10000000.0/le32(iv+4*i));
                printf("\n"); } break;
            case 0x0d: printf("  COLORFORMAT primaries=%d transfer=%d matrix=%d\n",p[3],p[4],p[5]); break;
            default: printf("  VS subtype 0x%02x len=%d\n",st,bl);
            }
        }
        p+=bl; len-=bl;
    }
}
int main(){
    libusb_context *ctx; libusb_init(&ctx);
    libusb_device **list; ssize_t n=libusb_get_device_list(ctx,&list);
    for(ssize_t i=0;i<n;i++){
        struct libusb_device_descriptor dd; libusb_get_device_descriptor(list[i],&dd);
        if(dd.idVendor!=VID||dd.idProduct!=PID) continue;
        printf("Elgato 4K X bus=%d addr=%d speed=%d bcdUSB=%04x numConfigs=%d\n",libusb_get_bus_number(list[i]),libusb_get_device_address(list[i]),libusb_get_device_speed(list[i]),dd.bcdUSB,dd.bNumConfigurations);
        struct libusb_config_descriptor *cfg;
        if(libusb_get_active_config_descriptor(list[i],&cfg)){printf("no config\n");continue;}
        printf("Config %d: %d interfaces, extra=%d\n",cfg->bConfigurationValue,cfg->bNumInterfaces,cfg->extra_length);
        for(int k=0;k<cfg->bNumInterfaces;k++){
            for(int a=0;a<cfg->interface[k].num_altsetting;a++){
                const struct libusb_interface_descriptor *id=&cfg->interface[k].altsetting[a];
                printf("Interface %d alt %d class=%02x sub=%02x proto=%02x eps=%d extra=%d\n",id->bInterfaceNumber,id->bAlternateSetting,id->bInterfaceClass,id->bInterfaceSubClass,id->bInterfaceProtocol,id->bNumEndpoints,id->extra_length);
                for(int e=0;e<id->bNumEndpoints;e++){
                    const struct libusb_endpoint_descriptor *ep=&id->endpoint[e];
                    const char *t[]={"control","iso","bulk","interrupt"};
                    printf("  EP 0x%02x %s maxPacket=%d interval=%d\n",ep->bEndpointAddress,t[ep->bmAttributes&3],ep->wMaxPacketSize,ep->bInterval);
                    if(ep->extra_length>=6 && ep->extra[1]==0x30) printf("    SS companion: maxBurst=%d attrs=0x%02x bytesPerInterval=%d\n",ep->extra[2],ep->extra[3],le16(ep->extra+4));
                }
                if(id->bInterfaceClass==0x0e && id->bInterfaceSubClass==1 && id->extra_length>=12){
                    printf("  VC_HEADER bcdUVC=%04x\n",le16(id->extra+3));
                }
                if(id->bInterfaceClass==0x0e && id->bInterfaceSubClass==2) dump_vs(id->extra,id->extra_length);
            }
        }
        libusb_free_config_descriptor(cfg);
    }
    libusb_free_device_list(list,1); libusb_exit(ctx); return 0;
}
