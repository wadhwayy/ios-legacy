//
//  PrepareFilesToUpload.m
//  Owncloud iOs Client
//
//  Created by Gonzalo Gonzalez on 12/09/12.
//

/*
 Copyright (C) 2014, ownCloud, Inc.
 This code is covered by the GNU Public License Version 3.
 For distribution utilizing Apple mechanisms please see https://owncloud.org/contribute/iOS-license-exception/
 You should have received a copy of this license
 along with this program. If not, see <http://www.gnu.org/licenses/gpl-3.0.en.html>.
 */

#import "PrepareFilesToUpload.h"
#import "ELCImagePickerController.h"
#import "ELCAlbumPickerController.h"
#import "CheckAccessToServer.h"
#import "AppDelegate.h"
#import <Photos/Photos.h>

#import "UserDto.h"
#import "constants.h"
#import "EditAccountViewController.h"
#import "UtilsDtos.h"
#import "ManageUploadsDB.h"
#import "FileNameUtils.h"
#import "UploadUtils.h"
#import "ManageUsersDB.h"
#import "ManageUploadRequest.h"
#import "ManageAppSettingsDB.h"
#import "UtilsNetworkRequest.h"
#import "constants.h"
#import "Customization.h"
#import "UtilsUrls.h"
#import "OCCommunication.h"
#import "FileNameUtils.h"

//Notification to end and init loading screen
NSString *EndLoadingFileListNotification = @"EndLoadingFileListNotification";
NSString *InitLoadingFileListNotification = @"InitLoadingFileListNotification";
NSString *ReloadFileListFromDataBaseNotification = @"ReloadFileListFromDataBaseNotification";


@implementation PrepareFilesToUpload

#pragma mark - Gallery Upload, Upload camera assets, instant upload

- (void) addAssetsToUploadFromArray:(NSArray <PHAsset *>*) info andRemoteFoldersToUpload:(NSMutableArray *) arrayOfRemoteurl {
    for (int i = 0 ; i < [info count] ; i++) {
        [self.listOfAssetsToUpload addObject:[info objectAtIndex:i]];
        [self.arrayOfRemoteurl addObject:[arrayOfRemoteurl objectAtIndex:i]];
    }
    
    [self startWithTheNextAsset];
}

- (void) addAssetsToUpload:(PHFetchResult *) assetsToUpload andRemoteFolder:(NSString *) remoteFolder {
    
    for (int i = 0 ; i < [assetsToUpload count] ; i++) {
        [self.listOfAssetsToUpload addObject:[assetsToUpload objectAtIndex:i]];
        
        [self.arrayOfRemoteurl addObject:remoteFolder];
    }
    
    [self startWithTheNextAsset];
}

- (void)sendFileToUploadByUploadOfflineDto:(UploadsOfflineDto *) currentUpload {
    NSLog(@"self.currentUpload: %@", currentUpload.uploadFileName);
    NSLog(@"isLast: %d", currentUpload.isLastUploadFileOfThisArray);
    
    ManageUploadRequest *currentManageUploadRequest = [ManageUploadRequest new];
    currentManageUploadRequest.delegate = self;
    currentManageUploadRequest.lenghtOfFile = [UploadUtils makeLengthString:currentUpload.estimateLength];
    
    [currentManageUploadRequest addFileToUpload:currentUpload];
    
}

- (void) startWithTheNextAsset {
    NSLog(@"_starWithTheNextAsset_");
    @synchronized (self) {
        AppDelegate *app = (AppDelegate *)[[UIApplication sharedApplication] delegate];
        
        if(self.listOfAssetsToUpload && [self.listOfAssetsToUpload count] >0) {
            PHAsset *assetToUpload = self.listOfAssetsToUpload[0];
            NSString *uploadPath = self.arrayOfRemoteurl[0];
            
            [self.listOfAssetsToUpload removeObjectAtIndex:0];
            [self.arrayOfRemoteurl removeObjectAtIndex:0];
            
            [self uploadAssetFromGallery:assetToUpload andRemoteFolder:uploadPath andCurrentUser:app.activeUser andIsLastFile:([self.listOfAssetsToUpload count] == 1)];
        }
    }
}

- (void) uploadAssetFromGallery:(PHAsset *) assetToUpload andRemoteFolder:(NSString *) remoteFolder andCurrentUser:(UserDto *) currentUser andIsLastFile:(BOOL) isLastUploadFileOfThisArray {
    NSLog(@"_uploadAssetFromGallery_ToRemoteFolder");
    
    NSString *fileName = [FileNameUtils getComposeNameFromPHAsset:assetToUpload];
    NSString *localPath = [[UtilsUrls getTempFolderForUploadFiles] stringByAppendingPathComponent:fileName];
    
    void (^UploadFile)(NSString *, UploadsOfflineDto *) = ^(NSString *localPath, UploadsOfflineDto *upload) {
        NSLog(@"_UploadFile_ : %@ , localPath: %@", upload.uploadFileName, localPath);
        
        [self.listOfUploadOfflineToGenerateSQL addObject:upload];
        
        if([self.listOfAssetsToUpload count] > 0) {
            //We have more files to process
            [self startWithTheNextAsset];
        } else {
            NSLog(@"No pending asset to process");
            //We finish all the files of this block
            NSLog(@"self.listOfUploadOfflineToGenerateSQL: %lu", (unsigned long)[self.listOfUploadOfflineToGenerateSQL count]);
            
            //In this point we have all the files to upload in the Array
            [ManageUploadsDB insertManyUploadsOffline:self.listOfUploadOfflineToGenerateSQL];
            
            //if is the last one we reset the array
            self.listOfUploadOfflineToGenerateSQL = nil;
            self.listOfUploadOfflineToGenerateSQL = [[NSMutableArray alloc] init];
            
            self.positionOfCurrentUploadInArray = 0;
            
            [self performSelectorOnMainThread:@selector(endLoadingInFileList) withObject:nil waitUntilDone:YES];
            
            UploadsOfflineDto *currentFile = [ManageUploadsDB getNextUploadOfflineFileToUpload];
            
            //We begin with the first file of the array
            if (currentFile) {
                [self sendFileToUploadByUploadOfflineDto:currentFile];
            }
        }
        
    };
    
    if (assetToUpload.mediaType == PHAssetMediaTypeImage) {
        [[PHImageManager defaultManager] requestImageDataForAsset:assetToUpload options:nil resultHandler:^(NSData * _Nullable imageData, NSString * _Nullable dataUTI, UIImageOrientation orientation, NSDictionary * _Nullable info) {
            
            NSFileManager *fileManager = [[NSFileManager alloc] init];
            if ([fileManager fileExistsAtPath:localPath]) {
                [fileManager removeItemAtPath:localPath error:nil];
            }
            
            if (imageData && localPath) {
                
                //Divide the file in chunks of 1024KB, then create the file with all chunks
                
                //Variables
               __block NSUInteger offset = 0;
                NSUInteger chunkSize = 1024 * 1024;
                NSUInteger length = (NSUInteger) imageData.length;
                NSLog(@"_assetFileSize_: %lu length: %lu", (unsigned long) (length/1024)/1024, length );
                
                if (length < (k_lenght_chunk *1024)) {
                     NSLog(@"_copyingFileDirectly_ - File: %@ - Path: %@ ",fileName, localPath);
                    [imageData writeToFile:localPath atomically:YES];
                    
                } else {
                    
                    //Create file
                    if (! [fileManager createFileAtPath:localPath contents:nil attributes:nil])
                    {
                        DLog(@"_error_createImageFileAtPath_ File: %@ - Path: %@ - Error was code: %d - message: %s",fileName, localPath, errno, strerror(errno));
                        NSLog(@"_error_createImageFileAtPath_ File: %@ - Path: %@ - Error was code: %d - message: %s",fileName, localPath, errno, strerror(errno));
                        
                    } else {
                         DLog(@"_copyingFile_ - File: %@ - Path: %@ ",fileName, localPath);
                        NSLog(@"_copyingFile_ - File: %@ - Path: %@ ",fileName, localPath);
                        
                        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
                            do {
                                Byte *buffer = (Byte*)malloc(chunkSize);
                                
                                //Store the chunk size
                                NSUInteger thisChunkSize = length - offset > chunkSize ? chunkSize : length - offset;
                                
                                NSRange rangeBytes= NSMakeRange(offset,thisChunkSize);
                                [imageData getBytes:buffer range:rangeBytes];
                                //NSUInteger k = rangeBytes.length - rangeBytes.location;
                                NSData *adata = [NSData dataWithBytes:buffer length:thisChunkSize];
                                
                                DLog(@"Write buffer in file: %@", localPath);
                                NSFileHandle *fileHandle=[NSFileHandle fileHandleForWritingAtPath:localPath];
                                [fileHandle seekToEndOfFile];
                                [fileHandle writeData:adata];
                                [fileHandle closeFile];
                                
                                //Avanced position
                                offset += thisChunkSize;
                                
                                //Free memory
                                free(buffer);
                                fileHandle=nil;
                                adata=nil;
                            } while (offset < length);
                        });
                    }
                }
             
                if (![fileManager fileExistsAtPath:localPath])
                {
                    DLog(@"_error_createImageFileAtPath_ fileNotExists - File: %@ - Path: %@ - Error was code: %d - message: %s",fileName, localPath, errno, strerror(errno));
                    NSLog(@"_error_createImageFileAtPath_ fileNotExists - File: %@ - Path: %@ - Error was code: %d - message: %s",fileName, localPath, errno, strerror(errno));
                }
                
                UploadsOfflineDto *currentUpload = [[UploadsOfflineDto alloc] init];
                currentUpload.originPath = localPath;
                currentUpload.destinyFolder = remoteFolder;
                currentUpload.uploadFileName = fileName;
                currentUpload.estimateLength = imageData.length;;
                currentUpload.userId = currentUser.idUser;
                currentUpload.isLastUploadFileOfThisArray = isLastUploadFileOfThisArray;
                currentUpload.status = waitingAddToUploadList;
                currentUpload.chunksLength = k_lenght_chunk;
                currentUpload.uploadedDate = 0;
                currentUpload.kindOfError = notAnError;
                currentUpload.isInternalUpload = YES;
                currentUpload.taskIdentifier = 0;
                
                UploadFile(localPath, currentUpload);
            }
        }];
    } else if (assetToUpload.mediaType == PHAssetMediaTypeVideo) {
        
        [[PHImageManager defaultManager] requestPlayerItemForVideo:assetToUpload options:nil resultHandler:^(AVPlayerItem * _Nullable playerItem, NSDictionary * _Nullable info) {
            
            NSString *videoFilePath;
            NSArray *tokenizedPHImageFileSandboxExtensionTokenKey = [info[@"PHImageFileSandboxExtensionTokenKey"] componentsSeparatedByString:@";"];
            for (NSString *substring in tokenizedPHImageFileSandboxExtensionTokenKey) {
                if ([substring isAbsolutePath] && [[NSFileManager defaultManager] fileExistsAtPath:substring]) {
                    videoFilePath = substring;
                    break;
                }
            }
            
            if (videoFilePath) {
                NSFileManager *fileManager = [NSFileManager defaultManager];
                if ([fileManager fileExistsAtPath:localPath]) {
                    [fileManager removeItemAtPath:localPath error:nil];
                }
                
                AVAssetExportSession *exportSession = [[AVAssetExportSession alloc] initWithAsset:playerItem.asset presetName:AVAssetExportPresetHighestQuality];
                
                exportSession.outputURL = [NSURL fileURLWithPath:localPath];
                exportSession.outputFileType = AVFileTypeQuickTimeMovie;
                
                [exportSession exportAsynchronouslyWithCompletionHandler:^{
                    NSData *videoData = [NSData dataWithContentsOfURL:[NSURL fileURLWithPath:localPath]];
                    
                    if (videoData && localPath) {
                        
                        if (![fileManager createFileAtPath:localPath contents:videoData attributes:nil])
                        {
                            DLog(@"_error_createVideoFileAtPath_ File: %@ - Path: %@ - Error was code: %d - message: %s",fileName, localPath, errno, strerror(errno));
                            NSLog(@"_error_createVideoFileAtPath_ File: %@ - Path: %@ - Error was code: %d - message: %s",fileName, localPath, errno, strerror(errno));
                        }
                            
                        UploadsOfflineDto *currentUpload = [[UploadsOfflineDto alloc] init];
                        currentUpload.originPath = localPath;
                        currentUpload.destinyFolder = remoteFolder;
                        currentUpload.uploadFileName = fileName;
                        currentUpload.estimateLength = videoData.length;;
                        currentUpload.userId = currentUser.idUser;
                        currentUpload.isLastUploadFileOfThisArray = isLastUploadFileOfThisArray;
                        currentUpload.status = waitingAddToUploadList;
                        currentUpload.chunksLength = k_lenght_chunk;
                        currentUpload.uploadedDate = 0;
                        currentUpload.kindOfError = notAnError;
                        currentUpload.isInternalUpload = YES;
                        currentUpload.taskIdentifier = 0;
                        
                        UploadFile(localPath, currentUpload);
                
                    }
                }];
            }
        }];
    }
}

/*
 * This method close the loading view in main screen by local notification
 */
- (void)endLoadingInFileList {
    NSLog(@"_endLoadingInFileList_");
    //Set global loading screen global flag to NO
    AppDelegate *app = (AppDelegate *)[[UIApplication sharedApplication] delegate];
    app.isLoadingVisible = NO;
    //Send notification to indicate to close the loading view
    [[NSNotificationCenter defaultCenter] postNotificationName:EndLoadingFileListNotification object: nil];
}

/*
 * This method close the loading view in main screen by local notification
 */
- (void)initLoadingInFileList {
    NSLog(@"_initLoadingInFileList_");
    //Set global loading screen global flag to NO
    AppDelegate *app = (AppDelegate *)[[UIApplication sharedApplication] delegate];
    app.isLoadingVisible = YES;
    //Send notification to indicate to close the loading view
    [[NSNotificationCenter defaultCenter] postNotificationName:InitLoadingFileListNotification object: nil];
}

/*
 * This method close the loading view in main screen by local notification
 */
- (void)reloadFromDataBaseInFileList {
    [[NSNotificationCenter defaultCenter] postNotificationName:ReloadFileListFromDataBaseNotification object: nil];
}


/*
 * Method to obtain the extension of the file in upper case
 */
- (NSString *)getExtension:(NSString*)string{

    NSArray *arr =[[NSArray alloc] initWithArray: [string componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"&ext="]]];
    NSString *ext = [NSString stringWithFormat:@"%@",[arr lastObject]];
    ext = [ext uppercaseString];
    
    return ext;
}



#pragma mark - ManageUploadRequestDelegate

/*
 * Method that is called when the upload is completed, its posible that the file
 * is not upload.
 */

- (void)uploadCompleted:(NSString *) currentRemoteFolder {
    NSLog(@"uploadCompleted");
    
    if (_delegate) {
        [_delegate refreshAfterUploadAllFiles:currentRemoteFolder];
    } else {
        NSLog(@"_delegate is nil");
    }
    
    //Update the Recent Tab for update the number of error in the badge
    AppDelegate *app = (AppDelegate *)[[UIApplication sharedApplication]delegate];
    [app updateRecents];
}

- (void)uploadFailed:(NSString*)string{
    
    //Error msg
    //Call showAlertView in main thread
    [self performSelectorOnMainThread:@selector(showAlertView:)
                           withObject:string
                        waitUntilDone:YES];
}

- (void)uploadFailedForLoginError:(NSString*)string {
    
    //Cancel all uploads
    //  [self cancelAllUploads];
    AppDelegate *appDelegate = (AppDelegate *)[[UIApplication sharedApplication] delegate];
    [appDelegate updateRecents];
    if ([(NSObject*)self.delegate respondsToSelector:@selector(errorWhileUpload)]) {
        [_delegate errorWhileUpload];
    }
    
    [self performSelectorOnMainThread:@selector(showAlertView:) withObject:string waitUntilDone:YES];
    
}

- (void)uploadCanceled:(NSObject*)up{
    NSLog(@"_uploadCanceled_");
}

//Control of the number of lost connecition to send only one message for the user
- (void)uploadLostConnectionWithServer:(NSString*)string{
    NSLog(@"_uploadLostConnectionWithServer_:%@", string);
    
    //Error msg
    //Call showAlertView in main thread
  /*  [self performSelectorOnMainThread:@selector(showAlertView:)
                           withObject:string
                        waitUntilDone:YES];*/
}

/*
 * This method is for show alert view in main thread.
 */

- (void) showAlertView:(NSString*)string {
    
    UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:string message:@"" delegate:nil cancelButtonTitle:NSLocalizedString(@"ok", nil) otherButtonTitles:nil, nil];
    [alertView show];
}


/*
 * Method to continue with the next file of the list (or the first)
 */
- (void)uploadAddedContinueWithNext {
    
    UploadsOfflineDto *currentFile = [ManageUploadsDB getNextUploadOfflineFileToUpload];
    
    if (currentFile) {
        [self sendFileToUploadByUploadOfflineDto:currentFile];
    }

}

/*
* Method to be sure that the loading of the file list is finish
*/
- (void) overwriteCompleted{
    
    [self initLoadingInFileList];
    [self reloadFromDataBaseInFileList];
    [self endLoadingInFileList];
}

@end
