//  SDLInteractionMode.h
//  SyncProxy
//  Copyright (c) 2014 Ford Motor Company. All rights reserved.

#import <Foundation/Foundation.h>
#import <AppLink/SDLEnum.h>

@interface SDLInteractionMode : SDLEnum {}

+(SDLInteractionMode*) valueOf:(NSString*) value;
+(NSMutableArray*) values;

+(SDLInteractionMode*) MANUAL_ONLY;
+(SDLInteractionMode*) VR_ONLY;
+(SDLInteractionMode*) BOTH;

@end