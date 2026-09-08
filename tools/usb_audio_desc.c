#include <libusb.h>
#include <stdio.h>
#include <stdint.h>
static uint16_t le16(const uint8_t *p){return p[0]|(p[1]<<8);}
static void dump_cs(const uint8_t *p,int len,int sub){
    while(len>=3){int bl=p[0],bt=p[1],st=p[2]; if(bl<3||bl>len)break;
        if(bt==0x24){
            if(sub==1){ // AudioControl
                if(st==1) printf("    AC_HEADER bcdADC=%04x\n",le16(p+3));
                else if(st==2) printf("    INPUT_TERMINAL id=%d type=0x%04x ch=%d\n",p[3],le16(p+4),p[7]);
                else if(st==3) printf("    OUTPUT_TERMINAL id=%d type=0x%04x src=%d\n",p[3],le16(p+4),p[7]);
                else if(st==6){ printf("    FEATURE_UNIT id=%d src=%d ctrlSize=%d controls:",p[3],p[4],p[5]); for(int i=6;i<bl-1;i++) printf(" %02x",p[i]); printf("\n"); }
                else printf("    AC subtype %d len %d\n",st,bl);
            } else {
                if(st==1) printf("    AS_GENERAL terminalLink=%d delay=%d formatTag=0x%04x\n",p[3],p[4],le16(p+5));
                else if(st==2){ printf("    FORMAT_TYPE type=%d ch=%d subframe=%d bits=%d freqType=%d rates:",p[3],p[4],p[5],p[6],p[7]);
                    if(p[7]==0) printf(" %u-%u",p[8]|(p[9]<<8)|(p[10]<<16),p[11]|(p[12]<<8)|(p[13]<<16));
                    for(int i=0;i<p[7];i++) printf(" %u",p[8+3*i]|(p[9+3*i]<<8)|(p[10+3*i]<<16)); printf("\n"); }
                else printf("    AS subtype %d len %d\n",st,bl);
            }
        } else if(bt==0x25) printf("    CS_ENDPOINT attrs=0x%02x lockDelayUnits=%d lockDelay=%d\n",p[3],p[4],le16(p+5));
        else printf("    desc type 0x%02x len %d\n",bt,bl);
        p+=bl;len-=bl;}
}
int main(){ libusb_context*c;libusb_init(&c); libusb_device**l; ssize_t n=libusb_get_device_list(c,&l);
 for(ssize_t i=0;i<n;i++){ struct libusb_device_descriptor d; libusb_get_device_descriptor(l[i],&d); if(d.idVendor!=0x0fd9||d.idProduct!=0x009b)continue;
  struct libusb_config_descriptor*cfg; libusb_get_active_config_descriptor(l[i],&cfg);
  for(int k=0;k<cfg->bNumInterfaces;k++) for(int a=0;a<cfg->interface[k].num_altsetting;a++){ const struct libusb_interface_descriptor*id=&cfg->interface[k].altsetting[a];
   if(id->bInterfaceClass!=1)continue; printf("Interface %d alt %d sub=%d eps=%d\n",id->bInterfaceNumber,id->bAlternateSetting,id->bInterfaceSubClass,id->bNumEndpoints);
   dump_cs(id->extra,id->extra_length,id->bInterfaceSubClass);
   for(int e=0;e<id->bNumEndpoints;e++){ const struct libusb_endpoint_descriptor*ep=&id->endpoint[e]; printf("  EP 0x%02x attrs=0x%02x maxPacket=%d interval=%d extra=%d\n",ep->bEndpointAddress,ep->bmAttributes,ep->wMaxPacketSize,ep->bInterval,ep->extra_length); dump_cs(ep->extra,ep->extra_length,2);} }
  libusb_free_config_descriptor(cfg);} libusb_free_device_list(l,1); libusb_exit(c); return 0;}
