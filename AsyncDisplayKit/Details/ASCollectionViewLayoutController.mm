/* Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "ASCollectionViewLayoutController.h"

#include <vector>

#import "ASAssert.h"
#import "ASCollectionView.h"
#import "CGRect+ASConvenience.h"

struct ASDirectionalScreenfulBuffer {
  CGFloat positiveDirection; // Positive relative to iOS Core Animation layer coordinate space.
  CGFloat negativeDirection;
};
typedef struct ASDirectionalScreenfulBuffer ASDirectionalScreenfulBuffer;

ASDirectionalScreenfulBuffer ASDirectionalScreenfulBufferHorizontal(ASScrollDirection scrollDirection,
                                                                    ASRangeTuningParameters rangeTuningParameters) {
  ASDirectionalScreenfulBuffer horizontalBuffer = {0, 0};
  BOOL movingRight = ASScrollDirectionContainsRight(scrollDirection);
  horizontalBuffer.positiveDirection = movingRight ? rangeTuningParameters.leadingBufferScreenfuls :
                                                     rangeTuningParameters.trailingBufferScreenfuls;
  horizontalBuffer.negativeDirection = movingRight ? rangeTuningParameters.trailingBufferScreenfuls :
                                                     rangeTuningParameters.leadingBufferScreenfuls;
  return horizontalBuffer;
}

ASDirectionalScreenfulBuffer ASDirectionalScreenfulBufferVertical(ASScrollDirection scrollDirection,
                                                                  ASRangeTuningParameters rangeTuningParameters) {
  ASDirectionalScreenfulBuffer verticalBuffer = {0, 0};
  BOOL movingDown = ASScrollDirectionContainsDown(scrollDirection);
  verticalBuffer.positiveDirection = movingDown ? rangeTuningParameters.leadingBufferScreenfuls :
                                                  rangeTuningParameters.trailingBufferScreenfuls;
  verticalBuffer.negativeDirection = movingDown ? rangeTuningParameters.trailingBufferScreenfuls :
                                                  rangeTuningParameters.leadingBufferScreenfuls;
  return verticalBuffer;
}

struct ASRangeGeometry {
  CGRect rangeBounds;
  CGRect updateBounds;
};
typedef struct ASRangeGeometry ASRangeGeometry;


#pragma mark -
#pragma mark ASCollectionViewLayoutController

@interface ASCollectionViewLayoutController () {
  ASCollectionView * __weak _collectionView;
  std::vector<CGRect> _updateRangeBoundsIndexedByRangeType;
}
@end

@implementation ASCollectionViewLayoutController

- (instancetype)initWithCollectionView:(ASCollectionView *)collectionView {
  if (!(self = [super init])) {
    return nil;
  }
  _collectionView = collectionView;
  _updateRangeBoundsIndexedByRangeType = std::vector<CGRect>(ASLayoutRangeTypeCount);
  return self;
}

#pragma mark -
#pragma mark Index Paths in Range

- (NSSet *)indexPathsForScrolling:(ASScrollDirection)scrollDirection
                     viewportSize:(CGSize)viewportSize
                        rangeType:(ASLayoutRangeType)rangeType {
  ASRangeGeometry rangeGeometry = [self rangeGeometryWithScrollDirection:scrollDirection
                                                          collectionView:_collectionView
                                                   rangeTuningParameters:[self tuningParametersForRangeType:rangeType]];
  _updateRangeBoundsIndexedByRangeType[rangeType] = rangeGeometry.updateBounds;
  return [self indexPathsForItemsWithinRangeBounds:rangeGeometry.rangeBounds collectionView:_collectionView];
}

- (ASRangeGeometry)rangeGeometryWithScrollDirection:(ASScrollDirection)scrollDirection
                                     collectionView:(ASCollectionView *)collectionView
                              rangeTuningParameters:(ASRangeTuningParameters)rangeTuningParameters {
  CGRect rangeBounds = collectionView.bounds;
  CGRect updateBounds = collectionView.bounds;
  ASScrollDirection scrollableDirections = [collectionView scrollableDirections];
  
  BOOL canScrollHorizontally = ASScrollDirectionContainsHorizontalDirection(scrollableDirections);
  if (canScrollHorizontally) {
    ASDirectionalScreenfulBuffer horizontalBuffer = ASDirectionalScreenfulBufferHorizontal(scrollDirection,
                                                                                           rangeTuningParameters);
    rangeBounds = asdk_CGRectExpandHorizontally(rangeBounds,
                                                horizontalBuffer.negativeDirection,
                                                horizontalBuffer.positiveDirection);
    // Update bounds is at most 95% of the next/previous screenful and at least half of tuning parameter value.
    updateBounds = asdk_CGRectExpandHorizontally(updateBounds,
                                                 MIN(horizontalBuffer.negativeDirection * 0.5, 0.95),
                                                 MIN(horizontalBuffer.positiveDirection * 0.5, 0.95));
  }
  
  BOOL canScrollVertically = ASScrollDirectionContainsVerticalDirection(scrollableDirections);
  if (canScrollVertically) {
    ASDirectionalScreenfulBuffer verticalBuffer = ASDirectionalScreenfulBufferVertical(scrollDirection,
                                                                                       rangeTuningParameters);
    rangeBounds = asdk_CGRectExpandVertically(rangeBounds,
                                              verticalBuffer.negativeDirection,
                                              verticalBuffer.positiveDirection);
    // Update bounds is at most 95% of the next/previous screenful and at least half of tuning parameter value.
    updateBounds = asdk_CGRectExpandVertically(updateBounds,
                                               MIN(verticalBuffer.negativeDirection * 0.5, 0.95),
                                               MIN(verticalBuffer.positiveDirection * 0.5, 0.95));
  }

  return {rangeBounds, updateBounds};
}

- (NSSet *)indexPathsForItemsWithinRangeBounds:(CGRect)rangeBounds collectionView:(ASCollectionView *)collectionView {
  NSMutableSet *indexPathSet = [[NSMutableSet alloc] init];
  NSArray *layoutAttributes = [collectionView.collectionViewLayout layoutAttributesForElementsInRect:rangeBounds];
  for (UICollectionViewLayoutAttributes *la in layoutAttributes) {
    [indexPathSet addObject:la.indexPath];
  }
  return indexPathSet;
}

#pragma mark -
#pragma mark Should Update Range

- (BOOL)shouldUpdateForVisibleIndexPaths:(NSArray *)indexPaths
                            viewportSize:(CGSize)viewportSize
                               rangeType:(ASLayoutRangeType)rangeType {
  CGRect updateRangeBounds = _updateRangeBoundsIndexedByRangeType[rangeType];
  if (CGRectIsEmpty(updateRangeBounds)) {
    return YES;
  }
  
  CGRect currentBounds = _collectionView.bounds;
  if (CGRectIsEmpty(currentBounds)) {
    currentBounds = CGRectMake(0, 0, viewportSize.width, viewportSize.height);
  }
  
  if (CGRectContainsRect(updateRangeBounds, currentBounds)) {
    return NO;
  } else {
    return YES;
  }
}

@end
