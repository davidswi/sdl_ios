//  SDLAbstractTransport.h

#import <Foundation/Foundation.h>

#import "SDLTransportDelegate.h"

NS_ASSUME_NONNULL_BEGIN
typedef enum{
	SDLTransportStateDisconnected,
	SDLTransportStateConnecting,
	SDLTransportStateConnected,
	SDLTransportStateConnectFailed,
	SDLTransportStateConnectDenied
} SDLTransportState;
@interface SDLAbstractTransport : NSObject

@property (nullable, weak, nonatomic) id<SDLTransportDelegate> delegate;
@property (strong, nonatomic) NSString *debugConsoleGroupName;
@property (nonatomic, assign) SDLTransportState state;
- (void)connect;
- (void)disconnect;
- (void)sendData:(NSData *)dataToSend;
- (double)retryDelay;

@end

NS_ASSUME_NONNULL_END
