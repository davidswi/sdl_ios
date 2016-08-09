//
//  SDLListFilesOperation.h
//  SmartDeviceLink-iOS
//
//  Created by Joel Fischer on 5/25/16.
//  Copyright © 2016 smartdevicelink. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "SDLFileManagerConstants.h"

@protocol SDLConnectionManagerType;

NS_ASSUME_NONNULL_BEGIN

@interface SDLListFilesOperation : NSOperation

/**
 *  Create an instance of a list files operation which will ask the remote system which files it has on its system already.
 *
 *  @param connectionManager The connection manager which will handle transporting the request to the remote system.
 *  @param completionHandler A completion handler for when the response returns.
 *
 *  @return An instance of SDLListFilesOperation
 */
- (instancetype)initWithConnectionManager:(id<SDLConnectionManagerType>)connectionManager completionHandler:(nullable SDLFileManagerListFilesCompletion)completionHandler;

@end

NS_ASSUME_NONNULL_END