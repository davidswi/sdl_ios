//
//  SDLURLRequestTask.m
//  SmartDeviceLink-iOS
//
//  Created by Joel Fischer on 8/17/15.
//  Copyright (c) 2015 smartdevicelink. All rights reserved.
//

#import "SDLURLRequestTask.h"

#import "SDLURLSession.h"
#import "SDLDebugTool.h"

NS_ASSUME_NONNULL_BEGIN

@interface SDLURLRequestTask () <NSURLConnectionDelegate, NSURLConnectionDataDelegate>

@property (strong, nonatomic) NSURLConnection *connection;
@property (strong, nonatomic, nullable) NSURLResponse *response;
@property (copy, nonatomic) SDLURLConnectionRequestCompletionHandler completionHandler;
@property (strong, nonatomic) NSMutableData *mutableData;

@end


@implementation SDLURLRequestTask

#pragma mark - Lifecycle

- (instancetype)init {
    NSAssert(NO, @"use initWithURLRequest:completionHandler instead");
    return nil;
}

- (instancetype)initWithURLRequest:(NSURLRequest *)request completionHandler:(SDLURLConnectionRequestCompletionHandler)completionHandler {
    self = [super init];
    if (!self) {
        return nil;
    }

    _connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
    [_connection scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    [_connection start];

    _completionHandler = completionHandler;

    _mutableData = [NSMutableData data];
    _response = nil;
    _state = SDLURLRequestTaskStateRunning;

    return self;
}

+ (instancetype)taskWithURLRequest:(NSURLRequest *)request completionHandler:(SDLURLConnectionRequestCompletionHandler)completionHandler {
    return [[self alloc] initWithURLRequest:request completionHandler:completionHandler];
}

- (void)dealloc {
    [SDLDebugTool logInfo:@"SDLURLRequestTask dealloc"];
    _state = SDLURLRequestTaskStateCanceled;
    [_connection cancel];
}


#pragma mark - Data Methods

- (void)sdl_addData:(NSData *)data {
    [self.mutableData appendData:data];
}


#pragma mark - Cancel

- (void)cancel {
    [SDLDebugTool logInfo:@"SDLURLRequestTask cancel"];
    self.state = SDLURLRequestTaskStateCanceled;
    [self.connection cancel];
    [self connection:self.connection didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:kCFURLErrorCancelled userInfo:nil]];
}


#pragma mark - NSURLConnectionDelegate
    
// Per https://stackoverflow.com/questions/12901536/reference-to-self-inside-block self should be referenced inside completion blocks using the strong-weak self dance

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    __weak SDLURLRequestTask *weakSelf = self;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong SDLURLRequestTask *strongSelf = weakSelf;
        
        strongSelf.completionHandler(nil, strongSelf.response, error);

        strongSelf.state = SDLURLRequestTaskStateCompleted;
        [strongSelf.delegate taskDidFinish:strongSelf];
    });
}


#pragma mark - NSURLConnectionDataDelegate

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    [self sdl_addData:data];
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    self.response = response;
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    __weak SDLURLRequestTask *weakSelf = self;
    if (self.state == SDLURLRequestTaskStateCanceled || self.state == SDLURLRequestTaskStateCompleted){
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong SDLURLRequestTask *strongSelf = weakSelf;
        strongSelf.completionHandler([strongSelf.mutableData copy], strongSelf.response, nil);

        strongSelf.state = SDLURLRequestTaskStateCompleted;
        [strongSelf.delegate taskDidFinish:strongSelf];
    });
}

@end

NS_ASSUME_NONNULL_END
