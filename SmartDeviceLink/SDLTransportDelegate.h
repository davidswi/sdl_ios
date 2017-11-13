//  SDLTransportDelegate.h
//

@protocol SDLTransportDelegate <NSObject>

- (void)onTransportConnected;
- (void)onTransportDisconnected;
- (void)onTransportFailed;
- (void)onDataReceived:(NSData *)receivedData;

@end
