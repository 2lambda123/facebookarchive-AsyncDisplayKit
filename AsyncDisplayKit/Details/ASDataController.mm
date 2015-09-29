/* Copyright (c) 2014-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "ASDataController.h"

#import <Foundation/NSProcessInfo.h>

#import "ASAssert.h"
#import "ASCellNode.h"
#import "ASDisplayNode.h"
#import "ASMultidimensionalArrayUtils.h"
#import "ASDisplayNodeInternal.h"
#import "ASInternalHelpers.h"

//#define LOG(...) NSLog(__VA_ARGS__)
#define LOG(...)

typedef void (^EditCommandBlock)(NSMutableIndexSet *deletedSections, NSMutableIndexSet *insertedSections, NSMutableIndexSet *reloadedSections, NSMutableArray *insertedItems, NSMutableArray *deletedItems, NSMutableArray *reloadedItems);
const static NSUInteger kASDataControllerSizingCountPerProcessor = 5;

static void *kASSizingQueueContext = &kASSizingQueueContext;

@interface ASDataController () {
  NSMutableArray *_externalCompletedNodes;    // Main thread only.  External data access can immediately query this if available.
  NSMutableArray *_completedNodes;            // Main thread only.  External data access can immediately query this if _externalCompletedNodes is unavailable.
  NSMutableArray *_editingNodes;              // Modified on _editingTransactionQueue only.  Updates propogated to _completedNodes.
  
  NSMutableArray *_pendingEditCommandBlocks;  // To be run on the main thread.  Handles begin/endUpdates tracking.
  NSOperationQueue *_editingTransactionQueue; // Serial background queue.  Dispatches concurrent layout and manages _editingNodes.
  
  BOOL _asyncDataFetchingEnabled;
  BOOL _delegateDidInsertNodes;
  BOOL _delegateDidDeleteNodes;
  BOOL _delegateDidInsertSections;
  BOOL _delegateDidDeleteSections;
}

@property (atomic, assign) NSUInteger batchUpdateCounter;

@end

@implementation ASDataController

#pragma mark - Lifecycle

- (instancetype)initWithAsyncDataFetching:(BOOL)asyncDataFetchingEnabled
{
  if (!(self = [super init])) {
    return nil;
  }
  
  _completedNodes = [NSMutableArray array];
  _editingNodes = [NSMutableArray array];

  _pendingEditCommandBlocks = [NSMutableArray array];
  
  _editingTransactionQueue = [[NSOperationQueue alloc] init];
  _editingTransactionQueue.maxConcurrentOperationCount = 1; // Serial queue
  _editingTransactionQueue.name = @"org.AsyncDisplayKit.ASDataController.editingTransactionQueue";
  
  _batchUpdateCounter = 0;
  _asyncDataFetchingEnabled = asyncDataFetchingEnabled;
  
  return self;
}

- (void)setDelegate:(id<ASDataControllerDelegate>)delegate
{
  if (_delegate == delegate) {
    return;
  }
  
  _delegate = delegate;
  
  // Interrogate our delegate to understand its capabilities, optimizing away expensive respondsToSelector: calls later.
  _delegateDidInsertNodes     = [_delegate respondsToSelector:@selector(dataController:didInsertNodes:atIndexPaths:withAnimationOptions:)];
  _delegateDidDeleteNodes     = [_delegate respondsToSelector:@selector(dataController:didDeleteNodes:atIndexPaths:withAnimationOptions:)];
  _delegateDidInsertSections  = [_delegate respondsToSelector:@selector(dataController:didInsertSections:atIndexSet:withAnimationOptions:)];
  _delegateDidDeleteSections  = [_delegate respondsToSelector:@selector(dataController:didDeleteSectionsAtIndexSet:withAnimationOptions:)];
}

+ (NSUInteger)parallelProcessorCount
{
  static NSUInteger parallelProcessorCount;

  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    parallelProcessorCount = [[NSProcessInfo processInfo] processorCount];
  });

  return parallelProcessorCount;
}

#pragma mark - Cell Layout

- (void)_layoutNodes:(NSArray *)nodes atIndexPaths:(NSArray *)indexPaths withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  ASDisplayNodeAssert([NSOperationQueue currentQueue] == _editingTransactionQueue, @"Cell node layout must be initiated from edit transaction queue");
  
  if (!nodes.count) {
    return;
  }
  
  dispatch_group_t layoutGroup = dispatch_group_create();
  
  for (NSUInteger j = 0; j < nodes.count && j < indexPaths.count; j += kASDataControllerSizingCountPerProcessor) {
    NSArray *subIndexPaths = [indexPaths subarrayWithRange:NSMakeRange(j, MIN(kASDataControllerSizingCountPerProcessor, indexPaths.count - j))];
    
    //TODO: There should be a fast-path that avoids all of this object creation.
    NSMutableArray *nodeBoundSizes = [[NSMutableArray alloc] initWithCapacity:kASDataControllerSizingCountPerProcessor];
    [subIndexPaths enumerateObjectsUsingBlock:^(NSIndexPath *indexPath, NSUInteger idx, BOOL *stop) {
      ASSizeRange constrainedSize = [_dataSource dataController:self constrainedSizeForNodeAtIndexPath:indexPath];
      [nodeBoundSizes addObject:[NSValue valueWithBytes:&constrainedSize objCType:@encode(ASSizeRange)]];
    }];
    
    dispatch_group_async(layoutGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      [subIndexPaths enumerateObjectsUsingBlock:^(NSIndexPath *indexPath, NSUInteger idx, BOOL *stop) {
        ASCellNode *node = nodes[j + idx];
        ASSizeRange constrainedSize;
        [nodeBoundSizes[idx] getValue:&constrainedSize];
        [node measureWithSizeRange:constrainedSize];
        node.frame = CGRectMake(0.0f, 0.0f, node.calculatedSize.width, node.calculatedSize.height);
      }];
    });
  }
  
  // Block the _editingTransactionQueue from executing a new edit transaction until layout is done & _editingNodes array is updated.
  dispatch_group_wait(layoutGroup, DISPATCH_TIME_FOREVER);
  
  // Insert finished nodes into data storage
  [self _insertNodes:nodes atIndexPaths:indexPaths withAnimationOptions:animationOptions];
}

- (void)_batchLayoutNodes:(NSArray *)nodes atIndexPaths:(NSArray *)indexPaths withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  NSUInteger blockSize = [[ASDataController class] parallelProcessorCount] * kASDataControllerSizingCountPerProcessor;
  
  // Processing in batches
  for (NSUInteger i = 0; i < indexPaths.count; i += blockSize) {
    NSRange batchedRange = NSMakeRange(i, MIN(indexPaths.count - i, blockSize));
    NSArray *batchedIndexPaths = [indexPaths subarrayWithRange:batchedRange];
    NSArray *batchedNodes = [nodes subarrayWithRange:batchedRange];
    
    [self _layoutNodes:batchedNodes atIndexPaths:batchedIndexPaths withAnimationOptions:animationOptions];
  }
}

#pragma mark - Internal Data Querying + Editing

- (void)_insertNodes:(NSArray *)nodes atIndexPaths:(NSArray *)indexPaths withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  if (indexPaths.count == 0)
    return;
  ASInsertElementsIntoMultidimensionalArrayAtIndexPaths(_editingNodes, indexPaths, nodes);
  
  // Deep copy is critical here, or future edits to the sub-arrays will pollute state between _editing and _complete on different threads.
  NSMutableArray *completedNodes = (NSMutableArray *)ASMultidimensionalArrayDeepMutableCopy(_editingNodes);
  
  ASDisplayNodePerformBlockOnMainThread(^{
    _completedNodes = completedNodes;
    if (_delegateDidInsertNodes)
      [_delegate dataController:self didInsertNodes:nodes atIndexPaths:indexPaths withAnimationOptions:animationOptions];
  });
}

- (void)_deleteNodesAtIndexPaths:(NSArray *)indexPaths withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  if (indexPaths.count == 0)
    return;
  LOG(@"_deleteNodesAtIndexPaths:%@, full index paths in _editingNodes = %@", indexPaths, ASIndexPathsForMultidimensionalArray(_editingNodes));
  ASDeleteElementsInMultidimensionalArrayAtIndexPaths(_editingNodes, indexPaths);

  ASDisplayNodePerformBlockOnMainThread(^{
    NSArray *nodes = ASFindElementsInMultidimensionalArrayAtIndexPaths(_completedNodes, indexPaths);
    ASDeleteElementsInMultidimensionalArrayAtIndexPaths(_completedNodes, indexPaths);
    if (_delegateDidDeleteNodes)
      [_delegate dataController:self didDeleteNodes:nodes atIndexPaths:indexPaths withAnimationOptions:animationOptions];
  });
}

- (void)_insertSections:(NSMutableArray *)sections atIndexSet:(NSIndexSet *)indexSet withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  if (indexSet.count == 0)
    return;
  [_editingNodes insertObjects:sections atIndexes:indexSet];
  
  // Deep copy is critical here, or future edits to the sub-arrays will pollute state between _editing and _complete on different threads.
  NSArray *sectionsForCompleted = (NSMutableArray *)ASMultidimensionalArrayDeepMutableCopy(sections);
  
  ASDisplayNodePerformBlockOnMainThread(^{
    [_completedNodes insertObjects:sectionsForCompleted atIndexes:indexSet];
    if (_delegateDidInsertSections)
      [_delegate dataController:self didInsertSections:sections atIndexSet:indexSet withAnimationOptions:animationOptions];
  });
}

- (void)_deleteSectionsAtIndexSet:(NSIndexSet *)indexSet withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  if (indexSet.count == 0)
    return;
  [_editingNodes removeObjectsAtIndexes:indexSet];
  ASDisplayNodePerformBlockOnMainThread(^{
    [_completedNodes removeObjectsAtIndexes:indexSet];
    if (_delegateDidDeleteSections)
      [_delegate dataController:self didDeleteSectionsAtIndexSet:indexSet withAnimationOptions:animationOptions];
  });
}

#pragma mark - Initial Load & Full Reload (External API)

- (void)initialDataLoadingWithAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  [self accessDataSourceWithBlock:^{
    NSUInteger sectionNum = [_dataSource dataControllerNumberOfSections:self];
    [self insertSections:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, sectionNum)] withAnimationOptions:0];
  }];
}

- (void)reloadDataWithAnimationOptions:(ASDataControllerAnimationOptions)animationOptions completion:(void (^)())completion
{
  [self performEditCommandWithBlock:^{
    ASDisplayNodeAssertMainThread();
    [_editingTransactionQueue waitUntilAllOperationsAreFinished];

    [self accessDataSourceWithBlock:^{
      NSUInteger sectionCount = [_dataSource dataControllerNumberOfSections:self];
      NSMutableArray *updatedNodes = [NSMutableArray array];
      NSMutableArray *updatedIndexPaths = [NSMutableArray array];
      [self _populateFromEntireDataSourceWithMutableNodes:updatedNodes mutableIndexPaths:updatedIndexPaths];
      
      [_editingTransactionQueue addOperationWithBlock:^{
        LOG(@"Edit Transaction - reloadData");
        
        // Remove everything that existed before the reload, now that we're ready to insert replacements
        NSArray *indexPaths = ASIndexPathsForMultidimensionalArray(_editingNodes);
        [self _deleteNodesAtIndexPaths:indexPaths withAnimationOptions:animationOptions];
        
        NSMutableIndexSet *indexSet = [[NSMutableIndexSet alloc] initWithIndexesInRange:NSMakeRange(0, _editingNodes.count)];
        [self _deleteSectionsAtIndexSet:indexSet withAnimationOptions:animationOptions];
        
        // Insert each section
        NSMutableArray *sections = [NSMutableArray arrayWithCapacity:sectionCount];
        for (int i = 0; i < sectionCount; i++) {
          [sections addObject:[[NSMutableArray alloc] init]];
        }
        
        [self _insertSections:sections atIndexSet:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, sectionCount)] withAnimationOptions:animationOptions];
        
        [self _batchLayoutNodes:updatedNodes atIndexPaths:updatedIndexPaths withAnimationOptions:animationOptions];
        
        if (completion) {
          dispatch_async(dispatch_get_main_queue(), completion);
        }
      }];
    }];
  }];
}

#pragma mark - Data Source Access (Calling _dataSource)

- (void)accessDataSourceWithBlock:(dispatch_block_t)block
{
  if (_asyncDataFetchingEnabled) {
    [_dataSource dataControllerLockDataSource];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
      block();
      [_dataSource dataControllerUnlockDataSource];
    });
  } else {
    [_dataSource dataControllerLockDataSource];
    block();
    [_dataSource dataControllerUnlockDataSource];
  }
}

- (void)_populateFromDataSourceWithSectionIndexSet:(NSIndexSet *)indexSet mutableNodes:(NSMutableArray *)nodes mutableIndexPaths:(NSMutableArray *)indexPaths
{
  [indexSet enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
    NSUInteger rowNum = [_dataSource dataController:self rowsInSection:idx];
    
    NSIndexPath *sectionIndex = [[NSIndexPath alloc] initWithIndex:idx];
    for (NSUInteger i = 0; i < rowNum; i++) {
      NSIndexPath *indexPath = [sectionIndex indexPathByAddingIndex:i];
      [indexPaths addObject:indexPath];
      [nodes addObject:[_dataSource dataController:self nodeAtIndexPath:indexPath]];
    }
  }];
}

- (void)_populateFromEntireDataSourceWithMutableNodes:(NSMutableArray *)nodes mutableIndexPaths:(NSMutableArray *)indexPaths
{
  NSUInteger sectionNum = [_dataSource dataControllerNumberOfSections:self];
  for (NSUInteger i = 0; i < sectionNum; i++) {
    NSIndexPath *sectionIndexPath = [[NSIndexPath alloc] initWithIndex:i];
    
    NSUInteger rowNum = [_dataSource dataController:self rowsInSection:i];
    for (NSUInteger j = 0; j < rowNum; j++) {
      NSIndexPath *indexPath = [sectionIndexPath indexPathByAddingIndex:j];
      [indexPaths addObject:indexPath];
      [nodes addObject:[_dataSource dataController:self nodeAtIndexPath:indexPath]];
    }
  }
}


#pragma mark - Batching (External API)

- (void)beginUpdates
{
  [_editingTransactionQueue waitUntilAllOperationsAreFinished];
  // Begin queuing up edit calls that happen on the main thread.
  // This will prevent further operations from being scheduled on _editingTransactionQueue.
  _batchUpdateCounter++;
}

- (void)endUpdates
{
  [self endUpdatesAnimated:YES completion:nil];
}

- (void)endUpdatesAnimated:(BOOL)animated completion:(void (^)(BOOL))completion
{
  _batchUpdateCounter--;

  if (_batchUpdateCounter == 0) {
    LOG(@"endUpdatesWithCompletion - beginning");

    [_editingTransactionQueue addOperationWithBlock:^{
      ASDisplayNodePerformBlockOnMainThread(^{
        // Deep copy _completedNodes to _externalCompletedNodes.
        // Any external queries from now on will be done on _externalCompletedNodes, to guarantee data consistency with the delegate.
        _externalCompletedNodes = (NSMutableArray *)ASMultidimensionalArrayDeepMutableCopy(_completedNodes);

        LOG(@"endUpdatesWithCompletion - begin updates call to delegate");
        [_delegate dataControllerBeginUpdates:self];
      });
    }];

    // Running these commands may result in blocking on an _editingTransactionQueue operation that started even before -beginUpdates.
    // Each subsequent command in the queue will also wait on the full asynchronous completion of the prior command's edit transaction.
    LOG(@"endUpdatesWithCompletion - %zd blocks to run", _pendingEditCommandBlocks.count);
    NSMutableIndexSet *deletedSections = [NSMutableIndexSet new];
    NSMutableIndexSet *insertedSections = [NSMutableIndexSet new];
    NSMutableIndexSet *reloadedSections = [NSMutableIndexSet new];
    NSMutableArray *reloadedItems = [NSMutableArray new];
    NSMutableArray *insertedItems = [NSMutableArray new];
    NSMutableArray *deletedItems = [NSMutableArray new];
    [_pendingEditCommandBlocks enumerateObjectsUsingBlock:^(EditCommandBlock block, NSUInteger idx, BOOL *stop) {
      LOG(@"endUpdatesWithCompletion - running block #%zd", idx);
      block(deletedSections, insertedSections, reloadedSections, insertedItems, deletedItems, reloadedItems);
    }];
    [_pendingEditCommandBlocks removeAllObjects];
    
    NSPredicate *sectionNotDeleted = [NSPredicate predicateWithBlock:^(NSIndexPath *indexPath, __unused NSDictionary *_) {
      return ![deletedSections containsIndex:indexPath.section];
    }];
    NSPredicate *sectionNotInserted = [NSPredicate predicateWithBlock:^(NSIndexPath *indexPath, __unused NSDictionary *_) {
      return ![insertedSections containsIndex:indexPath.section];
    }];
    [deletedItems filterUsingPredicate:sectionNotDeleted];
    [deletedItems sortUsingSelector:@selector(as_inverseCompare:)];
    [insertedItems filterUsingPredicate:sectionNotInserted];
    [insertedItems sortUsingSelector:@selector(compare:)];
    
    // FIXME: Per-update animation options
    ASDataControllerAnimationOptions animationOptions = 0;
    
    [self accessDataSourceWithBlock:^{
      
      if (reloadedSections.count > 0) { // Reloaded sections
        LOG(@"Edit Command - reloadSections: %@", reloadedSections);
        
        [_editingTransactionQueue waitUntilAllOperationsAreFinished];
        
        [self accessDataSourceWithBlock:^{
          NSMutableArray *updatedNodes = [NSMutableArray array];
          NSMutableArray *updatedIndexPaths = [NSMutableArray array];
          [self _populateFromDataSourceWithSectionIndexSet:reloadedSections mutableNodes:updatedNodes mutableIndexPaths:updatedIndexPaths];
          
          // Dispatch to sizing queue in order to guarantee that any in-progress sizing operations from prior edits have completed.
          // For example, if an initial -reloadData call is quickly followed by -reloadSections, sizing the initial set may not be done
          // at this time.  Thus _editingNodes could be empty and crash in ASIndexPathsForMultidimensional[...]
          
          [_editingTransactionQueue addOperationWithBlock:^{
            NSArray *indexPaths = ASIndexPathsForMultidimensionalArrayAtIndexSet(_editingNodes, reloadedSections);
            
            LOG(@"Edit Transaction - reloadSections: updatedIndexPaths: %@, indexPaths: %@, _editingNodes: %@", updatedIndexPaths, indexPaths, ASIndexPathsForMultidimensionalArray(_editingNodes));
            
            [self _deleteNodesAtIndexPaths:indexPaths withAnimationOptions:animationOptions];
            
            // reinsert the elements
            [self _batchLayoutNodes:updatedNodes atIndexPaths:updatedIndexPaths withAnimationOptions:animationOptions];
          }];
        }];
      }
      
      if (reloadedItems.count > 0) { // Reloaded items
        LOG(@"Edit Command - reloadRows: %@", reloadedItems);
        NSMutableArray *nodes = [[NSMutableArray alloc] initWithCapacity:reloadedItems.count];
        for (NSIndexPath *indexPath in reloadedItems) {
          [nodes addObject:[_dataSource dataController:self nodeAtIndexPath:indexPath]];
        }
        [_editingTransactionQueue waitUntilAllOperationsAreFinished];
        
        [_editingTransactionQueue addOperationWithBlock:^{
          LOG(@"Edit Transaction - reloadRows: %@", reloadedItems);
          [self _deleteNodesAtIndexPaths:reloadedItems withAnimationOptions:animationOptions];
          [self _batchLayoutNodes:nodes atIndexPaths:reloadedItems withAnimationOptions:animationOptions];
        }];
      }
      
      if (deletedItems.count > 0) { // Deleted items, descending
        [_editingTransactionQueue waitUntilAllOperationsAreFinished];
        
        [_editingTransactionQueue addOperationWithBlock:^{
          LOG(@"Edit Transaction - deleteRows: %@", indexPaths);
          [self _deleteNodesAtIndexPaths:deletedItems withAnimationOptions:animationOptions];
        }];
      }
      
      if (deletedSections.count > 0) { // Deleted sections
        LOG(@"Edit Command - deleteSections: %@", deletedSections);
        [_editingTransactionQueue waitUntilAllOperationsAreFinished];
        
        [_editingTransactionQueue addOperationWithBlock:^{
          // remove elements
          LOG(@"Edit Transaction - deleteSections: %@", deletedSections);
          NSArray *indexPaths = ASIndexPathsForMultidimensionalArrayAtIndexSet(_editingNodes, deletedSections);
          
          [self _deleteNodesAtIndexPaths:indexPaths withAnimationOptions:animationOptions];
          [self _deleteSectionsAtIndexSet:deletedSections withAnimationOptions:animationOptions];
        }];
      }
      
      if (insertedSections.count > 0) { // Inserted sections
        LOG(@"Edit Command - insertSections: %@", insertedSections);
        [_editingTransactionQueue waitUntilAllOperationsAreFinished];
        
        NSMutableArray *updatedNodes = [NSMutableArray array];
        NSMutableArray *updatedIndexPaths = [NSMutableArray array];
        [self _populateFromDataSourceWithSectionIndexSet:insertedSections mutableNodes:updatedNodes mutableIndexPaths:updatedIndexPaths];
        
        [_editingTransactionQueue addOperationWithBlock:^{
          LOG(@"Edit Transaction - insertSections: %@", indexSet);
          NSMutableArray *sectionArray = [NSMutableArray arrayWithCapacity:insertedSections.count];
          
          for (NSUInteger i = 0; i < insertedSections.count; i++) {
            [sectionArray addObject:[NSMutableArray array]];
          }
          
          [self _insertSections:sectionArray atIndexSet:insertedSections withAnimationOptions:animationOptions];
          [self _batchLayoutNodes:updatedNodes atIndexPaths:updatedIndexPaths withAnimationOptions:animationOptions];
        }];
      }

      if (insertedItems.count > 0) { // Inserted items, ascending
        LOG(@"Edit Command - insertRows: %@", insertedItems);
        
        [_editingTransactionQueue waitUntilAllOperationsAreFinished];
        
        NSMutableArray *nodes = [[NSMutableArray alloc] initWithCapacity:insertedItems.count];
        for (NSIndexPath *indexPath in insertedItems) {
          [nodes addObject:[_dataSource dataController:self nodeAtIndexPath:indexPath]];
        }
        
        [_editingTransactionQueue addOperationWithBlock:^{
          LOG(@"Edit Transaction - insertRows: %@", insertedItems);
          [self _batchLayoutNodes:nodes atIndexPaths:insertedItems withAnimationOptions:animationOptions];
        }];
      }
      
    }];
    
    [_editingTransactionQueue addOperationWithBlock:^{
      ASDisplayNodePerformBlockOnMainThread(^{
        // Now that the transaction is done, _completedNodes can be accessed externally again.
        _externalCompletedNodes = nil;
        
        LOG(@"endUpdatesWithCompletion - calling delegate end");
        [_delegate dataController:self endUpdatesAnimated:animated completion:completion];
      });
    }];
  }
}

// FIXME: Nonsense name while we port
- (void)performEditCommandWithBlockNew:(EditCommandBlock)block
{
  if (_batchUpdateCounter == 0) {
    [self beginUpdates];
    [self performEditCommandWithBlockNew:block];
    [self endUpdates];
  } else {
    [_pendingEditCommandBlocks addObject:block];
  }
}

- (void)performEditCommandWithBlock:(void (^)(void))block
{
  // This method needs to block the thread and synchronously perform the operation if we are not
  // queuing commands for begin/endUpdates.  If we are queuing, it needs to return immediately.
  if (_batchUpdateCounter == 0) {
    block();
  } else {
    [_pendingEditCommandBlocks addObject:block];
  }
}

#pragma mark - Section Editing (External API)

- (void)insertSections:(NSIndexSet *)indexSet withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  [self performEditCommandWithBlockNew:^(NSMutableIndexSet *deletedSections, NSMutableIndexSet *insertedSections, NSMutableIndexSet *reloadedSections, NSMutableArray *insertedItems, NSMutableArray *deletedItems, NSMutableArray *reloadedItems) {
    [insertedSections addIndexes:indexSet];
  }];
}

- (void)deleteSections:(NSIndexSet *)indexSet withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  [self performEditCommandWithBlockNew:^(NSMutableIndexSet *deletedSections, NSMutableIndexSet *insertedSections, NSMutableIndexSet *reloadedSections, NSMutableArray *insertedItems, NSMutableArray *deletedItems, NSMutableArray *reloadedItems) {
    [deletedSections addIndexes:indexSet];
  }];
}

- (void)reloadSections:(NSIndexSet *)sections withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  [self performEditCommandWithBlockNew:^(NSMutableIndexSet *deletedSections, NSMutableIndexSet *insertedSections, NSMutableIndexSet *reloadedSections, NSMutableArray *insertedItems, NSMutableArray *deletedItems, NSMutableArray *reloadedItems) {
    [reloadedSections addIndexes:sections];
  }];
}

- (void)moveSection:(NSInteger)section toSection:(NSInteger)newSection withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  [self performEditCommandWithBlockNew:^(NSMutableIndexSet *deletedSections, NSMutableIndexSet *insertedSections, NSMutableIndexSet *reloadedSections, NSMutableArray *insertedItems, NSMutableArray *deletedItems, NSMutableArray *reloadedItems) {
    [deletedSections addIndex:section];
    [insertedSections addIndex:newSection];
  }];
}

#pragma mark - Row Editing (External API)

- (void)insertRowsAtIndexPaths:(NSArray *)indexPaths withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  [self performEditCommandWithBlockNew:^(NSMutableIndexSet *deletedSections, NSMutableIndexSet *insertedSections, NSMutableIndexSet *reloadedSections, NSMutableArray *insertedItems, NSMutableArray *deletedItems, NSMutableArray *reloadedItems) {
    [insertedItems addObjectsFromArray:indexPaths];
  }];
}

- (void)deleteRowsAtIndexPaths:(NSArray *)indexPaths withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  [self performEditCommandWithBlockNew:^(NSMutableIndexSet *deletedSections, NSMutableIndexSet *insertedSections, NSMutableIndexSet *reloadedSections, NSMutableArray *insertedItems, NSMutableArray *deletedItems, NSMutableArray *reloadedItems) {
    [deletedItems addObjectsFromArray:indexPaths];
  }];
}

- (void)reloadRowsAtIndexPaths:(NSArray *)indexPaths withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  [self performEditCommandWithBlockNew:^(NSMutableIndexSet *deletedSections, NSMutableIndexSet *insertedSections, NSMutableIndexSet *reloadedSections, NSMutableArray *insertedItems, NSMutableArray *deletedItems, NSMutableArray *reloadedItems) {
    [reloadedItems addObjectsFromArray:indexPaths];
  }];
}

- (void)relayoutAllRows
{
  [self performEditCommandWithBlock:^{
    ASDisplayNodeAssertMainThread();
    LOG(@"Edit Command - relayoutRows");
    [_editingTransactionQueue waitUntilAllOperationsAreFinished];
    
    void (^relayoutNodesBlock)(NSMutableArray *) = ^void(NSMutableArray *nodes) {
      if (!nodes.count) {
        return;
      }
      
      [self accessDataSourceWithBlock:^{
        [nodes enumerateObjectsUsingBlock:^(NSMutableArray *section, NSUInteger sectionIndex, BOOL *stop) {
          [section enumerateObjectsUsingBlock:^(ASCellNode *node, NSUInteger rowIndex, BOOL *stop) {
            NSIndexPath *indexPath = [NSIndexPath indexPathForRow:rowIndex inSection:sectionIndex];
            ASSizeRange constrainedSize = [_dataSource dataController:self constrainedSizeForNodeAtIndexPath:indexPath];
            [node measureWithSizeRange:constrainedSize];
            node.frame = CGRectMake(0.0f, 0.0f, node.calculatedSize.width, node.calculatedSize.height);
          }];
        }];
      }];
    };

    // Can't relayout right away because _completedNodes may not be up-to-date,
    // i.e there might be some nodes that were measured using the old constrained size but haven't been added to _completedNodes
    // (see _layoutNodes:atIndexPaths:withAnimationOptions:).
    [_editingTransactionQueue addOperationWithBlock:^{
      ASDisplayNodePerformBlockOnMainThread(^{
        relayoutNodesBlock(_completedNodes);
      });
    }];
  }];
}

- (void)moveRowAtIndexPath:(NSIndexPath *)indexPath toIndexPath:(NSIndexPath *)newIndexPath withAnimationOptions:(ASDataControllerAnimationOptions)animationOptions
{
  [self performEditCommandWithBlockNew:^(NSMutableIndexSet *deletedSections, NSMutableIndexSet *insertedSections, NSMutableIndexSet *reloadedSections, NSMutableArray *insertedItems, NSMutableArray *deletedItems, NSMutableArray *reloadedItems) {
    [deletedItems addObject:indexPath];
    [insertedItems addObject:newIndexPath];
  }];
}

#pragma mark - Data Querying (External API)

- (NSUInteger)numberOfSections
{
  ASDisplayNodeAssertMainThread();
  return [[self completedNodes] count];
}

- (NSUInteger)numberOfRowsInSection:(NSUInteger)section
{
  ASDisplayNodeAssertMainThread();
  return [[self completedNodes][section] count];
}

- (ASCellNode *)nodeAtIndexPath:(NSIndexPath *)indexPath
{
  ASDisplayNodeAssertMainThread();
  return [self completedNodes][indexPath.section][indexPath.row];
}

- (NSIndexPath *)indexPathForNode:(ASCellNode *)cellNode;
{
  ASDisplayNodeAssertMainThread();

  NSArray *nodes = [self completedNodes];
  NSUInteger numberOfNodes = nodes.count;
  
  // Loop through each section to look for the cellNode
  for (NSUInteger i = 0; i < numberOfNodes; i++) {
    NSArray *sectionNodes = nodes[i];
    NSUInteger cellIndex = [sectionNodes indexOfObjectIdenticalTo:cellNode];
    if (cellIndex != NSNotFound) {
      return [NSIndexPath indexPathForRow:cellIndex inSection:i];
    }
  }
  
  return nil;
}

- (NSArray *)nodesAtIndexPaths:(NSArray *)indexPaths
{
  ASDisplayNodeAssertMainThread();
  return ASFindElementsInMultidimensionalArrayAtIndexPaths((NSMutableArray *)[self completedNodes], [indexPaths sortedArrayUsingSelector:@selector(compare:)]);
}

/// Returns nodes that can be queried externally. _externalCompletedNodes is used if available, _completedNodes otherwise.
- (NSArray *)completedNodes
{
  ASDisplayNodeAssertMainThread();
  return _externalCompletedNodes != nil ? _externalCompletedNodes : _completedNodes;
}

#pragma mark - Dealloc

- (void)dealloc
{
  ASDisplayNodeAssertMainThread();
  [_completedNodes enumerateObjectsUsingBlock:^(NSMutableArray *section, NSUInteger sectionIndex, BOOL *stop) {
    [section enumerateObjectsUsingBlock:^(ASCellNode *node, NSUInteger rowIndex, BOOL *stop) {
      if (node.isNodeLoaded) {
        if (node.layerBacked) {
          [node.layer removeFromSuperlayer];
        } else {
          [node.view removeFromSuperview];
        }
      }
    }];
  }];
}

@end
