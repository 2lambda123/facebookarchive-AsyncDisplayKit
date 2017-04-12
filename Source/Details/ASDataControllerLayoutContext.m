//
//  ASDataControllerLayoutContext.m
//  AsyncDisplayKit
//
//  Created by Huy Nguyen on 21/3/17.
//  Copyright © 2017 Facebook. All rights reserved.
//

#import <AsyncDisplayKit/ASDataControllerLayoutContext.h>
#import <AsyncDisplayKit/ASAssert.h>
#import <AsyncDisplayKit/ASElementMap.h>
#import <AsyncDisplayKit/ASEqualityHelpers.h>

@implementation ASDataControllerLayoutContext

- (instancetype)initWithViewportSize:(CGSize)viewportSize elementMap:(ASElementMap *)map
{
  self = [super init];
  if (self) {
    _viewportSize = viewportSize;
    _elementMap = map;
  }
  return self;
}

- (BOOL)isEqualToContext:(ASDataControllerLayoutContext *)context
{
  if (context == nil) {
    return NO;
  }
  return CGSizeEqualToSize(_viewportSize, context.viewportSize) && ASObjectIsEqual(_elementMap, context.elementMap);
}

- (BOOL)isEqual:(id)other
{
  if (self == other) {
    return YES;
  }
  if (! [other isKindOfClass:[ASDataControllerLayoutContext class]]) {
    return NO;
  }
  return [self isEqualToContext:other];
}

- (NSUInteger)hash
{
  return [_elementMap hash] ^ (((NSUInteger)(_viewportSize.width * 255) << 8) + (NSUInteger)(_viewportSize.height * 255));
}

@end
