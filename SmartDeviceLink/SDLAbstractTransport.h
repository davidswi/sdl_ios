//  SDLAbstractTransport.h

#import <Foundation/Foundation.h>

#import "SDLTransportDelegate.h"

typedef enum{
	SDLTransportStateDisconnected,
	SDLTransportStateConnecting,
	SDLTransportStateConnected,
	SDLTransportStateConnectFailed,
	SDLTransportStateConnectDenied
} SDLTransportState;


@interface SDLAbstractTransport : NSObject

@property (weak) id<SDLTransportDelegate> delegate;
@property (strong) NSString *debugConsoleGroupName;
@property (nonatomic, assign) SDLTransportState state;

- (void)connect;
- (void)disconnect;
- (void)sendData:(NSData *)dataToSend;
- (void)dispose;
- (double)retryDelay;

@end
