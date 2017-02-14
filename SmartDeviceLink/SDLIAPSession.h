//
//  SDLIAPSession.h
//

#import "SDLIAPSessionDelegate.h"
#import <ExternalAccessory/ExternalAccessory.h>
#import <Foundation/Foundation.h>

@class SDLStreamDelegate;

typedef void (^SessionCompletionHandler)(BOOL success);
typedef BOOL (^SessionSendHandler)(NSError **error);

@interface SDLIAPSession : NSObject

@property (strong, atomic) EAAccessory *accessory;
@property (strong, atomic) NSString *protocol;
@property (strong, atomic) EASession *easession;
@property (weak) id<SDLIAPSessionDelegate> delegate;
@property (strong, atomic) SDLStreamDelegate *streamDelegate;

- (instancetype)initWithAccessory:(EAAccessory *)accessory
                      forProtocol:(NSString *)protocol;

- (BOOL)start:(dispatch_queue_t)sendQ;
- (void)stop;

- (void)sendData:(SessionSendHandler)handler;

@end
