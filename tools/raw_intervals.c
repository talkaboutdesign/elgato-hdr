#include <libusb.h>
#include <stdio.h>
#include <stdint.h>
static uint16_t le16(const uint8_t *p){return p[0]|(p[1]<<8);}
static uint32_t le32(const uint8_t *p){return p[0]|(p[1]<<8)|(p[2]<<16)|(p[3]<<24);}
int main(){ libusb_context*c;libusb_init(&c); libusb_device**l; ssize_t n=libusb_get_device_list(c,&l); int found=0;
 for(ssize_t i=0;i<n;i++){ struct libusb_device_descriptor d; libusb_get_device_descriptor(l[i],&d); if(d.idVendor!=0x0fd9||d.idProduct!=0x009b)continue; found=1;
  struct libusb_config_descriptor*cfg; libusb_get_active_config_descriptor(l[i],&cfg);
  const struct libusb_interface_descriptor*id=&cfg->interface[1].altsetting[0]; const uint8_t*p=id->extra; int len=id->extra_length; int fmt=0;
  while(len>=3){int bl=p[0],bt=p[1],st=p[2]; if(bl<3||bl>len)break;
   if(bt==0x24&&(st==4||st==6||st==0x10)) fmt=p[3];
   if(bt==0x24&&st==5&&fmt==7){ printf("P010 frame %d %dx%d default=%u intervals:",p[3],le16(p+5),le16(p+7),le32(p+21)); for(int k=0;k<p[25];k++) printf(" %u",le32(p+26+4*k)); printf("\n"); }
   p+=bl;len-=bl;}
  libusb_free_config_descriptor(cfg);}
 if(!found) printf("device not visible (still captured?)\n"); libusb_free_device_list(l,1); libusb_exit(c); return 0;}
