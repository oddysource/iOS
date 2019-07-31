
#import "SearchOperation.h"
#import "MEGASdkManager.h"
#import "MEGANodeList+MNZCategory.h"

@interface SearchOperation ()

@property (strong, nonatomic) MEGANode *parentNode;
@property (strong, nonatomic) NSString *text;
@property (copy, nonatomic) void (^completion)(NSArray <MEGANode *> *nodesFound);

@end

@implementation SearchOperation

- (instancetype)initWithParentNode:(MEGANode *)parentNode text:(NSString *)text completion:(void (^)(NSArray  <MEGANode *> *_Nullable))completion {
    self = super.init;
    if (self) {
        _parentNode = parentNode;
        _text = text;
        _completion = completion;
    }
    return self;
}

- (void)start {
    if (self.isCancelled) {
        [self finishOperation];
        if (self.completion) {
            self.completion(nil);
        }
        return;
    }
    
    [self startExecuting];
    
#ifdef DEBUG
    MEGALogInfo(@"[Search] \"%@\" starts", self.text);
#else
    MEGALogInfo(@"[Search] starts", self.text);
#endif
    
    MEGANodeList *nodeListFound = [MEGASdkManager.sharedMEGASdk nodeListSearchForNode:self.parentNode searchString:self.text recursive:YES];
    
#ifdef DEBUG
    MEGALogInfo(@"[Search] \"%@\" finishes", self.text);
#else
    MEGALogInfo(@"[Search] finishes", self.text);
#endif
    
    if (self.completion) {
        if (self.isCancelled) {
#ifdef DEBUG
            MEGALogInfo(@"[Search] \"%@\" canceled", self.text);
#else
            MEGALogInfo(@"[Search] canceled", self.text);
#endif
            self.completion(nil);
        } else {
            NSArray *nodesFound = nodeListFound.mnz_nodesArrayFromNodeList;
            MEGALogInfo(@"[Search] %ld nodes found and added to the array", (long) nodesFound.count);
            self.completion(nodesFound);
        }
    }
    
    [self finishOperation];
}

@end
