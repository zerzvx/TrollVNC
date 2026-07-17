/*
 WaifuStream.h — servidor de streaming JPEG-sobre-WebSocket (estilo DUFF).

 El daemon VNC ya captura la pantalla (ScreenCapturer → CMSampleBuffer en su
 gFrameHandler). Aquí NO abrimos una segunda captura: el daemon "teea" cada
 frame llamando a WFStreamPushSampleBuffer(). Cuando no hay clientes conectados
 la función es un no-op barato. Cuando los hay, convierte el frame a JPEG (GPU
 vía CIContext), lo escala/comprime y lo empuja por un WebSocket a todos los
 navegadores. Push unidireccional continuo = sin round-trips (a diferencia de
 RFB/VNC, limitado a 1 update por RTT).

 El input (tap/swipe/teclado) sigue yendo por WaifuControl:46900 (RPC), así que
 este socket es solo salida de vídeo.
*/
#ifndef WaifuStream_h
#define WaifuStream_h

#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

#ifndef WAIFU_STREAM_PORT
#define WAIFU_STREAM_PORT 46980
#endif

#ifdef __cplusplus
extern "C" {
#endif

/** Teea un frame capturado a los clientes JPEG-over-WebSocket conectados.
    No-op (barato) cuando no hay clientes. Seguro desde el hilo de captura. */
void WFStreamPushSampleBuffer(CMSampleBufferRef sampleBuffer);

#ifdef __cplusplus
}
#endif

@interface WaifuStream : NSObject
+ (void)startOnPort:(uint16_t)port;
@end

#endif /* WaifuStream_h */
