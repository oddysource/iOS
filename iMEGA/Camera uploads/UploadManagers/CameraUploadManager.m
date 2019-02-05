
#import "CameraUploadManager.h"
#import "CameraUploadRecordManager.h"
#import "CameraScanner.h"
#import "CameraUploadOperation.h"
#import "Helper.h"
#import "MEGASdkManager.h"
#import "MEGACreateFolderRequestDelegate.h"
#import "UploadOperationFactory.h"
#import "AttributeUploadManager.h"
#import "MEGAConstants.h"
#import "CameraUploadManager+Settings.h"
#import "UploadRecordsCollator.h"
#import "BackgroundUploadMonitor.h"
#import "TransferSessionManager.h"
#import "NSFileManager+MNZCategory.h"
#import "NSURL+CameraUpload.h"
#import "MediaInfoLoader.h"

static NSString * const CameraUploadsNodeHandle = @"CameraUploadsNodeHandle";
static NSString * const CameraUplodFolderName = @"Camera Uploads";
static NSString * const CameraUploadIdentifierSeparator = @",";

static const NSInteger ConcurrentPhotoUploadCount = 10;
static const NSInteger MaxConcurrentPhotoOperationCountInBackground = 5;
static const NSInteger MaxConcurrentPhotoOperationCountInMemoryWarning = 2;

static const NSInteger ConcurrentVideoUploadCount = 1;
static const NSInteger MaxConcurrentVideoOperationCount = 1;

static const NSTimeInterval MinimumBackgroundRefreshInterval = 3600 * 1;
static const NSTimeInterval BackgroundRefreshDuration = 25;
static const NSTimeInterval LoadMediaInfoTimeoutInSeconds = 120;

@interface CameraUploadManager ()

@property (nonatomic) BOOL isNodesFetchDone;
@property (strong, nonatomic) NSOperationQueue *photoUploadOperationQueue;
@property (strong, nonatomic) NSOperationQueue *videoUploadOperationQueue;
@property (strong, readwrite, nonatomic) MEGANode *cameraUploadNode;
@property (strong, nonatomic) CameraScanner *cameraScanner;
@property (strong, nonatomic) UploadRecordsCollator *dataCollator;
@property (strong, nonatomic) BackgroundUploadMonitor *backgroundUploadMonitor;
@property (strong, nonatomic) MediaInfoLoader *mediaInfoLoader;

@end

@implementation CameraUploadManager

#pragma mark - initilization

+ (instancetype)shared {
    static id sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self initializeUploadOperationQueues];
        [self registerNotifications];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(resetCameraUpload) name:MEGALogoutNotificationName object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(nodesFetchDoneNotification) name:MEGANodesFetchDoneNotificationName object:nil];
    }
    return self;
}

- (void)initializeUploadOperationQueues {
    _photoUploadOperationQueue = [[NSOperationQueue alloc] init];
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) {
        _photoUploadOperationQueue.maxConcurrentOperationCount = MaxConcurrentPhotoOperationCountInBackground;
    }
    
    _videoUploadOperationQueue = [[NSOperationQueue alloc] init];
    _videoUploadOperationQueue.maxConcurrentOperationCount = MaxConcurrentVideoOperationCount;
}

- (void)registerNotifications {
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationDidEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationDidBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationDidReceiveMemoryWarning) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
}

#pragma mark - configuration when app launches

- (void)configCameraUploadWhenAppLaunches {
    [CameraUploadManager disableCameraUploadIfAccessProhibited];
    [CameraUploadManager enableBackgroundRefreshIfNeeded];
    [self startBackgroundUploadIfPossible];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [AttributeUploadManager.shared scanLocalAttributeFilesAndRetryUploadIfNeeded];
        [TransferSessionManager.shared restoreAllSessions];
        [self collateUploadRecords];
    });
}

#pragma mark - properties

- (UploadRecordsCollator *)dataCollator {
    if (_dataCollator == nil) {
        _dataCollator = [[UploadRecordsCollator alloc] init];
    }
    
    return _dataCollator;
}

- (BackgroundUploadMonitor *)backgroundUploadMonitor {
    if (_backgroundUploadMonitor == nil) {
        _backgroundUploadMonitor = [[BackgroundUploadMonitor alloc] init];
    }
    
    return _backgroundUploadMonitor;
}

- (CameraScanner *)cameraScanner {
    if (_cameraScanner == nil) {
        _cameraScanner = [[CameraScanner alloc] init];
    }
    
    return _cameraScanner;
}

- (MediaInfoLoader *)mediaInfoLoader {
    if (_mediaInfoLoader == nil) {
        _mediaInfoLoader = [[MediaInfoLoader alloc] init];
    }
    
    return _mediaInfoLoader;
}

#pragma mark - camera upload management

- (void)startCameraUploadIfNeeded {
    if (!MEGASdkManager.sharedMEGASdk.isLoggedIn || !CameraUploadManager.isCameraUploadEnabled) {
        return;
    }
    
    [self.cameraScanner scanMediaTypes:@[@(PHAssetMediaTypeImage)] completion:^{
        [self.cameraScanner observePhotoLibraryChanges];
    }];
    
    if (self.mediaInfoLoader.isMediaInfoLoaded) {
        [self requestCameraUploadNodeToUpload];
    } else {
        __weak __typeof__(self) weakSelf = self;
        [self.mediaInfoLoader loadMediaInfoWithTimeout:LoadMediaInfoTimeoutInSeconds completion:^(BOOL loaded) {
            if (loaded) {
                [weakSelf requestCameraUploadNodeToUpload];
            } else {
                [weakSelf startCameraUploadIfNeeded];
            }
        }];
    }
}

- (void)requestCameraUploadNodeToUpload {
    if (!self.isNodesFetchDone) {
        return;
    }
    
    [self requestCameraUploadNodeWithCompletion:^(MEGANode * _Nullable cameraUploadNode) {
        if (cameraUploadNode) {
            if (cameraUploadNode != self.cameraUploadNode) {
                self.cameraUploadNode = cameraUploadNode;
                [self saveCameraUploadHandle:cameraUploadNode.handle];
            }
            
            [self uploadCamera];
        }
    }];
}

- (void)uploadCamera {
    if (self.photoUploadOperationQueue.operationCount == 0) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            [self uploadNextAssetsWithNumber:ConcurrentPhotoUploadCount mediaType:PHAssetMediaTypeImage];
        });
    }

    [self startVideoUploadIfNeeded];
}

- (void)startVideoUploadIfNeeded {
    if (!(CameraUploadManager.isCameraUploadEnabled && CameraUploadManager.isVideoUploadEnabled)) {
        return;
    }
    
    [self.cameraScanner scanMediaTypes:@[@(PHAssetMediaTypeVideo)] completion:nil];
    
    if (!(self.mediaInfoLoader.isMediaInfoLoaded && self.isNodesFetchDone && self.cameraUploadNode != nil)) {
        return;
    }
    
    if (self.videoUploadOperationQueue.operationCount == 0) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            [self uploadNextAssetsWithNumber:ConcurrentVideoUploadCount mediaType:PHAssetMediaTypeVideo];
        });
    }
}

- (void)uploadNextAssetWithMediaType:(PHAssetMediaType)mediaType {
    if (!CameraUploadManager.isCameraUploadEnabled) {
        return;
    }
    
    if (mediaType == PHAssetMediaTypeVideo && !CameraUploadManager.isVideoUploadEnabled) {
        return;
    }
    
    [self uploadNextAssetsWithNumber:1 mediaType:mediaType];
}

- (void)uploadNextAssetsWithNumber:(NSInteger)number mediaType:(PHAssetMediaType)mediaType {
    NSArray *records = [CameraUploadRecordManager.shared fetchRecordsToQueueUpForUploadWithLimit:number mediaType:mediaType error:nil];
    if (records.count == 0) {
        MEGALogDebug(@"[Camera Upload] no more local asset to upload for media type %li", (long)mediaType);
        return;
    }
    
    for (MOAssetUploadRecord *record in records) {
        [CameraUploadRecordManager.shared updateUploadRecord:record withStatus:CameraAssetUploadStatusQueuedUp error:nil];
        PHAssetMediaSubtype savedMediaSubtype = PHAssetMediaSubtypeNone;
        CameraUploadOperation *operation = [UploadOperationFactory operationWithUploadRecord:record parentNode:self.cameraUploadNode identifierSeparator:CameraUploadIdentifierSeparator savedMediaSubtype:&savedMediaSubtype];
        PHAsset *asset = operation.uploadInfo.asset;
        if (operation) {
            if (asset.mediaType == PHAssetMediaTypeImage) {
                [self.photoUploadOperationQueue addOperation:operation];
            } else {
                [self.videoUploadOperationQueue addOperation:operation];
            }
            
            [self addUploadRecordIfNeededForAsset:asset savedMediaSubtype:savedMediaSubtype];
        } else {
            [CameraUploadRecordManager.shared deleteUploadRecord:record error:nil];
        }
    }
}

- (void)addUploadRecordIfNeededForAsset:(PHAsset *)asset savedMediaSubtype:(PHAssetMediaSubtype)savedMediaSubtype {
    if (@available(iOS 9.1, *)) {
        if (asset.mediaType == PHAssetMediaTypeImage && savedMediaSubtype == PHAssetMediaSubtypeNone && (asset.mediaSubtypes & PHAssetMediaSubtypePhotoLive)) {
            NSString *mediaSubtypedLocalIdentifier = [@[asset.localIdentifier, [@(PHAssetMediaSubtypePhotoLive) stringValue]] componentsJoinedByString:CameraUploadIdentifierSeparator];
            [CameraUploadRecordManager.shared saveAsset:asset mediaSubtypedLocalIdentifier:mediaSubtypedLocalIdentifier error:nil];
        }
    }
}

#pragma mark - nodes fetch done notification

- (void)nodesFetchDoneNotification {
    self.isNodesFetchDone = YES;
    [self startCameraUploadIfNeeded];
    [AttributeUploadManager.shared scanLocalAttributeFilesAndRetryUploadIfNeeded];
}

#pragma mark - stop upload

- (void)resetCameraUpload {
    CameraUploadManager.cameraUploadEnabled = NO;
    [NSFileManager.defaultManager removeItemIfExistsAtURL:NSURL.mnz_cameraUploadURL];
    [CameraUploadManager clearLocalSettings];
}

- (void)stopCameraUpload {
    [self stopVideoUpload];
    [self.photoUploadOperationQueue cancelAllOperations];
    [TransferSessionManager.shared invalidateAndCancelPhotoSessions];
    [self.cameraScanner unobservePhotoLibraryChanges];
    [CameraUploadManager disableBackgroundRefresh];
    [self stopBackgroundUpload];
}

- (void)stopVideoUpload {
    [self.videoUploadOperationQueue cancelAllOperations];
    [TransferSessionManager.shared invalidateAndCancelVideoSessions];
}

#pragma mark - upload status

- (NSUInteger)uploadPendingItemsCount {
    NSUInteger pendingCount = 0;
    
    if (CameraUploadManager.isCameraUploadEnabled) {
        NSArray<NSNumber *> *mediaTypes;
        if (CameraUploadManager.isVideoUploadEnabled) {
            mediaTypes = @[@(PHAssetMediaTypeVideo), @(PHAssetMediaTypeImage)];
        } else {
            mediaTypes = @[@(PHAssetMediaTypeImage)];
        }
        
        pendingCount = [CameraUploadRecordManager.shared pendingUploadRecordsCountByMediaTypes:mediaTypes error:nil];
    }
    
    return pendingCount;
}

#pragma mark - photo library scan

- (void)scanPhotoLibraryWithCompletion:(void (^)(void))completion {
    NSMutableArray<NSNumber *> *mediaTypes = [NSMutableArray array];
    
    if (CameraUploadManager.isCameraUploadEnabled) {
        [mediaTypes addObject:@(PHAssetMediaTypeImage)];
        if (CameraUploadManager.isVideoUploadEnabled) {
            [mediaTypes addObject:@(PHAssetMediaTypeVideo)];
        }
        
        [self.cameraScanner scanMediaTypes:mediaTypes completion:completion];
    } else {
        completion();
        return;
    }
}

#pragma mark - handle app lifecycle

- (void)applicationDidEnterBackground {
    self.photoUploadOperationQueue.maxConcurrentOperationCount = MaxConcurrentPhotoOperationCountInBackground;
}

- (void)applicationDidBecomeActive {
    self.photoUploadOperationQueue.maxConcurrentOperationCount = NSOperationQueueDefaultMaxConcurrentOperationCount;
}

- (void)applicationDidReceiveMemoryWarning {
    self.photoUploadOperationQueue.maxConcurrentOperationCount = MaxConcurrentPhotoOperationCountInMemoryWarning;
}

#pragma mark - photos access permission check

+ (void)disableCameraUploadIfAccessProhibited {
    switch (PHPhotoLibrary.authorizationStatus) {
        case PHAuthorizationStatusDenied:
        case PHAuthorizationStatusRestricted:
            if (CameraUploadManager.isCameraUploadEnabled) {
                CameraUploadManager.cameraUploadEnabled = NO;
            }
            break;
        default:
            break;
    }
}

#pragma mark - data collator

- (void)collateUploadRecords {
    [self.dataCollator collateUploadRecords];
}

#pragma mark - background refresh

+ (void)enableBackgroundRefreshIfNeeded {
    if (CameraUploadManager.isCameraUploadEnabled) {
        [UIApplication.sharedApplication setMinimumBackgroundFetchInterval:MinimumBackgroundRefreshInterval];
    }
}

+ (void)disableBackgroundRefresh {
    [UIApplication.sharedApplication setMinimumBackgroundFetchInterval:UIApplicationBackgroundFetchIntervalNever];
}

- (void)performBackgroundRefreshWithCompletion:(void (^)(UIBackgroundFetchResult))completion {
    if (CameraUploadManager.isCameraUploadEnabled) {
        [self scanPhotoLibraryWithCompletion:^{
            if (self.uploadPendingItemsCount == 0) {
                completion(UIBackgroundFetchResultNoData);
            } else {
                [self startCameraUploadIfNeeded];
                [NSTimer scheduledTimerWithTimeInterval:BackgroundRefreshDuration repeats:NO block:^(NSTimer * _Nonnull timer) {
                    completion(UIBackgroundFetchResultNewData);
                    if (self.uploadPendingItemsCount == 0) {
                        completion(UIBackgroundFetchResultNoData);
                    }
                }];
            }
        }];
    } else {
        completion(UIBackgroundFetchResultNoData);
    }
}

#pragma mark - background upload

- (void)startBackgroundUploadIfPossible {
    [self.backgroundUploadMonitor startBackgroundUploadIfPossible];
}

- (void)stopBackgroundUpload {
    [self.backgroundUploadMonitor stopBackgroundUpload];
}

#pragma mark - handle camera upload node

- (MEGANode *)cameraUploadNode {
    if (_cameraUploadNode == nil) {
        _cameraUploadNode = [self restoreCameraUploadNode];
    }
    
    return _cameraUploadNode;
}

- (MEGANode *)restoreCameraUploadNode {
    MEGANode *node = [self savedCameraUploadNode];
    if (node == nil) {
        node = [self findCameraUploadNodeInRoot];
        [self saveCameraUploadHandle:node.handle];
    }
    
    return node;
}

- (MEGANode *)savedCameraUploadNode {
    unsigned long long cameraUploadHandle = [[[NSUserDefaults standardUserDefaults] objectForKey:CameraUploadsNodeHandle] unsignedLongLongValue];
    if (cameraUploadHandle > 0) {
        MEGANode *node = [[MEGASdkManager sharedMEGASdk] nodeForHandle:cameraUploadHandle];
        if (node.parentHandle == [[MEGASdkManager sharedMEGASdk] rootNode].handle) {
            return node;
        }
    }
    
    return nil;
}

- (void)saveCameraUploadHandle:(uint64_t)handle {
    if (handle > 0) {
        [[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithUnsignedLongLong:handle] forKey:CameraUploadsNodeHandle];
    }
}

- (MEGANode *)findCameraUploadNodeInRoot {
    MEGANodeList *nodeList = [[MEGASdkManager sharedMEGASdk] childrenForParent:[[MEGASdkManager sharedMEGASdk] rootNode]];
    NSInteger nodeListSize = [[nodeList size] integerValue];
    
    for (NSInteger i = 0; i < nodeListSize; i++) {
        MEGANode *node = [nodeList nodeAtIndex:i];
        if ([CameraUplodFolderName isEqualToString:node.name] && node.isFolder) {
            return node;
        }
    }
    
    return nil;
}

- (void)requestCameraUploadNodeWithCompletion:(void (^)(MEGANode * _Nullable cameraUploadNode))completion {
    if (self.cameraUploadNode) {
        completion(self.cameraUploadNode);
    } else {
        [[MEGASdkManager sharedMEGASdk] createFolderWithName:CameraUplodFolderName parent:[[MEGASdkManager sharedMEGASdk] rootNode]
                                                    delegate:[[MEGACreateFolderRequestDelegate alloc] initWithCompletion:^(MEGARequest *request) {
            MEGANode *node = [[MEGASdkManager sharedMEGASdk] nodeForHandle:request.nodeHandle];
            completion(node);
        }]];
    }
}

@end
