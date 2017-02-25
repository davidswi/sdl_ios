//
//  SDLIAPSession.m
//

#import "SDLIAPSession.h"
#import "SDLDebugTool.h"
#import "SDLStreamDelegate.h"
#import "SDLTimer.h"

#define IO_STREAMTHREAD_NAME         @ "com.smartdevicelink.iostream"

#define STREAM_THREAD_WAIT_SECS 1.0

@interface SDLIAPSession ()

@property (assign) BOOL isInputStreamOpen;
@property (assign) BOOL isOutputStreamOpen;
@property (nonatomic, strong) dispatch_semaphore_t canceledSema;
@property (atomic, assign) NSInteger bytesWritten;

@end


@implementation SDLIAPSession

#pragma mark - Lifecycle

- (instancetype)initWithAccessory:(EAAccessory *)accessory forProtocol:(NSString *)protocol {
    NSString *logMessage = [NSString stringWithFormat:@"SDLIAPSession initWithAccessory:%@ forProtocol:%@", accessory, protocol];
    [SDLDebugTool logInfo:logMessage];

    self = [super init];
    if (self) {
        _delegate = nil;
        _accessory = accessory;
        _protocol = protocol;
        _streamDelegate = nil;
        _easession = nil;
        _isInputStreamOpen = NO;
        _isOutputStreamOpen = NO;
        _canceledSema = dispatch_semaphore_create(0);
    }
    return self;
}


#pragma mark - Public Stream Lifecycle

- (BOOL)start {
    __weak typeof(self) weakSelf = self;

    NSString *logMessage = [NSString stringWithFormat:@"Opening EASession withAccessory:%@ forProtocol:%@", _accessory.name, _protocol];
    [SDLDebugTool logInfo:logMessage];

    if ((self.easession = [[EASession alloc] initWithAccessory:_accessory forProtocol:_protocol])) {
        __strong typeof(self) strongSelf = weakSelf;

        [SDLDebugTool logInfo:@"Created Session Object"];

        strongSelf.streamDelegate.streamErrorHandler = [self streamErroredHandler];
        strongSelf.streamDelegate.streamOpenHandler = [self streamOpenedHandler];
#if USE_MAIN_THREAD
        [strongSelf startStream:weakSelf.easession.outputStream];
        [strongSelf startStream:weakSelf.easession.inputStream];
#else 
      // Start I/O event loop processing events in iAP channel
      _ioStreamThread = [[NSThread alloc] initWithTarget:self selector:@selector(accessoryEventLoop) object:nil];
      [_ioStreamThread setName:IO_STREAMTHREAD_NAME];
      [_ioStreamThread start];
      
#endif

        return YES;

    } else {
        [SDLDebugTool logInfo:@"Error: Could Not Create Session Object"];
        return NO;
    }
}

- (void)stop {
  #if USE_MAIN_THREAD
    [self stopStream:self.easession.outputStream];
    [self stopStream:self.easession.inputStream];
    self.easession = nil;
#else
  [_ioStreamThread cancel];
    
    long lWait = dispatch_semaphore_wait(self.canceledSema, dispatch_time(DISPATCH_TIME_NOW, STREAM_THREAD_WAIT_SECS * NSEC_PER_SEC));
    if (lWait == 0){
        NSLog(@"Stream thread canceled");
        _ioStreamThread = nil;
    }
    else{
        NSLog(@"ERROR! Failed to cancel stream thread!!!");
    }
#endif
}

- (void)writeToOutputStream:(NSData *)data{
    self.bytesWritten = [self.easession.outputStream write:data.bytes maxLength:data.length];
}

- (void)sendData:(NSData *)data{
    NSOutputStream *ostream = self.easession.outputStream;
    NSMutableData *remainder = data.mutableCopy;
    
    while (remainder.length != 0 &&
           ostream != nil &&
           ostream.streamStatus == NSStreamStatusOpen){
        if (ostream.hasSpaceAvailable) {
            [self performSelector:@selector(writeToOutputStream:) onThread:self.ioStreamThread withObject:remainder waitUntilDone:YES];
        
            if (self.bytesWritten == -1) {
                [SDLDebugTool logInfo:[NSString stringWithFormat:@"Error: %@", [ostream streamError]] withType:SDLDebugType_Transport_iAP toOutput:SDLDebugOutput_All];
                break;
            }
        
        [remainder replaceBytesInRange:NSMakeRange(0, self.bytesWritten) withBytes:NULL length:0];
    }
}

- (void)accessoryEventLoop {
  @autoreleasepool {
    NSAssert(self.easession, @"_session must be assigned before calling");
    
    if (!self.easession) {
      return;
    }
    
    // Open I/O streams of the iAP session
    NSInputStream *inStream = [self.easession inputStream];
    [inStream setDelegate:self.streamDelegate];
    [inStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [inStream open];
    
    NSOutputStream *outStream = [self.easession outputStream];
    [outStream setDelegate:self.streamDelegate];
    [outStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [outStream open];
    
    NSLog(@"starting the event loop for accessory");
    do {
      @autoreleasepool {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.25f]];
      }
    } while (![[NSThread currentThread] isCancelled] &&
             outStream != nil &&
             outStream.streamStatus != NSStreamStatusClosed);
    
    NSLog(@"closing accessory session");
    
    // Close I/O streams of the iAP session
    [self closeSession];
    _accessory = nil;
      dispatch_semaphore_signal(self.canceledSema);
  }
}

// Must be called on accessoryEventLoop.
- (void)closeSession {
  if (self.easession) {
    NSLog(@"Close EASession: %tu", self.easession.accessory.connectionID);
    NSInputStream *inStream = [self.easession inputStream];
    NSOutputStream *outStream = [self.easession outputStream];
    
    [inStream close];
    [inStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [inStream setDelegate:nil];
    
    [outStream close];
    [outStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [outStream setDelegate:nil];
    
    self.easession = nil;
  }
}


#pragma mark - Private Stream Lifecycle Helpers

- (void)startStream:(NSStream *)stream {
    stream.delegate = self.streamDelegate;
    [stream scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    [stream open];
}

- (void)stopStream:(NSStream *)stream {
    // Verify stream is in a state that can be closed.
    // (N.B. Closing a stream that has not been opened has very, very bad effects.)

    // When you disconect the cable you get a stream end event and come here but stream is already in closed state.
    // Still need to remove from run loop.

    NSUInteger status1 = stream.streamStatus;
    if (status1 != NSStreamStatusNotOpen &&
        status1 != NSStreamStatusClosed) {
        [stream close];
    }

    [stream removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    [stream setDelegate:nil];

    NSUInteger status2 = stream.streamStatus;
    if (status2 == NSStreamStatusClosed) {
        if (stream == [self.easession inputStream]) {
            [SDLDebugTool logInfo:@"Input Stream Closed"];
        } else if (stream == [self.easession outputStream]) {
            [SDLDebugTool logInfo:@"Output Stream Closed"];
        }
    }
}


#pragma mark - Stream Handlers

- (SDLStreamOpenHandler)streamOpenedHandler {
    __weak typeof(self) weakSelf = self;

    return ^(NSStream *stream) {
        __strong typeof(weakSelf) strongSelf = weakSelf;

        if (stream == [strongSelf.easession outputStream]) {
            [SDLDebugTool logInfo:@"Output Stream Opened"];
            strongSelf.isOutputStreamOpen = YES;
        } else if (stream == [strongSelf.easession inputStream]) {
            [SDLDebugTool logInfo:@"Input Stream Opened"];
            strongSelf.isInputStreamOpen = YES;
        }

        // When both streams are open, session initialization is complete. Let the delegate know.
        if (strongSelf.isInputStreamOpen && strongSelf.isOutputStreamOpen) {
            [strongSelf.delegate onSessionInitializationCompleteForSession:weakSelf];
        }
    };
}

- (SDLStreamErrorHandler)streamErroredHandler {
    __weak typeof(self) weakSelf = self;

    return ^(NSStream *stream) {
        __strong typeof(weakSelf) strongSelf = weakSelf;

        [SDLDebugTool logInfo:@"Stream Error"];
        [strongSelf.delegate onSessionStreamsEnded:strongSelf];
    };
}


#pragma mark - Lifecycle Destruction

- (void)dealloc {
    self.delegate = nil;
    self.accessory = nil;
    self.protocol = nil;
    self.streamDelegate = nil;
    self.easession = nil;
    self.ioStreamThread =  nil;
    self.canceledSema = nil;
    [SDLDebugTool logInfo:@"SDLIAPSession Dealloc"];
}

@end
