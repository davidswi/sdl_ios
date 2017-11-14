//  SDLAbstractProtocol.m

#import "SDLAbstractProtocol.h"
#import "SDLAbstractTransport.h"
#import "SDLRPCMessage.h"
#import "SDLError.h"

NS_ASSUME_NONNULL_BEGIN

@implementation SDLAbstractProtocol

- (instancetype)init {
    if (self = [super init]) {
        _protocolDelegateTable = [NSHashTable weakObjectsHashTable];
        _debugConsoleGroupName = @"default";
    }
    return self;
}

// Implement in subclasses.
- (void)startServiceWithType:(SDLServiceType)serviceType payload:(nullable NSData *)payload {
    [self doesNotRecognizeSelector:_cmd];
}

- (void)startSecureServiceWithType:(SDLServiceType)serviceType payload:(nullable NSData *)payload completionHandler:(void (^)(BOOL, NSError *))completionHandler {
    [self doesNotRecognizeSelector:_cmd];
}

- (void)endServiceWithType:(SDLServiceType)serviceType {
    [self doesNotRecognizeSelector:_cmd];
}

- (void)sendRPC:(SDLRPCMessage *)message {
    [self doesNotRecognizeSelector:_cmd];
}

- (BOOL)sendRPC:(SDLRPCMessage *)message encrypted:(BOOL)encryption error:(NSError *__autoreleasing *)error {
    [self doesNotRecognizeSelector:_cmd];
    return NO;
}

- (void)handleBytesFromTransport:(NSData *)receivedData {
    [self doesNotRecognizeSelector:_cmd];
}

- (void)sendRawData:(NSData *)data withServiceType:(SDLServiceType)serviceType {
    [self doesNotRecognizeSelector:_cmd];
}

- (void)sendEncryptedRawData:(NSData *)data onService:(SDLServiceType)serviceType {
    [self doesNotRecognizeSelector:_cmd];
}


#pragma - SDLTransportListener Implementation
- (void)onTransportConnected {
    for (id<SDLProtocolListener> listener in self.protocolDelegateTable.allObjects) {
        if ([listener respondsToSelector:@selector(onProtocolOpened)]) {
            [listener onProtocolOpened];
        }
    }
}

- (void)onTransportDisconnected {
    for (id<SDLProtocolListener> listener in self.protocolDelegateTable.allObjects) {
        if ([listener respondsToSelector:@selector(onProtocolClosed)]) {
            [listener onProtocolClosed];
        }
    }
}

- (void)onTransportFailed {
	NSException *exception = nil;
	
	for (id<SDLProtocolListener> listener in self.protocolDelegateTable.allObjects) {
		switch (self.transport.state){
			case SDLTransportStateNoSDLService:
				exception = [NSException sdl_noSDLServiceException];
				break;
				
			case SDLTransportStateConnectFailed:
				exception = [NSException sdl_connectionFailedException];
				break;
				
			case SDLTransportStateConnectDenied:
				exception = [NSException sdl_connectionDeniedException];
				break;
				
			default:
				break;
		}
		
		if ([listener respondsToSelector:@selector(onError:exception:)]) {
			[listener onError:@"Transport error -- transport failed" exception:exception];
		}
	}
}

- (void)onDataReceived:(NSData *)receivedData {
    [self handleBytesFromTransport:receivedData];
}

@end

NS_ASSUME_NONNULL_END
