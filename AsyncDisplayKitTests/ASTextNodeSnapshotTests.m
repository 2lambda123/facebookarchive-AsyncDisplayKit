//
//  ASTextNodeSnapshotTests.m
//  AsyncDisplayKit
//
//  Created by Garrett Moon on 8/12/16.
//  Copyright (c) 2014-present, Facebook, Inc.  All rights reserved.
//  This source code is licensed under the BSD-style license found in the
//  LICENSE file in the root directory of this source tree. An additional grant
//  of patent rights can be found in the PATENTS file in the same directory.
//

#import "ASSnapshotTestCase.h"
#import <AsyncDisplayKit/AsyncDisplayKit.h>
#import "ASLayout.h"

@interface ASTextNodeSnapshotTests : ASSnapshotTestCase

@end

@implementation ASTextNodeSnapshotTests

- (void)testTextContainerInset
{
  // trivial test case to ensure ASSnapshotTestCase works
  ASTextNode *textNode = [[ASTextNode alloc] init];
  textNode.attributedText = [[NSAttributedString alloc] initWithString:@"judar"
                                                            attributes:@{NSFontAttributeName : [UIFont italicSystemFontOfSize:24]}];
  textNode.textContainerInset = UIEdgeInsetsMake(0, 2, 0, 2);
  
  ASLayout *l = [textNode layoutThatFits:ASSizeRangeMake(CGSizeZero, CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX))];
  textNode.frame = (CGRect){.origin = {0, 0}, .size = l.size};
  
  ASSnapshotVerifyNode(textNode, nil);
}

- (void)testTextContainerInsetIsIncludedWithSmallerConstrainedSize
{
  UIView *backgroundView = [[UIView alloc] initWithFrame:CGRectZero];
  backgroundView.layer.as_allowsHighlightDrawing = YES;

  ASTextNode *textNode = [[ASTextNode alloc] init];
  textNode.attributedText = [[NSAttributedString alloc] initWithString:@"judar judar judar judar judar judar"
                                                            attributes:@{ NSFontAttributeName : [UIFont systemFontOfSize:30] }];
  textNode.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
  
  ASLayout *l = [textNode layoutThatFits:ASSizeRangeMake(CGSizeZero, CGSizeMake(100, 80))];
  textNode.frame = CGRectMake(50, 50, l.size.width, l.size.height);

  [backgroundView addSubview:textNode.view];
  backgroundView.frame = UIEdgeInsetsInsetRect(textNode.bounds, UIEdgeInsetsMake(-50, -50, -50, -50));

  textNode.highlightRange = NSMakeRange(0, textNode.attributedText.length);

  [ASSnapshotTestCase hackilySynchronouslyRecursivelyRenderNode:textNode];
  ASSnapshotVerifyLayer(backgroundView.layer, nil);
}

- (void)testTextContainerInsetHighlight
{
  UIView *backgroundView = [[UIView alloc] initWithFrame:CGRectZero];
  backgroundView.layer.as_allowsHighlightDrawing = YES;

  ASTextNode *textNode = [[ASTextNode alloc] init];
  textNode.attributedText = [[NSAttributedString alloc] initWithString:@"yolo"
                                                            attributes:@{ NSFontAttributeName : [UIFont systemFontOfSize:30] }];
  textNode.textContainerInset = UIEdgeInsetsMake(5, 10, 10, 5);

  ASLayout *l = [textNode layoutThatFits:ASSizeRangeMake(CGSizeZero, CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX))];
  textNode.frame = CGRectMake(50, 50, l.size.width, l.size.height);

  [backgroundView addSubview:textNode.view];
  backgroundView.frame = UIEdgeInsetsInsetRect(textNode.bounds, UIEdgeInsetsMake(-50, -50, -50, -50));

  textNode.highlightRange = NSMakeRange(0, textNode.attributedText.length);

  [ASSnapshotTestCase hackilySynchronouslyRecursivelyRenderNode:textNode];
  ASSnapshotVerifyView(backgroundView, nil);
}

// This test is disabled because the fast-path is disabled.
- (void)DISABLED_testThatFastPathTruncationWorks
{
  ASTextNode *textNode = [[ASTextNode alloc] init];
  textNode.attributedText = [[NSAttributedString alloc] initWithString:@"Quality is Important" attributes:@{ NSForegroundColorAttributeName: [UIColor blueColor], NSFontAttributeName: [UIFont italicSystemFontOfSize:24] }];
  ASLayout *l = [textNode layoutThatFits:ASSizeRangeMake(CGSizeZero, CGSizeMake(100, 50))];
  textNode.frame = CGRectMake(0, 0, l.size.width, l.size.height);
  
  ASSnapshotVerifyNode(textNode, nil);
}

- (void)testThatSlowPathTruncationWorks
{
  ASTextNode *textNode = [[ASTextNode alloc] init];
  textNode.attributedText = [[NSAttributedString alloc] initWithString:@"Quality is Important" attributes:@{ NSForegroundColorAttributeName: [UIColor blueColor], NSFontAttributeName: [UIFont italicSystemFontOfSize:24] }];

  ASLayout *l = [textNode layoutThatFits:ASSizeRangeMake(CGSizeZero, CGSizeMake(100, 50))];
  textNode.frame = CGRectMake(0, 0, l.size.width, l.size.height);
  
  // Set exclusion paths to trigger slow path
  textNode.exclusionPaths = @[ [UIBezierPath bezierPath] ];
  [textNode layoutThatFits:ASSizeRangeMake(CGSizeZero, CGSizeMake(100, 50))];
  ASSnapshotVerifyNode(textNode, nil);
}

- (void)testShadowing
{
  ASTextNode *textNode = [[ASTextNode alloc] init];
  textNode.attributedText = [[NSAttributedString alloc] initWithString:@"Quality is Important"];
  textNode.shadowColor = [UIColor blackColor].CGColor;
  textNode.shadowOpacity = 0.3;
  textNode.shadowRadius = 3;
  textNode.shadowOffset = CGSizeMake(0, 1);
  ASLayout *l = [textNode layoutThatFits:ASSizeRangeMake(CGSizeZero, CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX))];
  textNode.frame = CGRectMake(0, 0, l.size.width, l.size.height);
  
  
  ASSnapshotVerifyNode(textNode, nil);
}

@end
