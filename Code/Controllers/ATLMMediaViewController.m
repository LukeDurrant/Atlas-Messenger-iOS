//
//  ATLMMediaViewController.m
//  Atlas Messenger
//
//  Created by Ben Blakley on 1/16/15.
//  Copyright (c) 2015 Layer, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "ATLMMediaViewController.h"
#import <MediaPlayer/MediaPlayer.h>
#import <Atlas/Atlas.h>
#import <AVFoundation/AVFoundation.h>
#import <Atlas/ATLUIImageHelper.h>

static NSTimeInterval const ATLMMediaViewControllerAnimationDuration = 0.75f;
static NSTimeInterval const ATLMMediaViewControllerProgressBarHeight = 2.00f;
static NSString *ATLMMediaViewControllerSymLinkedMediaTempPath = @"com.layer.atlas/media/";

@interface ATLMMediaViewController () <UIScrollViewDelegate, LYRProgressDelegate>

@property (nonatomic) LYRMessage *message;
@property (nonatomic) UIImage *lowResImage;
@property (nonatomic) UIImage *fullResImage;
@property (nonatomic) NSURL *mediaBaseURL;
@property (nonatomic) MPMoviePlayerController *moviePlayerController;
@property (nonatomic) CGSize fullResImageSize;
@property (nonatomic) CGRect mediaViewFrame;
@property (nonatomic) UIScrollView *scrollView;
@property (nonatomic) UIImageView *lowResImageView;
@property (nonatomic) UIImageView *fullResImageView;
@property (nonatomic) UIProgressView *progressView;
@property (nonatomic) BOOL zoomingEnabled;
@property (nonatomic) BOOL viewControllerConfigured;
@property (nonatomic) LYRMessagePart *observedMessagePart;

@property (nonatomic) NSArray<id<UIPreviewActionItem>> *previewActions;

@end

@implementation ATLMMediaViewController

- (instancetype)initWithMessage:(LYRMessage *)message
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _message = message;
    }
    return self;
}

- (void)dealloc
{
    self.scrollView.delegate = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self name:MPMoviePlayerLoadStateDidChangeNotification object:nil];
    if (self.observedMessagePart) {
        [self.observedMessagePart removeObserver:self forKeyPath:@"transferStatus"];
    }
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.fullResImageSize = CGSizeZero;
    self.view.backgroundColor = [UIColor whiteColor];
    
    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.scrollView.delegate = self;
    self.scrollView.contentSize = CGSizeMake(self.view.bounds.size.width, self.view.bounds.size.height);
    [self.view addSubview:self.scrollView];
    
    self.lowResImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
    [self.scrollView addSubview:self.lowResImageView];
    
    self.fullResImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
    self.fullResImageView.alpha = 0.0f; // hide the full-res image view at the beginning.
    [self.scrollView addSubview:self.fullResImageView];
    
    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.alpha = 0.0;
    self.progressView.tintColor = ATLBlueColor();
    self.progressView.trackTintColor = [UIColor clearColor];
    [self.navigationController.navigationBar addSubview:self.progressView];
    [self.progressView setProgress:0];
    
    UITapGestureRecognizer *recognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(doubleTapRecognized:)];
    recognizer.numberOfTapsRequired = 2;
    [self.view addGestureRecognizer:recognizer];
    
    UIBarButtonItem *shareBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(share:)];
    self.navigationItem.rightBarButtonItem = shareBarButtonItem;
    self.navigationItem.rightBarButtonItem.enabled = NO;
    
    if (ATLMessagePartForMIMEType(self.message, ATLMIMETypeImageJPEG) || ATLMessagePartForMIMEType(self.message, ATLMIMETypeImagePNG) || ATLMessagePartForMIMEType(self.message, ATLMIMETypeImageGIF)) {
        self.title = @"Image";
        self.zoomingEnabled = YES;
    } else if (ATLMessagePartForMIMEType(self.message, ATLMIMETypeVideoMP4)) {
        self.title = @"Video";
        self.zoomingEnabled = NO;
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        NSString *basePath = ([paths count] > 0) ? [paths objectAtIndex:0] : nil;
        NSURL *symLinkedMediaBaseURL = [NSURL fileURLWithPath:basePath isDirectory:YES];
        self.mediaBaseURL = [symLinkedMediaBaseURL URLByAppendingPathComponent:ATLMMediaViewControllerSymLinkedMediaTempPath].absoluteURL;
        if ([[NSFileManager defaultManager] fileExistsAtPath:symLinkedMediaBaseURL.path isDirectory:nil]) {
            [[NSFileManager defaultManager] removeItemAtURL:self.mediaBaseURL error:nil];
        }
        [[NSFileManager defaultManager] createDirectoryAtURL:self.mediaBaseURL withIntermediateDirectories:YES attributes:nil error:nil];
    }
    self.scrollView.pinchGestureRecognizer.enabled = self.zoomingEnabled;
    self.scrollView.panGestureRecognizer.enabled = self.zoomingEnabled;
    
    self.viewControllerConfigured = NO;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    if (self.viewControllerConfigured) {
        return;
    }
    [self loadLowResMedia];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if (self.viewControllerConfigured) {
        return;
    }
    [self loadFullResMedia];
    self.viewControllerConfigured = YES;
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self.progressView removeFromSuperview];
    [self done:nil];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    [self configureForAvailableSpace];
}

- (void)viewWillLayoutSubviews
{
    [super viewWillLayoutSubviews];
    self.progressView.frame = CGRectMake(0, self.navigationController.navigationBar.frame.size.height - ATLMMediaViewControllerProgressBarHeight, self.view.frame.size.width, ATLMMediaViewControllerProgressBarHeight);
}

#pragma mark - UIScrollViewDelegate

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView
{
    return self.lowResImageView;
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    if (self.zoomingEnabled) {
        [self configureForAvailableSpace];
    }
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView
{
    if (self.zoomingEnabled) {
        [self configureForAvailableSpace];
    }
}

#pragma mark - Gesture Recognizer Handler

- (void)doubleTapRecognized:(UIGestureRecognizer *)gestureRecognizer
{
    if (self.scrollView.minimumZoomScale == self.scrollView.maximumZoomScale || !self.zoomingEnabled) {
        return;
    }
    
    if (self.scrollView.zoomScale == self.scrollView.minimumZoomScale) {
        CGPoint tappedPoint;
        tappedPoint = [gestureRecognizer locationInView:self.lowResImageView];
        CGRect tappedRect = CGRectMake(tappedPoint.x, tappedPoint.y, 0, 0);
        [self.scrollView zoomToRect:tappedRect animated:YES];
    } else {
        [self.scrollView setZoomScale:self.scrollView.minimumZoomScale animated:YES];
    }
}

#pragma mark - Actions

- (void)share:(id)sender
{
    LYRMessagePart *fullResMediaMessagePart;
    if (ATLMessagePartForMIMEType(self.message, ATLMIMETypeImageGIF)) {
        fullResMediaMessagePart = ATLMessagePartForMIMEType(self.message, ATLMIMETypeImageGIF);
    } else if (ATLMessagePartForMIMEType(self.message, ATLMIMETypeImagePNG)) {
        fullResMediaMessagePart = ATLMessagePartForMIMEType(self.message, ATLMIMETypeImagePNG);
    } else if (ATLMessagePartForMIMEType(self.message, ATLMIMETypeVideoMP4)) {
        fullResMediaMessagePart = ATLMessagePartForMIMEType(self.message, ATLMIMETypeVideoMP4);
    } else if (ATLMessagePartForMIMEType(self.message, ATLMIMETypeImageJPEG)) {
        fullResMediaMessagePart = ATLMessagePartForMIMEType(self.message, ATLMIMETypeImageJPEG);
    }
    UIActivityViewController *activityViewController = [[UIActivityViewController alloc] initWithActivityItems:@[fullResMediaMessagePart.fileURL] applicationActivities:nil];
    [self presentViewController:activityViewController animated:YES completion:nil];
}

- (void)done:(id)sender
{
    // Removing the full-resolution image to save GPU resources when
    // animating the view controller POP.
    self.lowResImageView.hidden = NO;
    self.lowResImageView.alpha = 1.0f;
    [self.fullResImageView removeFromSuperview];
    self.fullResImageView = nil;
    self.fullResImage = nil;
    if (self.moviePlayerController) {
        [self.moviePlayerController pause];
    }
}

#pragma mark - Helpers

- (void)loadLowResMedia
{
    if (ATLMessagePartForMIMEType(self.message, ATLMIMETypeImageGIFPreview) || ATLMessagePartForMIMEType(self.message, ATLMIMETypeImageGIF)) {
        [self loadLowResGIFs];
    } else if (ATLMessagePartForMIMEType(self.message, ATLMIMETypeImageJPEGPreview) && !ATLMessagePartForMIMEType(self.message, ATLMIMETypeVideoMP4)) {
        [self loadLowResImages];
    } else if (ATLMessagePartForMIMEType(self.message, ATLMIMETypeImageJPEGPreview) && ATLMessagePartForMIMEType(self.message, ATLMIMETypeVideoMP4)) {
        [self loadLowResImages];
    }
}

- (void)loadFullResMedia
{
    if (ATLMessagePartForMIMEType(self.message, ATLMIMETypeImageGIF)) {
        [self downloadFullResMediaForMIMEType:ATLMIMETypeImageGIF];
    } else if (ATLMessagePartForMIMEType(self.message, ATLMIMETypeImagePNG)) {
        [self downloadFullResMediaForMIMEType:ATLMIMETypeImagePNG];
    } else if (ATLMessagePartForMIMEType(self.message, ATLMIMETypeVideoMP4)) {
        [self downloadFullResMediaForMIMEType:ATLMIMETypeVideoMP4];
    } else if (ATLMessagePartForMIMEType(self.message, ATLMIMETypeImageJPEG)) {
        [self downloadFullResMediaForMIMEType:ATLMIMETypeImageJPEG];
    }
}

- (void)loadLowResImages
{
    LYRMessagePart *lowResImagePart = ATLMessagePartForMIMEType(self.message, ATLMIMETypeImageJPEGPreview);
    LYRMessagePart *imageInfoPart = ATLMessagePartForMIMEType(self.message, ATLMIMETypeImageSize);
    if (!lowResImagePart) {
        // Default back to image/jpeg MIMEType
        lowResImagePart = ATLMessagePartForMIMEType(self.message, ATLMIMETypeImageJPEG);
    }
    
    // Retrieve low-res image from message part
    if (!(lowResImagePart.transferStatus == LYRContentTransferReadyForDownload || lowResImagePart.transferStatus == LYRContentTransferDownloading)) {
        if (lowResImagePart.fileURL) {
            self.lowResImage = [UIImage imageWithContentsOfFile:lowResImagePart.fileURL.path];
        } else {
            self.lowResImage = [UIImage imageWithData:lowResImagePart.data];
        }
        self.lowResImageView.image = self.lowResImage;
    }
    
    // Set the size of the canvas.
    if (imageInfoPart) {
        self.fullResImageSize = ATLImageSizeForJSONData(imageInfoPart.data);
    } else {
        if (self.lowResImage) {
            self.fullResImageSize = self.lowResImage.size;
        } else {
            return;
        }
    }
    
    self.scrollView.contentSize = self.fullResImageSize;
    self.mediaViewFrame = CGRectMake(0, 0, self.fullResImageSize.width, self.fullResImageSize.height);
    self.lowResImageView.frame = self.mediaViewFrame;
    [self viewDidLayoutSubviews];
}

- (void)loadLowResGIFs
{
    LYRMessagePart *lowResImagePart = ATLMessagePartForMIMEType(self.message, ATLMIMETypeImageGIFPreview);
    LYRMessagePart *imageInfoPart = ATLMessagePartForMIMEType(self.message, ATLMIMETypeImageSize);
    
    if (!lowResImagePart) {
        lowResImagePart = ATLMessagePartForMIMEType(self.message, ATLMIMETypeImageGIF);
    }
    
    // Retrieve low-res gif from message part
    if (!(lowResImagePart.transferStatus == LYRContentTransferReadyForDownload || lowResImagePart.transferStatus == LYRContentTransferDownloading)) {
        if (lowResImagePart.fileURL) {
            self.lowResImage = ATLAnimatedImageWithAnimatedGIFURL(lowResImagePart.fileURL);
        } else {
            self.lowResImage = ATLAnimatedImageWithAnimatedGIFData(lowResImagePart.data);
        }
        self.lowResImageView.image = self.lowResImage;
    }
    
    // Set the size of the canvas.
    if (imageInfoPart) {
        self.fullResImageSize = ATLImageSizeForJSONData(imageInfoPart.data);
    } else {
        if (self.lowResImage) {
            self.fullResImageSize = self.lowResImage.size;
        } else {
            return;
        }
    }
    
    self.scrollView.contentSize = self.fullResImageSize;
    self.mediaViewFrame = CGRectMake(0, 0, self.fullResImageSize.width, self.fullResImageSize.height);
    self.lowResImageView.frame = self.mediaViewFrame;
    [self viewDidLayoutSubviews];
}

- (void)loadFullResImage
{
    LYRMessagePart *fullResImagePart = ATLMessagePartForMIMEType(self.message, ATLMIMETypeImageJPEG);
    if (!fullResImagePart) {
        fullResImagePart = ATLMessagePartForMIMEType(self.message, ATLMIMETypeImagePNG);
    }
    
    // Retrieve hi-res image from message part
    if (!(fullResImagePart.transferStatus == LYRContentTransferReadyForDownload || fullResImagePart.transferStatus == LYRContentTransferDownloading)) {
        if (fullResImagePart.fileURL) {
            self.fullResImage = [UIImage imageWithContentsOfFile:fullResImagePart.fileURL.path];
        } else {
            self.fullResImage = [UIImage imageWithData:fullResImagePart.data];
        }
        
        self.fullResImageView.image = self.fullResImage;
        
        // Set the scrollview if we couldn't set it with the thumbnail sized image
        if (CGSizeEqualToSize(self.fullResImageSize, CGSizeZero)) {
            self.fullResImageSize = self.fullResImage.size;
            self.scrollView.contentSize = self.fullResImageSize;
            self.mediaViewFrame = CGRectMake(0, 0, self.fullResImageSize.width, self.fullResImageSize.height);
            self.lowResImageView.frame = self.mediaViewFrame;
        }
    }
    if (!self.fullResImage) {
        return;
    }
    self.fullResImageView.frame = self.mediaViewFrame;
    [UIView animateWithDuration:ATLMMediaViewControllerAnimationDuration animations:^{
        self.fullResImageView.alpha = 1.0f; // make the full res image appear.
        self.progressView.alpha = 0.0;
        self.navigationItem.rightBarButtonItem.enabled = YES;
    }];
    [self viewDidLayoutSubviews];
}

- (void)loadFullResGIFs
{
    LYRMessagePart *fullResImagePart = ATLMessagePartForMIMEType(self.message, ATLMIMETypeImageGIF);
    
    // Retrieve hi-res gif from message part
    if (!(fullResImagePart.transferStatus == LYRContentTransferReadyForDownload || fullResImagePart.transferStatus == LYRContentTransferDownloading)) {
        if (fullResImagePart.fileURL) {
            self.fullResImage = ATLAnimatedImageWithAnimatedGIFURL(fullResImagePart.fileURL);
        } else {
            self.fullResImage = ATLAnimatedImageWithAnimatedGIFData(fullResImagePart.data);
        }
        
        self.fullResImageView.image = self.fullResImage;
        
        // Set the scrollview if we couldn't set it with the thumbnail sized image
        if (CGSizeEqualToSize(self.fullResImageSize, CGSizeZero)) {
            self.fullResImageSize = self.fullResImage.size;
            self.scrollView.contentSize = self.fullResImageSize;
            self.mediaViewFrame = CGRectMake(0, 0, self.fullResImageSize.width, self.fullResImageSize.height);
            self.lowResImageView.frame = self.mediaViewFrame;
        }
    }
    if (!self.fullResImage) {
        return;
    }
    self.fullResImageView.frame = self.mediaViewFrame;
    [UIView animateWithDuration:ATLMMediaViewControllerAnimationDuration animations:^{
        self.fullResImageView.alpha = 1.0f; // make the full res image appear.
        self.progressView.alpha = 0.0;
        self.navigationItem.rightBarButtonItem.enabled = YES;
    }];
    [self viewDidLayoutSubviews];
}

- (void)loadFullResVideo
{
    LYRMessagePart *fullResVideoPart = ATLMessagePartForMIMEType(self.message, ATLMIMETypeVideoMP4);
    
    // Retrieve hi-res image from message part
    if (!(fullResVideoPart.transferStatus == LYRContentTransferReadyForDownload || fullResVideoPart.transferStatus == LYRContentTransferDownloading)) {
        if (!self.moviePlayerController) {
            self.moviePlayerController = [[MPMoviePlayerController alloc] initWithContentURL:fullResVideoPart.fileURL];
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(moviePlayerStateDidChange:) name:MPMoviePlayerLoadStateDidChangeNotification object:nil];
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(moviePlayerWillChangeFullScreenAppearance:) name:MPMoviePlayerWillEnterFullscreenNotification object:nil];
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(moviePlayerWillChangeFullScreenAppearance:) name:MPMoviePlayerWillExitFullscreenNotification object:nil];
            [self.view addSubview:self.moviePlayerController.view];
            [self.moviePlayerController prepareToPlay];
        } else {
            return;
        }
        CGFloat yOffset = self.navigationController.navigationBar.frame.size.height + self.navigationController.navigationBar.frame.origin.y;
        self.moviePlayerController.view.frame = CGRectMake(0, yOffset, self.view.frame.size.width, self.view.frame.size.height - yOffset);
        self.moviePlayerController.view.alpha = 0.0f;
        self.moviePlayerController.backgroundView.backgroundColor = [UIColor whiteColor];
        self.moviePlayerController.controlStyle = MPMovieControlStyleEmbedded;
    }
    if (!self.moviePlayerController) {
        return;
    }

    [self viewDidLayoutSubviews];
}

- (void)moviePlayerStateDidChange:(NSNotification *)notification
{
    MPMovieLoadState loadState = self.moviePlayerController.loadState;
    if (loadState & MPMovieLoadStatePlayable) {
        [UIView animateWithDuration:ATLMMediaViewControllerAnimationDuration animations:^{
            self.progressView.alpha = 0.0;
            self.moviePlayerController.view.alpha = 1.0f; // make the full res image appear.
            self.navigationItem.rightBarButtonItem.enabled = YES;
        }];
    }
}

- (void)moviePlayerWillChangeFullScreenAppearance:(NSNotification *)notification
{
    NSTimeInterval transitionDuration = [notification.userInfo[MPMoviePlayerFullscreenAnimationDurationUserInfoKey] floatValue];
    UIColor *moviePlayerBackgroundColorBackground;
    if ([notification.name isEqualToString:MPMoviePlayerWillEnterFullscreenNotification]) {
        moviePlayerBackgroundColorBackground = [UIColor blackColor];
    } else {
        moviePlayerBackgroundColorBackground = [UIColor whiteColor];
    }
    [UIView animateWithDuration:transitionDuration animations:^{
        self.moviePlayerController.backgroundView.backgroundColor = moviePlayerBackgroundColorBackground;
    }];
}

- (void)downloadFullResMediaForMIMEType:(NSString *)MIMEType
{
    LYRMessagePart *fullResMedia = ATLMessagePartForMIMEType(self.message, MIMEType);
    
    if (fullResMedia && (fullResMedia.transferStatus == LYRContentTransferReadyForDownload || fullResMedia.transferStatus == LYRContentTransferDownloading)) {
        NSError *error;
        LYRProgress *downloadProgress = [fullResMedia downloadContent:&error];
        if (!downloadProgress) {
            NSLog(@"problem downloading full resolution photo with %@", error);
            return;
        }
        downloadProgress.delegate = self;
        [fullResMedia addObserver:self forKeyPath:@"transferStatus" options:NSKeyValueObservingOptionNew context:nil];
        self.observedMessagePart = fullResMedia;
        if ([@[ATLMIMETypeImageJPEG, ATLMIMETypeImagePNG, ATLMIMETypeImageGIF] containsObject:MIMEType]) {
            self.title = @"Downloading Image...";
        } else if ([@[ATLMIMETypeVideoMP4] containsObject:MIMEType]) {
            self.title = @"Downloading Video...";
        }
        [UIView animateWithDuration:ATLMMediaViewControllerAnimationDuration animations:^{
            self.progressView.alpha = 1.0f;
        }];
    } else {
        if ([MIMEType isEqualToString:ATLMIMETypeImageGIF]) {
            [self loadFullResGIFs];
        } else if ([@[ATLMIMETypeImageJPEG, ATLMIMETypeImagePNG] containsObject:MIMEType]) {
            [self loadFullResImage];
        } else if ([@[ATLMIMETypeVideoMP4] containsObject:MIMEType]) {
            [self loadFullResVideo];
        }
    }
}

- (void)configureForAvailableSpace
{
    if (!self.view.superview) {
        return;
    }
    
    // We want to position and zoom the image based on the available size, i.e. so that it can be seen without being obstructed by the navigation bar or a toolbar.
    CGSize availableSize = self.scrollView.bounds.size;
    availableSize.height -= self.scrollView.contentInset.top;
    availableSize.height -= self.scrollView.contentInset.bottom;
    
    // We don't want to display the image larger than its native size.
    CGFloat maximumScale;
    if ((self.fullResImageSize.width / [[UIScreen mainScreen] scale] < self.view.frame.size.width) &&
        (self.fullResImageSize.height / [[UIScreen mainScreen] scale] < self.view.frame.size.height)) {
        // Fallback to default image scale;
        maximumScale = 1;
    } else {
        // Force device scale of the image (1:1 pixel mapping).
        maximumScale = 1 / [[UIScreen mainScreen] scale];
    }
    
    // The smallest we want to display the image is the size that it completely fits onscreen.
    CGFloat xFittedScale = availableSize.width / self.fullResImageSize.width;
    CGFloat yFittedScale = availableSize.height / self.fullResImageSize.height;
    CGFloat fittedScale = MIN(xFittedScale, yFittedScale);
    
    // If we're dealing with a small image then we only display it at its native size.
    CGFloat minimumScale = MIN(fittedScale, maximumScale);
    
    // If we're already at the minimum scale, we want to remain at that scale after our adjustments.
    BOOL atMinimumZoomScale = self.scrollView.zoomScale == self.scrollView.minimumZoomScale;
    self.scrollView.maximumZoomScale = maximumScale;
    self.scrollView.minimumZoomScale = minimumScale;
    if (atMinimumZoomScale) {
        self.scrollView.zoomScale = minimumScale;
    }
    
    CGRect imageViewFrame = self.lowResImageView.frame;
    
    // If the entire image width is onscreen then we horizontally center the image in the available space.
    if (CGRectGetWidth(imageViewFrame) < availableSize.width) {
        imageViewFrame.origin.x = (availableSize.width - CGRectGetWidth(imageViewFrame)) / 2;
    } else {
        imageViewFrame.origin.x = 0;
    }
    
    // If the entire image height is onscreen then we vertically center the image in the available space.
    if (CGRectGetHeight(imageViewFrame) < availableSize.height) {
        imageViewFrame.origin.y = (availableSize.height - CGRectGetHeight(imageViewFrame)) / 2;
    } else {
        imageViewFrame.origin.y = 0;
    }
    
    self.mediaViewFrame = imageViewFrame;
    self.lowResImageView.frame = imageViewFrame;
    self.fullResImageView.frame = imageViewFrame;
    if (self.moviePlayerController) {
        CGFloat yOffset = self.navigationController.navigationBar.frame.size.height + self.navigationController.navigationBar.frame.origin.y;
        self.moviePlayerController.view.frame = CGRectMake(0, yOffset, self.view.frame.size.width, self.view.frame.size.height - yOffset);
    }
}

#pragma mark - LYRProgress Delegate Implementation

- (void)progressDidChange:(LYRProgress *)progress
{
    // Queue UI updates onto the main thread, since LYRProgress performs
    // delegate callbacks from a background thread.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.progressView setProgress:progress.fractionCompleted animated:YES];
    });
}

#pragma mark - LYRMessagePart.transferStatus KVO notifications

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(LYRMessagePart *)messagePart change:(NSDictionary *)change context:(void *)context
{
    if (messagePart.transferStatus == LYRContentTransferComplete) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ATLMessagePartForMIMEType(self.message, ATLMIMETypeImageGIF)) {
                self.title = @"GIF Downloaded";
            } else if (ATLMessagePartForMIMEType(self.message, ATLMIMETypeVideoMP4)) {
                self.title = @"Video Downloaded";
            } else if (ATLMessagePartForMIMEType(self.message, ATLMIMETypeImageJPEG) || ATLMessagePartForMIMEType(self.message, ATLMIMETypeImagePNG)) {
                self.title = @"Image Downloaded";
            } else {
                self.title = @"Downloaded";
            }
            [self loadFullResMedia];
        });
    }
}

#pragma mark - UIPreviewActionItem

- (NSArray<id<UIPreviewActionItem>> *)previewActionItems {
    if (_previewActions == nil) {
        UIPreviewAction *closeAction = [UIPreviewAction
                                        actionWithTitle:@"Close"
                                        style:UIPreviewActionStyleDefault
                                        handler:^(UIPreviewAction * _Nonnull action,
                                                  UIViewController * _Nonnull previewViewController) {
                                            // ... code to handle action here
                                            // Think of something goo do put here
                                        }];
        
        
        
        _previewActions = @[closeAction];
    }
    return _previewActions;
}
@end
