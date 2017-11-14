//  SDLIAPTransport.h
//


#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "EAAccessory+SDLProtocols.h"
#import "EAAccessoryManager+SDLProtocols.h"
#import "SDLGlobals.h"
#import "SDLIAPSession.h"
#import "SDLIAPTransport.h"
#import "SDLIAPTransport.h"
#import "SDLLogMacros.h"
#import "SDLStreamDelegate.h"
#import "SDLTimer.h"
#import <CommonCrypto/CommonDigest.h>

NS_ASSUME_NONNULL_BEGIN

NSString *const LegacyProtocolString = @"com.ford.sync.prot0";
NSString *const ControlProtocolString = @"com.smartdevicelink.prot0";
NSString *const IndexedProtocolStringPrefix = @"com.smartdevicelink.prot";
NSString *const MultiSessionProtocolString = @"com.smartdevicelink.multisession";
NSString *const BackgroundTaskName = @"com.sdl.transport.iap.backgroundTask";

int const createSessionRetries = 3;
int const protocolIndexTimeoutSeconds = 10;
int const streamOpenTimeoutSeconds = 2;
int const controlSessionRetryOffsetSeconds = 2;


@interface SDLIAPTransport () {
    BOOL _alreadyDestructed;
}

@property (assign) int retryCounter;
@property (assign) BOOL sessionSetupInProgress;
@property (assign) BOOL listeningForEvents;
@property (strong) SDLTimer *protocolIndexTimer;
@property (nonatomic, assign) UIBackgroundTaskIdentifier backgroundTaskId;

@end


@implementation SDLIAPTransport

- (instancetype)init {
    SDLLogV(@"SDLIAPTransport Init");
    if (self = [super init]) {
        _alreadyDestructed = NO;
        _sessionSetupInProgress = NO;
        _session = nil;
        _controlSession = nil;
        _retryCounter = 0;
        _sessionSetupInProgress = NO;
        _listeningForEvents = NO;
        _protocolIndexTimer = nil;

		self.state = SDLTransportStateDisconnected;
    }
    
    return self;
}

#pragma mark - Background Task

/**
 *  Starts a background task that allows the app to search for accessories and while the app is in the background.
 */
- (void)sdl_backgroundTaskStart {
    if (self.backgroundTaskId != UIBackgroundTaskInvalid) {
        return;
    }
    
    SDLLogD(@"Starting background task");
    self.backgroundTaskId = [[UIApplication sharedApplication] beginBackgroundTaskWithName:BackgroundTaskName expirationHandler:^{
        SDLLogD(@"Background task expired");
        [self sdl_backgroundTaskEnd];
    }];
}

/**
 *  Cleans up a background task when it is stopped.
 */
- (void)sdl_backgroundTaskEnd {
    if (self.backgroundTaskId == UIBackgroundTaskInvalid) {
        return;
    }
    
    SDLLogD(@"Ending background task");
    [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTaskId];
    self.backgroundTaskId = UIBackgroundTaskInvalid;
}

#pragma mark - Notifications

#pragma mark Subscription

/**
 *  Registers for system notifications about connected accessories and the app life cycle.
 */
- (void)sdl_startEventListening {
    SDLLogV(@"SDLIAPTransport started listening for events");
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sdl_accessoryConnected:)
                                                 name:EAAccessoryDidConnectNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sdl_accessoryDisconnected:)
                                                 name:EAAccessoryDidDisconnectNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sdl_applicationWillEnterForeground:)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sdl_applicationDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    
    [[EAAccessoryManager sharedAccessoryManager] registerForLocalNotifications];
    self.listeningForEvents = YES;
}

/**
 *  Unsubscribes to notifications.
 */
- (void)sdl_stopEventListening {
    SDLLogV(@"SDLIAPTransport stopped listening for events");
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    self.listeningForEvents = NO;
}


#pragma mark EAAccessory Notifications

/**
 *  Handles a notification sent by the system when a new accessory has been detected by attempting to connect to the new accessory.
 *
 *  @param notification Contains information about the connected accessory
 */
- (void)sdl_accessoryConnected:(NSNotification *)notification {
    EAAccessory *accessory = notification.userInfo[EAAccessoryKey];
    
    double retryDelay = self.retryDelay;
    SDLLogD(@"Accessory Connected (%@), Opening in %0.03fs", notification.userInfo[EAAccessoryKey], retryDelay);
    
    if ([[UIApplication sharedApplication] applicationState] != UIApplicationStateActive) {
        SDLLogD(@"Accessory connected while app is in background. Starting background task.");
        [self sdl_backgroundTaskStart];
    }
    
    self.retryCounter = 0;
    [self performSelector:@selector(sdl_connect:) withObject:accessory afterDelay:retryDelay];
}

/**
 *  Handles a notification sent by the system when an accessory has been disconnected by cleaning up after the disconnected device. Only check for the data session, the control session is handled separately
 *
 *  @param accessory Contains information about the connected accessory
 */
- (BOOL)accessoryIsOurs:(EAAccessory *)accessory{
	SDLIAPSession *activeSession = nil;
	if (self.controlSession){
		activeSession = self.controlSession;
	}
	else{
		activeSession = self.session;
	}
	
	if (activeSession){
		if (accessory.connectionID == activeSession.accessory.connectionID ||
			[accessory.serialNumber isEqualToString:activeSession.accessory.serialNumber]){
			return YES;
		}
	}
	else{
		if ([accessory supportsProtocol:@"com.smartdevicelink.prot0"]){
			return YES;
		}
	}
	
	return NO;
}

- (void)sdl_accessoryDisconnected:(NSNotification *)notification {
    EAAccessory *accessory = [notification.userInfo objectForKey:EAAccessoryKey];
	if ([self accessoryIsOurs:accessory]){
		self.retryCounter = 0;
		self.sessionSetupInProgress = NO;
		// [self disconnect];
		[self.delegate onTransportDisconnected];
	}
	else{
		SDLLogW(@"Accessory is not ours, ignoring!!!");
	}
}

#pragma mark App Lifecycle Notifications

/**
 *  Handles a notification sent by the system when the app enters the foreground.
 *
 *  If the app is still searching for an accessory, a background task will be started so the app can still search for and/or connect with an accessory while it is in the background.
 *
 *  @param notification Notification
 */
- (void)sdl_applicationWillEnterForeground:(NSNotification *)notification {
    SDLLogV(@"App foregrounded, attempting connection");
    [self sdl_backgroundTaskEnd];
    [self connect];
}

/**
 *  Handles a notification sent by the system when the app enters the background.
 *
 *  @param notification Notification
 */
- (void)sdl_applicationDidEnterBackground:(NSNotification *)notification {
    SDLLogV(@"App backgrounded, starting background task");
	if (self.sessionSetupInProgress){
 		[self sdl_backgroundTaskStart];
	}
}

#pragma mark - Stream Lifecycle

- (void)connect {
    if (!self.listeningForEvents) {
        [self sdl_startEventListening];
    }
	
	UIApplicationState state = [UIApplication sharedApplication].applicationState;
	if (state != UIApplicationStateActive){
		SDLLogW(@"App inactive on connect, starting background task");
		[self sdl_backgroundTaskStart];
	}
    
	[self sdl_connect:nil];
}

/**
 *  Starts the process to connect to an accessory. If no accessory specified, scans for a valid accessory.
 *
 *  @param accessory The accessory to attempt connection with or nil to scan for accessories.
 */
- (void)sdl_connect:(nullable EAAccessory *)accessory {
	self.state = SDLTransportStateConnecting;
	BOOL isDataSessionEstablished = (self.session && !self.session.stopped);
	
    if (!isDataSessionEstablished && !self.sessionSetupInProgress) {
        // reset counter when this is triggered from -sdl_accessoryConnected:
        if (accessory) {
            self.retryCounter = 0;
        }
        self.sessionSetupInProgress = YES;
        [self sdl_establishSessionWithAccessory:accessory];
    } else if (self.session) {
        // Session already established
        SDLLogV(@"Session already established");
    } else {
        // Session attempting to be established
        SDLLogV(@"Session setup already in progress");
    }
}

/**
 *  Cleans up after a disconnected accessory by closing any open input streams.
 */
- (void)disconnect {
    SDLLogD(@"Disconnecting IAP data session");
    // Stop event listening here so that even if the transport is disconnected by the proxy we unregister for accessory local notifications
    [self sdl_stopEventListening];
    if (self.controlSession != nil) {
        [self.controlSession stop];
        self.controlSession.streamDelegate = nil;
        self.controlSession = nil;
    } else if (self.session != nil) {
        [self.session stop];
        self.session.streamDelegate = nil;
        self.session = nil;
    }
	self.state = SDLTransportStateDisconnected;
}


#pragma mark - Creating Session Streams

/**
 *  Attempt to connect an accessory using the control or legacy protocols, then return whether or not we've generated an IAP session.
 *
 *  @param accessory The accessory to attempt a connection with
 *  @return Whether or not we succesfully created a session.
 */
- (BOOL)sdl_connectAccessory:(EAAccessory *)accessory {
    BOOL connecting = NO;
    if ([self.class sdl_supportsRequiredProtocolStrings] != nil) {
        NSString *failedString = [self.class sdl_supportsRequiredProtocolStrings];
        SDLLogE(@"A required External Accessory protocol string is missing from the info.plist: %@", failedString);
        NSAssert(NO, @"Some SDL protocol strings are not supported, check the README for all strings that must be included in your info.plist file. Missing string: %@", failedString);
        return connecting;
    }

    if ([accessory supportsProtocol:MultiSessionProtocolString] && SDL_SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"9")) {
        [self sdl_createIAPDataSessionWithAccessory:accessory forProtocol:MultiSessionProtocolString];
        connecting = YES;
    } else if ([accessory supportsProtocol:ControlProtocolString]) {
        [self sdl_createIAPControlSessionWithAccessory:accessory];
        connecting = YES;
    } else if ([accessory supportsProtocol:LegacyProtocolString]) {
        [self sdl_createIAPDataSessionWithAccessory:accessory forProtocol:LegacyProtocolString];
        connecting = YES;
    }
    return connecting;
}

/**
 Check all required protocol strings in the info.plist dictionary.

 @return A missing protocol string or nil if all strings are supported.
 */
+ (nullable NSString *)sdl_supportsRequiredProtocolStrings {
    NSArray<NSString *> *protocolStrings = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"UISupportedExternalAccessoryProtocols"];

    if (![protocolStrings containsObject:MultiSessionProtocolString]) {
        return MultiSessionProtocolString;
    }

    if (![protocolStrings containsObject:LegacyProtocolString]) {
        return LegacyProtocolString;
    }

    for (int i = 0; i < 30; i++) {
        NSString *indexedProtocolString = [NSString stringWithFormat:@"%@%i", IndexedProtocolStringPrefix, i];
        if (![protocolStrings containsObject:indexedProtocolString]) {
            return indexedProtocolString;
        }
    }

    return nil;
}

/**
 *  Attept to establish a session with an accessory, or if nil is passed, to scan for one.
 *
 *  @param accessory The accessory to try to establish a session with, or nil to scan all connected accessories.
 */
- (void)sdl_establishSessionWithAccessory:(nullable EAAccessory *)accessory {
    SDLLogD(@"Attempting to connect");
    if (self.retryCounter < createSessionRetries) {
        // We should be attempting to connect
        self.retryCounter++;
        
        EAAccessory *sdlAccessory = accessory;
        // If we are being called from sdl_connectAccessory, the EAAccessoryDidConnectNotification will contain the SDL accessory to connect to and we can connect without searching the accessory manager's connected accessory list. Otherwise, we fall through to a search.
        if (sdlAccessory != nil && [self sdl_connectAccessory:sdlAccessory]) {
            // Connection underway, exit
            return;
        }

        if ([self.class sdl_supportsRequiredProtocolStrings] != nil) {
            NSString *failedString = [self.class sdl_supportsRequiredProtocolStrings];
            SDLLogE(@"A required External Accessory protocol string is missing from the info.plist: %@", failedString);
            NSAssert(NO, @"Some SDL protocol strings are not supported, check the README for all strings that must be included in your info.plist file. Missing string: %@", failedString);
            return;
        }
        
        // Determine if we can start a multi-app session or a legacy (single-app) session
        if ((sdlAccessory = [EAAccessoryManager findAccessoryForProtocol:MultiSessionProtocolString]) && SDL_SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"9")) {
            [self sdl_createIAPDataSessionWithAccessory:sdlAccessory forProtocol:MultiSessionProtocolString];
        } else if ((sdlAccessory = [EAAccessoryManager findAccessoryForProtocol:ControlProtocolString])) {
            [self sdl_createIAPControlSessionWithAccessory:sdlAccessory];
        } else if ((sdlAccessory = [EAAccessoryManager findAccessoryForProtocol:LegacyProtocolString])) {
            [self sdl_createIAPDataSessionWithAccessory:sdlAccessory forProtocol:LegacyProtocolString];
        } else {
            // No compatible accessory
            SDLLogV(@"No accessory supporting SDL was found, dismissing setup");
            self.sessionSetupInProgress = NO;
        }
        
    } else {
        // We are beyond the number of retries allowed
		self.state = SDLTransportStateConnectFailed;
         	SDLLogW(@"Surpassed allowed retry attempts");
		if (self.delegate && [self.delegate respondsToSelector:@selector(onTransportFailed)]){
			[self.delegate onTransportFailed];
		}
        self.sessionSetupInProgress = NO;
    }
}

- (void)sdl_createIAPControlSessionWithAccessory:(EAAccessory *)accessory {
    SDLLogD(@"Starting IAP control session (%@)", accessory);
    self.controlSession = [[SDLIAPSession alloc] initWithAccessory:accessory forProtocol:ControlProtocolString];
    
    if (self.controlSession) {
        self.controlSession.delegate = self;
        
        if (self.protocolIndexTimer == nil) {
            self.protocolIndexTimer = [[SDLTimer alloc] initWithDuration:protocolIndexTimeoutSeconds repeat:NO];
        } else {
            [self.protocolIndexTimer cancel];
        }
        
        __weak typeof(self) weakSelf = self;
        void (^elapsedBlock)(void) = ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            
            SDLLogW(@"Control session timeout");
            [strongSelf.controlSession stop];
            strongSelf.controlSession.streamDelegate = nil;
            strongSelf.controlSession = nil;
            [strongSelf sdl_retryEstablishSession];
        };
        self.protocolIndexTimer.elapsedBlock = elapsedBlock;
        
        SDLStreamDelegate *controlStreamDelegate = [[SDLStreamDelegate alloc] init];
        controlStreamDelegate.streamHasBytesHandler = [self sdl_controlStreamHasBytesHandlerForAccessory:accessory];
        controlStreamDelegate.streamEndHandler = [self sdl_controlStreamEndedHandler];
        controlStreamDelegate.streamErrorHandler = [self sdl_controlStreamErroredHandler];
        self.controlSession.streamDelegate = controlStreamDelegate;
        
        if (![self.controlSession start]) {
            SDLLogW(@"Control session failed to setup (%@)", accessory);
            self.controlSession.streamDelegate = nil;
            self.controlSession = nil;
			
			double retryDelay = [self retryDelayWithMinValue:1.5 maxValue:5.5];
			SDLLogW(@"Retry control session in %0.03fs", retryDelay);
            [self sdl_retryEstablishSessionWithDelay:retryDelay];
        }
    } else {
        SDLLogW(@"Failed to setup control session (%@)", accessory);
        [self sdl_retryEstablishSession];
    }
}

- (void)sdl_createIAPDataSessionWithAccessory:(EAAccessory *)accessory forProtocol:(NSString *)protocol {
    SDLLogD(@"Starting data session (%@:%@)", protocol, accessory);
    self.session = [[SDLIAPSession alloc] initWithAccessory:accessory forProtocol:protocol];
    if (self.session) {
        self.session.delegate = self;
        
        SDLStreamDelegate *ioStreamDelegate = [[SDLStreamDelegate alloc] init];
        self.session.streamDelegate = ioStreamDelegate;
        ioStreamDelegate.streamHasBytesHandler = [self sdl_dataStreamHasBytesHandler];
        ioStreamDelegate.streamEndHandler = [self sdl_dataStreamEndedHandler];
        ioStreamDelegate.streamErrorHandler = [self sdl_dataStreamErroredHandler];
        
        if (![self.session start]) {
            SDLLogW(@"Data session failed to setup (%@)", accessory);
            self.session.streamDelegate = nil;
            self.session = nil;
            [self sdl_retryEstablishSession];
        }
    } else {
        SDLLogW(@"Failed to setup data session (%@)", accessory);
        [self sdl_retryEstablishSession];
    }
}

- (void)sdl_retryEstablishSession {
    [self sdl_retryEstablishSessionWithDelay:0];
}

- (void)sdl_retryEstablishSessionWithDelay:(double)delay {
    // Current strategy disallows automatic retries.
    self.sessionSetupInProgress = NO;
    if (self.session != nil) {
        [self.session stop];
        self.session.delegate = nil;
        self.session = nil;
    }
    // No accessory to use this time, search connected accessories
    if (delay > 0) {
        [self performSelector:@selector(sdl_connect:) withObject:nil afterDelay:delay];
    } else {
        [self sdl_connect:nil];
    }
}

// This gets called after both I/O streams of the session have opened.
- (void)onSessionInitializationCompleteForSession:(SDLIAPSession *)session {
    // Control Session Opened
    if ([ControlProtocolString isEqualToString:session.protocol]) {
        SDLLogD(@"Control Session Established");
        [self.protocolIndexTimer start];
    }
    
    // Data Session Opened
    if (![ControlProtocolString isEqualToString:session.protocol]) {
        self.sessionSetupInProgress = NO;
        SDLLogD(@"Data Session Established");
        [self.delegate onTransportConnected];
    }
}


#pragma mark - Session End

// Retry establishSession on Stream End events only if it was the control session and we haven't already connected on non-control protocol
- (void)onSessionStreamsEnded:(SDLIAPSession *)session {
    SDLLogV(@"Session streams ended (%@)", session.protocol);
    if (!self.session && [ControlProtocolString isEqualToString:session.protocol]) {
        [session stop];
        [self sdl_retryEstablishSession];
    }
}


#pragma mark - Data Transmission

- (void)sendData:(NSData *)data {
    if (self.session == nil || !self.session.accessory.connected) {
        return;
    }
    
    [self.session sendData:data];
}


#pragma mark - Stream Handlers
#pragma mark Control Stream

- (SDLStreamEndHandler)sdl_controlStreamEndedHandler {
    __weak typeof(self) weakSelf = self;
    
    return ^(NSStream *stream) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        SDLLogD(@"Control stream ended");
        
        // End events come in pairs, only perform this once per set.
        if (strongSelf.controlSession != nil) {
            [strongSelf.protocolIndexTimer cancel];
            [strongSelf.controlSession stop];
            strongSelf.controlSession.streamDelegate = nil;
            strongSelf.controlSession = nil;

			double retryDelay = [self retryDelayWithMinValue:1.5 maxValue:5.5];
			SDLLogW(@"Retry control session in %0.03fs", retryDelay);
            [strongSelf sdl_retryEstablishSessionWithDelay:retryDelay];
        }
    };
}

- (SDLStreamHasBytesHandler)sdl_controlStreamHasBytesHandlerForAccessory:(EAAccessory *)accessory {
    __weak typeof(self) weakSelf = self;
    
    return ^(NSInputStream *istream) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        SDLLogV(@"Control stream received data");
        
        // Read in the stream a single byte at a time
        uint8_t buf[1];
        NSUInteger len = [istream read:buf maxLength:1];
        if (len <= 0) {
            return;
        }
        
        // If we have data from the stream
        // Determine protocol string of the data session, then create that data session
        NSString *indexedProtocolString = [NSString stringWithFormat:@"%@%@", IndexedProtocolStringPrefix, @(buf[0])];
        SDLLogD(@"Control Stream will switch to protocol %@", indexedProtocolString);
        
        // Destroy the control session
        [strongSelf.protocolIndexTimer cancel];
        dispatch_sync(dispatch_get_main_queue(), ^{
            [strongSelf.controlSession stop];
            strongSelf.controlSession.streamDelegate = nil;
            strongSelf.controlSession = nil;
        });
        
        if (accessory.isConnected) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.retryCounter = 0;
                [strongSelf sdl_createIAPDataSessionWithAccessory:accessory forProtocol:indexedProtocolString];
            });
        }
    };
}

- (SDLStreamErrorHandler)sdl_controlStreamErroredHandler {
    __weak typeof(self) weakSelf = self;
    
    return ^(NSStream *stream) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        SDLLogE(@"Control stream error");
        
        [strongSelf.protocolIndexTimer cancel];
        [strongSelf.controlSession stop];
        strongSelf.controlSession.streamDelegate = nil;
        strongSelf.controlSession = nil;

        double retryDelay = controlSessionRetryOffsetSeconds + self.retryDelay;
		SDLLogW(@"Retry control session in %0.03fs", retryDelay);
        [strongSelf sdl_retryEstablishSessionWithDelay:retryDelay];
    };
}


#pragma mark Data Stream

- (SDLStreamEndHandler)sdl_dataStreamEndedHandler {
    __weak typeof(self) weakSelf = self;
    
    return ^(NSStream *stream) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        SDLLogD(@"Data stream ended");
        if (strongSelf.session != nil) {
            // The handler will be called on the IO thread, but the session stop method must be called on the main thread and we need to wait for the session to stop before nil'ing it out. To do this, we use dispatch_sync() on the main thread.
            dispatch_sync(dispatch_get_main_queue(), ^{
                [strongSelf.session stop];
            });
            strongSelf.session.streamDelegate = nil;
            strongSelf.session = nil;
        }
        // We don't call sdl_retryEstablishSession here because the stream end event usually fires when the accessory is disconnected
    };
}

- (SDLStreamHasBytesHandler)sdl_dataStreamHasBytesHandler {
    __weak typeof(self) weakSelf = self;
    
    return ^(NSInputStream *istream) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        
        uint8_t buf[[[SDLGlobals sharedGlobals] mtuSizeForServiceType:SDLServiceTypeRPC]];
        while (istream.streamStatus == NSStreamStatusOpen && istream.hasBytesAvailable) {
            // It is necessary to check the stream status and whether there are bytes available because the dataStreamHasBytesHandler is executed on the IO thread and the accessory disconnect notification arrives on the main thread, causing data to be passed to the delegate while the main thread is tearing down the transport.
            
            NSInteger bytesRead = [istream read:buf maxLength:[[SDLGlobals sharedGlobals] mtuSizeForServiceType:SDLServiceTypeRPC]];
            NSData *dataIn = [NSData dataWithBytes:buf length:bytesRead];
            SDLLogBytes(dataIn, SDLLogBytesDirectionReceive);

            if (bytesRead > 0) {
                [strongSelf.delegate onDataReceived:dataIn];
            } else {
                break;
            }
        }
    };
}

- (SDLStreamErrorHandler)sdl_dataStreamErroredHandler {
    __weak typeof(self) weakSelf = self;
    
    return ^(NSStream *stream) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        SDLLogE(@"Data stream error");
        dispatch_sync(dispatch_get_main_queue(), ^{
            [strongSelf.session stop];
        });
        strongSelf.session.streamDelegate = nil;
        strongSelf.session = nil;
        if (![LegacyProtocolString isEqualToString:strongSelf.session.protocol]) {
            [strongSelf sdl_retryEstablishSession];
        }
    };
}

- (double)retryDelayWithMinValue:(double)min maxValue:(double)max{
	const double min_value = min;
	const double max_value = max;
	double range_length = max_value - min_value;
	double delay = min_value;
	UInt64 randomLong;
	
	int ret = SecRandomCopyBytes(kSecRandomDefault, sizeof(UInt64), (uint8_t *)&randomLong);
	if (ret == 0){
		// Transform the string into a number between 0 and 1
		double randomValueInRange0to1 = ((double)randomLong) / 0xffffffffffffffff;
		
		// Transform the number into a number between min and max
		delay = ((range_length * randomValueInRange0to1) + min_value);
		
	}
	
	return delay;
}

- (double)retryDelay{
	return [self retryDelayWithMinValue:1.5 maxValue:9.5];
}

#pragma mark - Lifecycle Destruction

- (void)sdl_destructObjects {
    if (!_alreadyDestructed) {
		[self sdl_backgroundTaskEnd];
        [self sdl_stopEventListening];
        [self disconnect];
        _alreadyDestructed = YES;
        [self.protocolIndexTimer cancel];
        self.controlSession = nil;
        self.session = nil;
        self.delegate = nil;
        self.sessionSetupInProgress = NO;
    }
}

- (void)dealloc {
    [self sdl_destructObjects];
    SDLLogD(@"SDLIAPTransport dealloc");
}

@end

NS_ASSUME_NONNULL_END
