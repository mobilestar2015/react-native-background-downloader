//
//  RNFileBackgroundDownload.m
//  EkoApp
//
//  Created by Elad Gil on 20/11/2017.
//  Copyright © 2017 Eko. All rights reserved.
//
//
#import "RNBackgroundDownloader.h"
#import "RNBGDTaskConfig.h"

#define ID_TO_CONFIG_MAP_KEY @"com.eko.bgdownloadidmap"

static CompletionHandler storedCompletionHandler;

@implementation RNBackgroundDownloader {
    NSURLSession *urlSession;
    NSURLSessionConfiguration *sessionConfig;
    NSMutableDictionary<NSNumber *, RNBGDTaskConfig *> *taskToConfigMap;
    NSMutableDictionary<NSString *, NSURLSessionDownloadTask *> *idToTaskMap;
    NSMutableDictionary<NSString *, NSData *> *idToResumeDataMap;
    NSMutableDictionary<NSString *, NSNumber *> *idToPercentMap;
    NSMutableDictionary<NSString *, NSDictionary *> *progressReports;
    NSDate *lastProgressReport;
    NSNumber *sharedLock;
}

RCT_EXPORT_MODULE();

- (dispatch_queue_t)methodQueue
{
    return dispatch_queue_create("com.eko.backgrounddownloader", DISPATCH_QUEUE_SERIAL);
}

+ (BOOL)requiresMainQueueSetup {
    return YES;
}

- (NSArray<NSString *> *)supportedEvents {
    return @[@"downloadComplete", @"downloadProgress", @"downloadFailed", @"downloadBegin"];
}

- (NSDictionary *)constantsToExport {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);

    return @{
             @"documents": [paths firstObject],
             @"TaskRunning": @(NSURLSessionTaskStateRunning),
             @"TaskSuspended": @(NSURLSessionTaskStateSuspended),
             @"TaskCanceling": @(NSURLSessionTaskStateCanceling),
             @"TaskCompleted": @(NSURLSessionTaskStateCompleted)
             };
}

- (id) init {
    self = [super init];
    if (self) {
        taskToConfigMap = [self deserialize:[[NSUserDefaults standardUserDefaults] objectForKey:ID_TO_CONFIG_MAP_KEY]];
        if (taskToConfigMap == nil) {
            taskToConfigMap = [[NSMutableDictionary alloc] init];
        }
        idToTaskMap = [[NSMutableDictionary alloc] init];
        idToResumeDataMap= [[NSMutableDictionary alloc] init];
        idToPercentMap = [[NSMutableDictionary alloc] init];
        NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
        NSString *sessonIdentifier = [bundleIdentifier stringByAppendingString:@".backgrounddownloadtask"];
        sessionConfig = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:sessonIdentifier];
        sessionConfig.HTTPMaximumConnectionsPerHost = 10;
        progressReports = [[NSMutableDictionary alloc] init];
        lastProgressReport = [[NSDate alloc] init];
        sharedLock = [NSNumber numberWithInt:1];
    }
    return self;
}

- (void)lazyInitSession {
    if (urlSession == nil) {
        urlSession = [NSURLSession sessionWithConfiguration:sessionConfig delegate:self delegateQueue:nil];
    }
}

- (void)removeTaskFromMap: (NSURLSessionTask *)task {
    @synchronized (sharedLock) {
        NSNumber *taskId = @(task.taskIdentifier);
        RNBGDTaskConfig *taskConfig = taskToConfigMap[taskId];

        [taskToConfigMap removeObjectForKey:taskId];
        [[NSUserDefaults standardUserDefaults] setObject:[self serialize: taskToConfigMap] forKey:ID_TO_CONFIG_MAP_KEY];

        if (taskConfig) {
            [idToTaskMap removeObjectForKey:taskConfig.id];
            [idToPercentMap removeObjectForKey:taskConfig.id];
        }
        if (taskToConfigMap.count == 0) {
            [urlSession invalidateAndCancel];
            urlSession = nil;
        }
    }
}

+ (void)setCompletionHandlerWithIdentifier: (NSString *)identifier completionHandler: (CompletionHandler)completionHandler {
    NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
    NSString *sessonIdentifier = [bundleIdentifier stringByAppendingString:@".backgrounddownloadtask"];
    if ([sessonIdentifier isEqualToString:identifier]) {
        storedCompletionHandler = completionHandler;
    }
}

- (NSError *)getServerError: (nonnull NSURLSessionDownloadTask *)downloadTask {
    NSError *serverError;
    NSInteger httpStatusCode = [((NSHTTPURLResponse *)downloadTask.response) statusCode];
    if(httpStatusCode != 200) {
      serverError = [NSError errorWithDomain:NSURLErrorDomain
                                        code:httpStatusCode
                                    userInfo:@{NSLocalizedDescriptionKey: [NSHTTPURLResponse localizedStringForStatusCode: httpStatusCode]}];
    }
    return serverError;
}

- (BOOL)saveDownloadedFile: (nonnull RNBGDTaskConfig *) taskConfig downloadURL:(nonnull NSURL *)location error:(NSError **)saveError {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *destURL = [NSURL fileURLWithPath:taskConfig.destination];
    [fileManager createDirectoryAtURL:[destURL URLByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    [fileManager removeItemAtURL:destURL error:nil];

    return [fileManager moveItemAtURL:location toURL:destURL error:saveError];
}

- (NSURLSessionDownloadTask*)downloadImpl: (NSDictionary*) options {
    NSString *identifier = options[@"id"];
    NSString *url = options[@"url"];
    NSString *destination = options[@"destination"];
    NSDictionary *headers = options[@"headers"];
    if (identifier == nil || url == nil || destination == nil) {
        NSLog(@"[RNBackgroundDownloader] - [Error] id, url and destination must be set");
        return nil;
    }

    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:url]];
    if (headers != nil) {
        for (NSString *headerKey in headers) {
            [request setValue:[headers valueForKey:headerKey] forHTTPHeaderField:headerKey];
        }
    }

    NSURLSessionDownloadTask __strong *task = [urlSession downloadTaskWithRequest:request];
    idToTaskMap[identifier] = task;
    idToPercentMap[identifier] = @0.0;

    return task;
}

- (void)startDownloadTasks:(NSMutableArray<NSURLSessionDownloadTask*>*) tasks {
    if (tasks.count > 0) {
        @synchronized (sharedLock) {
            [[NSUserDefaults standardUserDefaults] setObject:[self serialize: taskToConfigMap] forKey:ID_TO_CONFIG_MAP_KEY];

            for (int i = 0; i < tasks.count; i++) {
                [tasks[i] resume];
            }

            [tasks removeAllObjects];
        }
    }
}

#pragma mark - JS exported methods
RCT_EXPORT_METHOD(downloadFiles: (NSArray*) downloads) {
    @synchronized (sharedLock) {
        [self lazyInitSession];
        lastProgressReport = [[NSDate alloc] init];

        NSMutableArray<NSURLSessionDownloadTask*> *tasks = [[NSMutableArray alloc] init];

        for (int i = 0; i < downloads.count; i++) {
            NSDictionary* options = downloads[i];
            NSString *identifier = options[@"id"];
            NSString *destination = options[@"destination"];
            NSURLSessionDownloadTask* task = [self downloadImpl:options];

            if (task != nil) {
                RNBGDTaskConfig *taskConfig = [[RNBGDTaskConfig alloc] initWithDictionary: @{@"id": identifier, @"destination": destination}];

                taskToConfigMap[@(task.taskIdentifier)] = taskConfig;
                [[NSUserDefaults standardUserDefaults] setObject:[self serialize: taskToConfigMap] forKey:ID_TO_CONFIG_MAP_KEY];
                [task resume];
//                [tasks addObject:task];
            }
        }

//        [self startDownloadTasks:tasks];
    }
}

RCT_EXPORT_METHOD(download: (NSDictionary *) options) {
    NSString *identifier = options[@"id"];
    NSString *url = options[@"url"];
    NSString *destination = options[@"destination"];
    NSDictionary *headers = options[@"headers"];
    if (identifier == nil || url == nil || destination == nil) {
        NSLog(@"[RNBackgroundDownloader] - [Error] id, url and destination must be set");
        return;
    }

    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:url]];
    if (headers != nil) {
        for (NSString *headerKey in headers) {
            [request setValue:[headers valueForKey:headerKey] forHTTPHeaderField:headerKey];
        }
    }

    @synchronized (sharedLock) {
        [self lazyInitSession];
        NSURLSessionDownloadTask __strong *task = [urlSession downloadTaskWithRequest:request];
        RNBGDTaskConfig *taskConfig = [[RNBGDTaskConfig alloc] initWithDictionary: @{@"id": identifier, @"destination": destination}];

        taskToConfigMap[@(task.taskIdentifier)] = taskConfig;
        [[NSUserDefaults standardUserDefaults] setObject:[self serialize: taskToConfigMap] forKey:ID_TO_CONFIG_MAP_KEY];

        idToTaskMap[identifier] = task;
        idToPercentMap[identifier] = @0.0;

        [task resume];
        lastProgressReport = [[NSDate alloc] init];
    }
}

RCT_EXPORT_METHOD(pauseTask: (NSString *)identifier) {
    @synchronized (sharedLock) {
        NSURLSessionDownloadTask *task = idToTaskMap[identifier];
        if (task != nil && task.state == NSURLSessionTaskStateRunning) {
            [task suspend];
        }
    }
}

RCT_EXPORT_METHOD(resumeTask: (NSString *)identifier) {
    @synchronized (sharedLock) {
        NSURLSessionDownloadTask *task = idToTaskMap[identifier];
        if (task != nil && task.state == NSURLSessionTaskStateSuspended) {
            [task resume];
        }
    }
}

RCT_EXPORT_METHOD(stopTask: (NSString *)identifier) {
    @synchronized (sharedLock) {
        NSURLSessionDownloadTask *task = idToTaskMap[identifier];
        if (task != nil) {
            [task cancel];
            [self removeTaskFromMap:task];
        }
    }
}

RCT_EXPORT_METHOD(checkForExistingDownloads: (RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
    [self lazyInitSession];
    [urlSession getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> * _Nonnull dataTasks, NSArray<NSURLSessionUploadTask *> * _Nonnull uploadTasks, NSArray<NSURLSessionDownloadTask *> * _Nonnull downloadTasks) {
        NSMutableArray *idsFound = [[NSMutableArray alloc] init];
        @synchronized (self->sharedLock) {
            for (NSURLSessionDownloadTask *foundTask in downloadTasks) {
                NSURLSessionDownloadTask __strong *task = foundTask;
                RNBGDTaskConfig *taskConfig = self->taskToConfigMap[@(task.taskIdentifier)];
                if (taskConfig) {
                    if (task.state == NSURLSessionTaskStateCompleted && task.countOfBytesReceived < task.countOfBytesExpectedToReceive) {
                        if (task.error && task.error.code == -999 && task.error.userInfo[NSURLSessionDownloadTaskResumeData] != nil) {
                            task = [self->urlSession downloadTaskWithResumeData:task.error.userInfo[NSURLSessionDownloadTaskResumeData]];
                        } else {
                            task = [self->urlSession downloadTaskWithURL:foundTask.currentRequest.URL];
                        }
                        [task resume];
                    }
                    NSNumber *percent = foundTask.countOfBytesExpectedToReceive > 0 ? [NSNumber numberWithFloat:(float)task.countOfBytesReceived/(float)foundTask.countOfBytesExpectedToReceive] : @0.0;
                    [idsFound addObject:@{
                                          @"id": taskConfig.id,
                                          @"state": [NSNumber numberWithInt: task.state],
                                          @"bytesWritten": [NSNumber numberWithLongLong:task.countOfBytesReceived],
                                          @"totalBytes": [NSNumber numberWithLongLong:foundTask.countOfBytesExpectedToReceive],
                                          @"percent": percent
                                          }];
                    taskConfig.reportedBegin = YES;
                    self->taskToConfigMap[@(task.taskIdentifier)] = taskConfig;
                    self->idToTaskMap[taskConfig.id] = task;
                    self->idToPercentMap[taskConfig.id] = percent;
                } else {
                    [task cancel];
                }
            }
            resolve(idsFound);
        }
    }];
}

#pragma mark - NSURLSessionDownloadDelegate methods
- (void)URLSession:(nonnull NSURLSession *)session downloadTask:(nonnull NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(nonnull NSURL *)location {
    @synchronized (sharedLock) {
        RNBGDTaskConfig *taskConfig = taskToConfigMap[@(downloadTask.taskIdentifier)];
        if (taskConfig != nil) {
            NSError *error = [self getServerError:downloadTask];
            if (error == nil) {
                [self saveDownloadedFile:taskConfig downloadURL:location error:&error];
            }
            if (self.bridge) {
                if (error == nil) {
                    [self sendEventWithName:@"downloadComplete" body:@{@"id": taskConfig.id}];
                } else {
                    [self sendEventWithName:@"downloadFailed" body:@{@"id": taskConfig.id, @"error": [error localizedDescription]}];
                }
            }
            [self removeTaskFromMap:downloadTask];
        }
    }
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didResumeAtOffset:(int64_t)fileOffset expectedTotalBytes:(int64_t)expectedTotalBytes {
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    @synchronized (sharedLock) {
        RNBGDTaskConfig *taskCofig = taskToConfigMap[@(downloadTask.taskIdentifier)];
        if (taskCofig != nil) {
            if (!taskCofig.reportedBegin) {
                [self sendEventWithName:@"downloadBegin" body:@{@"id": taskCofig.id, @"expectedBytes": [NSNumber numberWithLongLong: totalBytesExpectedToWrite]}];
                taskCofig.reportedBegin = YES;
            }

            NSNumber *prevPercent = idToPercentMap[taskCofig.id];
            NSNumber *percent = [NSNumber numberWithFloat:(float)totalBytesWritten/(float)totalBytesExpectedToWrite];
            if ([percent floatValue] - [prevPercent floatValue] > 0.01f) {
                progressReports[taskCofig.id] = @{@"id": taskCofig.id, @"written": [NSNumber numberWithLongLong: totalBytesWritten], @"total": [NSNumber numberWithLongLong: totalBytesExpectedToWrite], @"percent": percent};
                idToPercentMap[taskCofig.id] = percent;
            }

            NSDate *now = [[NSDate alloc] init];
            if ([now timeIntervalSinceDate:lastProgressReport] > 0.25 && progressReports.count > 0) {
                if (self.bridge) {
                    [self sendEventWithName:@"downloadProgress" body:[progressReports allValues]];
                }
                lastProgressReport = now;
                [progressReports removeAllObjects];
            }
        }
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    @synchronized (sharedLock) {
        RNBGDTaskConfig *taskCofig = taskToConfigMap[@(task.taskIdentifier)];
        if (error != nil && error.code != -999 && taskCofig != nil) {
            if (self.bridge) {
                [self sendEventWithName:@"downloadFailed" body:@{@"id": taskCofig.id, @"error": [error localizedDescription]}];
            }
            [self removeTaskFromMap:task];
        }
    }
}

- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    if (storedCompletionHandler) {
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            storedCompletionHandler();
            storedCompletionHandler = nil;
        }];
    }
}

#pragma mark - serialization
- (NSData *)serialize: (id)obj {
    return [NSKeyedArchiver archivedDataWithRootObject:obj];
}

- (id)deserialize: (NSData *)data {
    if (data == nil) {
        return nil;
    }

    return [NSKeyedUnarchiver unarchiveObjectWithData:data];
}

@end
