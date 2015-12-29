/* Copyright (c) 2014-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "_ASCoreAnimationExtras.h"
#import "_ASPendingState.h"
#import "ASInternalHelpers.h"
#import "ASAssert.h"
#import "ASDisplayNodeInternal.h"
#import "ASDisplayNode+Subclasses.h"
#import "ASDisplayNode+FrameworkPrivate.h"
#import "ASDisplayNode+Beta.h"
#import "ASEqualityHelpers.h"
#import "ASMainQueueTransaction.h"

/**
 * The following macros are conveniences to help in the common tasks related to the bridging that ASDisplayNode does to UIView and CALayer.
 * In general, a property can either be:
 *   - Always sent to the layer or view's layer
 *       use _getFromLayer / _setToLayer
 *   - Bridged to the view if view-backed or the layer if layer-backed
 *       use _getFromViewOrLayer / _setToViewOrLayer / _messageToViewOrLayer
 *   - Only applicable if view-backed
 *       use _setToViewOnly / _getFromViewOnly
 *   - Has differing types on views and layers, or custom ASDisplayNode-specific behavior is desired
 *       manually implement
 *
 *  _bridge_prologue is defined to either take an appropriate lock or assert thread affinity. Add it at the beginning of any bridged methods.
 */

#define DISPLAYNODE_USE_LOCKS 1

#define __loaded (_layer != nil)

#if DISPLAYNODE_USE_LOCKS
#define _bridge_prologue ASDisplayNodeAssertThreadAffinity(self); ASDN::MutexLocker l(_propertyLock)
#else
#define _bridge_prologue ASDisplayNodeAssertThreadAffinity(self)
#endif


#define _getFromViewOrLayer(layerProperty, viewAndPendingViewStateProperty) __loaded ? \
  (_view ? _view.viewAndPendingViewStateProperty : _layer.layerProperty )\
 : self.pendingViewState.viewAndPendingViewStateProperty

#define _setToViewOrLayer(layerProperty, layerValueExpr, viewAndPendingViewStateProperty, viewAndPendingViewStateExpr) __loaded ? \
   (_view ? _view.viewAndPendingViewStateProperty = (viewAndPendingViewStateExpr) : _layer.layerProperty = (layerValueExpr))\
 : self.pendingViewState.viewAndPendingViewStateProperty = (viewAndPendingViewStateExpr)

#define _setToViewOnly(viewAndPendingViewStateProperty, viewAndPendingViewStateExpr) __loaded ? _view.viewAndPendingViewStateProperty = (viewAndPendingViewStateExpr) : self.pendingViewState.viewAndPendingViewStateProperty = (viewAndPendingViewStateExpr)

#define _getFromViewOnly(viewAndPendingViewStateProperty) __loaded ? _view.viewAndPendingViewStateProperty : self.pendingViewState.viewAndPendingViewStateProperty

#define _getFromLayer(layerProperty) __loaded ? _layer.layerProperty : self.pendingViewState.layerProperty

#define _setToLayer(layerProperty, layerValueExpr) __loaded ? _layer.layerProperty = (layerValueExpr) : self.pendingViewState.layerProperty = (layerValueExpr)

#define _messageToViewOrLayer(viewAndLayerSelector) __loaded ? (_view ? [_view viewAndLayerSelector] : [_layer viewAndLayerSelector]) : [self.pendingViewState viewAndLayerSelector]

#define _messageToLayer(layerSelector) __loaded ? [_layer layerSelector] : [self.pendingViewState layerSelector]

/**
 * This category implements certain frequently-used properties and methods of UIView and CALayer so that ASDisplayNode clients can just call the view/layer methods on the node,
 * with minimal loss in performance.  Unlike UIView and CALayer methods, these can be called from a non-main thread until the view or layer is created.
 * This allows text sizing in -calculateSizeThatFits: (essentially a simplified layout) to happen off the main thread
 * without any CALayer or UIView actually existing while still being able to set and read properties from ASDisplayNode instances.
 */
@implementation ASDisplayNode (UIViewBridge)

- (BOOL)canBecomeFirstResponder
{
  return NO;
}

- (BOOL)canResignFirstResponder
{
  return YES;
}

- (BOOL)isFirstResponder
{
  ASDisplayNodeAssertMainThread();
  return _view != nil && [_view isFirstResponder];
}

// Note: this implicitly loads the view if it hasn't been loaded yet.
- (BOOL)becomeFirstResponder
{
  ASDisplayNodeAssertMainThread();
  return !self.layerBacked && [self canBecomeFirstResponder] && [self.view becomeFirstResponder];
}

- (BOOL)resignFirstResponder
{
  ASDisplayNodeAssertMainThread();
  return !self.layerBacked && [self canResignFirstResponder] && [_view resignFirstResponder];
}

- (BOOL)canPerformAction:(SEL)action withSender:(id)sender
{
  ASDisplayNodeAssertMainThread();
  return !self.layerBacked && [self.view canPerformAction:action withSender:sender];
}

- (CGFloat)alpha
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->alpha;
}

- (void)setAlpha:(CGFloat)newAlpha
{
  ASDN::MutexLocker l(_propertyLock);
  if (self.nodeLoaded) {
    _pendingViewState->alpha = newAlpha;
    [ASMainQueueTransaction performOnMainThread:^{
      _setToViewOrLayer(opacity, newAlpha, alpha, newAlpha);
    }];
  } else {
    _pendingViewState.alpha = newAlpha;
  }
}

- (CGFloat)cornerRadius
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->cornerRadius;
}

- (void)setCornerRadius:(CGFloat)newCornerRadius
{
  ASDN::MutexLocker l(_propertyLock);
  if (self.nodeLoaded) {
    _pendingViewState->cornerRadius = newCornerRadius;
    [ASMainQueueTransaction performOnMainThread:^{
      _setToLayer(cornerRadius, newCornerRadius);
    }];
  } else {
    _pendingViewState.cornerRadius = newCornerRadius;
  }
}

- (CGFloat)contentsScale
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->contentsScale;
}

- (void)setContentsScale:(CGFloat)newContentsScale
{
  ASDN::MutexLocker l(_propertyLock);
  if (self.nodeLoaded) {
    _pendingViewState->contentsScale = newContentsScale;
    [ASMainQueueTransaction performOnMainThread:^{
      _setToLayer(contentsScale, newContentsScale);
    }];
  } else {
    _pendingViewState.contentsScale = newContentsScale;
  }
}

- (CGRect)bounds
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->bounds;
}

- (void)setBounds:(CGRect)newBounds
{
  _bridge_prologue;
  _setToViewOrLayer(bounds, newBounds, bounds, newBounds);
}

- (CGRect)frame
{
  _bridge_prologue;

  // Frame is only defined when transform is identity.
#if DEBUG
  // Checking if the transform is identity is expensive, so disable when unnecessary. We have assertions on in Release, so DEBUG is the only way I know of.
  ASDisplayNodeAssert(CATransform3DIsIdentity(self.transform), @"-[ASDisplayNode frame] - self.transform must be identity in order to use the frame property.  (From Apple's UIView documentation: If the transform property is not the identity transform, the value of this property is undefined and therefore should be ignored.)");
#endif

  CGPoint position = self.position;
  CGRect bounds = self.bounds;
  CGPoint anchorPoint = self.anchorPoint;
  CGPoint origin = CGPointMake(position.x - bounds.size.width * anchorPoint.x,
                               position.y - bounds.size.height * anchorPoint.y);
  return CGRectMake(origin.x, origin.y, bounds.size.width, bounds.size.height);
}

- (void)setFrame:(CGRect)rect
{
  _bridge_prologue;

  if (_flags.synchronous && !_flags.layerBacked) {
    // For classes like ASTableNode, ASCollectionNode, ASScrollNode and similar - make sure UIView gets setFrame:
    
    // Frame is only defined when transform is identity because we explicitly diverge from CALayer behavior and define frame without transform
#if DEBUG
    // Checking if the transform is identity is expensive, so disable when unnecessary. We have assertions on in Release, so DEBUG is the only way I know of.
    ASDisplayNodeAssert(CATransform3DIsIdentity(self.transform), @"-[ASDisplayNode setFrame:] - self.transform must be identity in order to set the frame property.  (From Apple's UIView documentation: If the transform property is not the identity transform, the value of this property is undefined and therefore should be ignored.)");
#endif

    _setToViewOnly(frame, rect);
  } else {
    // This is by far the common case / hot path.
    [self __setSafeFrame:rect];
  }
}

/**
 * Sets a new frame to this node by changing its bounds and position. This method can be safely called even if
 * the transform is a non-identity transform, because bounds and position can be set instead of frame.
 * This is NOT called for synchronous nodes (wrapping regular views), which may rely on a [UIView setFrame:] call.
 * A notable example of the latter is UITableView, which won't resize its internal container if only layer bounds are set.
 */
- (void)__setSafeFrame:(CGRect)rect
{
  ASDisplayNodeAssertThreadAffinity(self);
  ASDN::MutexLocker l(_propertyLock);
  
  BOOL useLayer = (_layer && ASDisplayNodeThreadIsMain());
  
  CGPoint origin      = (useLayer ? _layer.bounds.origin : self.bounds.origin);
  CGPoint anchorPoint = (useLayer ? _layer.anchorPoint   : self.anchorPoint);
  
  CGRect  bounds      = (CGRect){ origin, rect.size };
  CGPoint position    = CGPointMake(rect.origin.x + rect.size.width * anchorPoint.x,
                                    rect.origin.y + rect.size.height * anchorPoint.y);
  
  if (useLayer) {
    _layer.bounds = bounds;
    _layer.position = position;
  } else {
    self.bounds = bounds;
    self.position = position;
  }
}

- (void)setNeedsDisplay
{
  _bridge_prologue;

  if (_hierarchyState & ASHierarchyStateRasterized) {
    ASPerformBlockOnMainThread(^{
      // The below operation must be performed on the main thread to ensure against an extremely rare deadlock, where a parent node
      // begins materializing the view / layer heirarchy (locking itself or a descendant) while this node walks up
      // the tree and requires locking that node to access .shouldRasterizeDescendants.
      // For this reason, this method should be avoided when possible.  Use _hierarchyState & ASHierarchyStateRasterized.
      ASDisplayNodeAssertMainThread();
      ASDisplayNode *rasterizedContainerNode = self.supernode;
      while (rasterizedContainerNode) {
        if (rasterizedContainerNode.shouldRasterizeDescendants) {
          break;
        }
        rasterizedContainerNode = rasterizedContainerNode.supernode;
      }
      [rasterizedContainerNode setNeedsDisplay];
    });
  } else {
    // If not rasterized (and therefore we certainly have a view or layer),
    // Send the message to the view/layer first, as scheduleNodeForDisplay may call -displayIfNeeded.
    // Wrapped / synchronous nodes created with initWithView/LayerBlock: do not need scheduleNodeForDisplay,
    // as they don't need to display in the working range at all - since at all times onscreen, one
    // -setNeedsDisplay to the CALayer will result in a synchronous display in the next frame.

    _messageToViewOrLayer(setNeedsDisplay);

    if ([ASDisplayNode shouldUseNewRenderingRange]) {
      if (_layer && !self.isSynchronous) {
        [ASDisplayNode scheduleNodeForDisplay:self];
      }
    }
  }
}

- (void)setNeedsLayout
{
  [self __setNeedsLayout];
  [ASMainQueueTransaction performOnMainThread:^{
    _messageToViewOrLayer(setNeedsLayout);
  }];
}

- (BOOL)isOpaque
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->opaque;
}

- (void)setOpaque:(BOOL)newOpaque
{
  BOOL prevOpaque = self.opaque;

  _bridge_prologue;
  _setToLayer(opaque, newOpaque);

  if (prevOpaque != newOpaque) {
    [self setNeedsDisplay];
  }
}

- (BOOL)isUserInteractionEnabled
{
  ASDN::MutexLocker l(_propertyLock);
  if (_flags.layerBacked) return NO;
  return _pendingViewState->userInteractionEnabled;
}

- (void)setUserInteractionEnabled:(BOOL)enabled
{
  _bridge_prologue;
  _setToViewOnly(userInteractionEnabled, enabled);
}

- (BOOL)isExclusiveTouch
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->exclusiveTouch;
}

- (void)setExclusiveTouch:(BOOL)exclusiveTouch
{
  _bridge_prologue;
  _setToViewOnly(exclusiveTouch, exclusiveTouch);
}

- (BOOL)clipsToBounds
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->clipsToBounds;
}

- (void)setClipsToBounds:(BOOL)clips
{
  _bridge_prologue;
  _setToViewOrLayer(masksToBounds, clips, clipsToBounds, clips);
}

- (CGPoint)anchorPoint
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->anchorPoint;
}

- (void)setAnchorPoint:(CGPoint)newAnchorPoint
{
  _bridge_prologue;
  _setToLayer(anchorPoint, newAnchorPoint);
}

- (CGPoint)position
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->position;
}

- (void)setPosition:(CGPoint)newPosition
{
  _bridge_prologue;
  _setToLayer(position, newPosition);
}

- (CGFloat)zPosition
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->zPosition;
}

- (void)setZPosition:(CGFloat)newPosition
{
  _bridge_prologue;
  _setToLayer(zPosition, newPosition);
}

- (CATransform3D)transform
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->transform;
}

- (void)setTransform:(CATransform3D)newTransform
{
  _bridge_prologue;
  _setToLayer(transform, newTransform);
}

- (CATransform3D)subnodeTransform
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->sublayerTransform;
}

- (void)setSubnodeTransform:(CATransform3D)newSubnodeTransform
{
  _bridge_prologue;
  _setToLayer(sublayerTransform, newSubnodeTransform);
}

- (id)contents
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->contents;
}

- (void)setContents:(id)newContents
{
  _bridge_prologue;
  _setToLayer(contents, newContents);
}

- (BOOL)isHidden
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->hidden;
}

- (void)setHidden:(BOOL)flag
{
  _bridge_prologue;
  _setToViewOrLayer(hidden, flag, hidden, flag);
}

- (BOOL)needsDisplayOnBoundsChange
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->needsDisplayOnBoundsChange;
}

- (void)setNeedsDisplayOnBoundsChange:(BOOL)flag
{
  _bridge_prologue;
  _setToLayer(needsDisplayOnBoundsChange, flag);
}

- (BOOL)autoresizesSubviews
{
  ASDisplayNodeAssert(!_flags.layerBacked, @"Danger: this property is undefined on layer-backed nodes.");
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->autoresizesSubviews;
}

- (void)setAutoresizesSubviews:(BOOL)flag
{
  _bridge_prologue;
  ASDisplayNodeAssert(!_flags.layerBacked, @"Danger: this property is undefined on layer-backed nodes.");
  _setToViewOnly(autoresizesSubviews, flag);
}

- (UIViewAutoresizing)autoresizingMask
{
  ASDisplayNodeAssert(!_flags.layerBacked, @"Danger: this property is undefined on layer-backed nodes.");
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->autoresizingMask;
}

- (void)setAutoresizingMask:(UIViewAutoresizing)mask
{
  _bridge_prologue;
  ASDisplayNodeAssert(!_flags.layerBacked, @"Danger: this property is undefined on layer-backed nodes.");
  _setToViewOnly(autoresizingMask, mask);
}

- (UIViewContentMode)contentMode
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->contentMode;
}

- (void)setContentMode:(UIViewContentMode)contentMode
{
  _bridge_prologue;
  if (__loaded) {
    if (_flags.layerBacked) {
      _layer.contentsGravity = ASDisplayNodeCAContentsGravityFromUIContentMode(contentMode);
    } else {
      _view.contentMode = contentMode;
    }
  } else {
    self.pendingViewState.contentMode = contentMode;
  }
}

- (UIColor *)backgroundColor
{
  ASDN::MutexLocker l(_propertyLock);
  return [UIColor colorWithCGColor:_pendingViewState->backgroundColor];
}

- (void)setBackgroundColor:(UIColor *)newBackgroundColor
{
  UIColor *prevBackgroundColor = self.backgroundColor;

  _bridge_prologue;
  _setToLayer(backgroundColor, newBackgroundColor.CGColor);

  // Note: This check assumes that the colors are within the same color space.
  if (!ASObjectIsEqual(prevBackgroundColor, newBackgroundColor)) {
    [self setNeedsDisplay];
  }
}

- (UIColor *)tintColor
{
  ASDisplayNodeAssert(!_flags.layerBacked, @"Danger: this property is undefined on layer-backed nodes.");
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->tintColor;
}

- (void)setTintColor:(UIColor *)color
{
    _bridge_prologue;
    ASDisplayNodeAssert(!_flags.layerBacked, @"Danger: this property is undefined on layer-backed nodes.");
    _setToViewOnly(tintColor, color);
}

- (void)tintColorDidChange
{
    // ignore this, allow subclasses to be notified
}

- (CGColorRef)shadowColor
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->shadowColor;
}

- (void)setShadowColor:(CGColorRef)colorValue
{
  _bridge_prologue;
  _setToLayer(shadowColor, colorValue);
}

- (CGFloat)shadowOpacity
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->shadowOpacity;
}

- (void)setShadowOpacity:(CGFloat)opacity
{
  _bridge_prologue;
  _setToLayer(shadowOpacity, opacity);
}

- (CGSize)shadowOffset
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->shadowOffset;
}

- (void)setShadowOffset:(CGSize)offset
{
  _bridge_prologue;
  _setToLayer(shadowOffset, offset);
}

- (CGFloat)shadowRadius
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->shadowRadius;
}

- (void)setShadowRadius:(CGFloat)radius
{
  _bridge_prologue;
  _setToLayer(shadowRadius, radius);
}

- (CGFloat)borderWidth
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->borderWidth;
}

- (void)setBorderWidth:(CGFloat)width
{
  _bridge_prologue;
  _setToLayer(borderWidth, width);
}

- (CGColorRef)borderColor
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->borderColor;
}

- (void)setBorderColor:(CGColorRef)colorValue
{
  _bridge_prologue;
  _setToLayer(borderColor, colorValue);
}

- (BOOL)allowsEdgeAntialiasing
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->allowsEdgeAntialiasing;
}

- (void)setAllowsEdgeAntialiasing:(BOOL)allowsEdgeAntialiasing
{
  _bridge_prologue;
  _setToLayer(allowsEdgeAntialiasing, allowsEdgeAntialiasing);
}

- (unsigned int)edgeAntialiasingMask
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->edgeAntialiasingMask;
}

- (void)setEdgeAntialiasingMask:(unsigned int)edgeAntialiasingMask
{
  _bridge_prologue;
  _setToLayer(edgeAntialiasingMask, edgeAntialiasingMask);
}

- (BOOL)isAccessibilityElement
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->isAccessibilityElement;
}

- (void)setIsAccessibilityElement:(BOOL)isAccessibilityElement
{
  _bridge_prologue;
  _setToViewOnly(isAccessibilityElement, isAccessibilityElement);
}

- (NSString *)accessibilityLabel
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->accessibilityLabel;
}

- (void)setAccessibilityLabel:(NSString *)accessibilityLabel
{
  _bridge_prologue;
  _setToViewOnly(accessibilityLabel, accessibilityLabel);
}

- (NSString *)accessibilityHint
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->accessibilityHint;
}

- (void)setAccessibilityHint:(NSString *)accessibilityHint
{
  _bridge_prologue;
  _setToViewOnly(accessibilityHint, accessibilityHint);
}

- (NSString *)accessibilityValue
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->accessibilityValue;
}

- (void)setAccessibilityValue:(NSString *)accessibilityValue
{
  _bridge_prologue;
  _setToViewOnly(accessibilityValue, accessibilityValue);
}

- (UIAccessibilityTraits)accessibilityTraits
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->accessibilityTraits;
}

- (void)setAccessibilityTraits:(UIAccessibilityTraits)accessibilityTraits
{
  _bridge_prologue;
  _setToViewOnly(accessibilityTraits, accessibilityTraits);
}

- (CGRect)accessibilityFrame
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->accessibilityFrame;
}

- (void)setAccessibilityFrame:(CGRect)accessibilityFrame
{
  _bridge_prologue;
  _setToViewOnly(accessibilityFrame, accessibilityFrame);
}

- (NSString *)accessibilityLanguage
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->accessibilityLanguage;
}

- (void)setAccessibilityLanguage:(NSString *)accessibilityLanguage
{
  _bridge_prologue;
  _setToViewOnly(accessibilityLanguage, accessibilityLanguage);
}

- (BOOL)accessibilityElementsHidden
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->accessibilityElementsHidden;
}

- (void)setAccessibilityElementsHidden:(BOOL)accessibilityElementsHidden
{
  _bridge_prologue;
  _setToViewOnly(accessibilityElementsHidden, accessibilityElementsHidden);
}

- (BOOL)accessibilityViewIsModal
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->accessibilityViewIsModal;
}

- (void)setAccessibilityViewIsModal:(BOOL)accessibilityViewIsModal
{
  _bridge_prologue;
  _setToViewOnly(accessibilityViewIsModal, accessibilityViewIsModal);
}

- (BOOL)shouldGroupAccessibilityChildren
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->shouldGroupAccessibilityChildren;
}

- (void)setShouldGroupAccessibilityChildren:(BOOL)shouldGroupAccessibilityChildren
{
  _bridge_prologue;
  _setToViewOnly(shouldGroupAccessibilityChildren, shouldGroupAccessibilityChildren);
}

- (NSString *)accessibilityIdentifier
{
  ASDN::MutexLocker l(_propertyLock);
  return _pendingViewState->accessibilityIdentifier;
}

- (void)setAccessibilityIdentifier:(NSString *)accessibilityIdentifier
{
  _bridge_prologue;
  _setToViewOnly(accessibilityIdentifier, accessibilityIdentifier);
}

@end


@implementation ASDisplayNode (ASAsyncTransactionContainer)

- (BOOL)asyncdisplaykit_isAsyncTransactionContainer
{
  _bridge_prologue;
  return _getFromViewOrLayer(asyncdisplaykit_isAsyncTransactionContainer, asyncdisplaykit_isAsyncTransactionContainer);
}

- (void)asyncdisplaykit_setAsyncTransactionContainer:(BOOL)asyncTransactionContainer
{
  _bridge_prologue;
  _setToViewOrLayer(asyncdisplaykit_asyncTransactionContainer, asyncTransactionContainer, asyncdisplaykit_asyncTransactionContainer, asyncTransactionContainer);
}

- (ASAsyncTransactionContainerState)asyncdisplaykit_asyncTransactionContainerState
{
  ASDisplayNodeAssertMainThread();
  return [_layer asyncdisplaykit_asyncTransactionContainerState];
}

- (void)asyncdisplaykit_cancelAsyncTransactions
{
  ASDisplayNodeAssertMainThread();
  [_layer asyncdisplaykit_cancelAsyncTransactions];
}

- (void)asyncdisplaykit_asyncTransactionContainerStateDidChange
{
}

@end
