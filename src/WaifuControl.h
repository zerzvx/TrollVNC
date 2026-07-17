/*
 WaifuControl — API de control HTTP/JSON nativa del tweak (Waifu VNC / Waifu Suite).
 Expone STHIDEventGenerator + gestión de apps + system + shell en un puerto TCP,
 para que el panel controle el device SIN depender de CatMCP.
 */
#ifndef WaifuControl_h
#define WaifuControl_h

#import <Foundation/Foundation.h>

#define WAIFU_CONTROL_PORT 46900

@interface WaifuControl : NSObject
+ (void)startOnPort:(uint16_t)port;
@end

#endif /* WaifuControl_h */
