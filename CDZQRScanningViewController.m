//
//  CDZQRScanningViewController.m
//
//  Created by Chris Dzombak on 10/27/13.
//  Copyright (c) 2013 Chris Dzombak. All rights reserved.
//

#import "CDZQRScanningViewController.h"
#import <AVFoundation/AVFoundation.h>

static AVCaptureVideoOrientation CDZVideoOrientationFromInterfaceOrientation(UIInterfaceOrientation interfaceOrientation)
{
    switch (interfaceOrientation) {
        case UIInterfaceOrientationUnknown:
        case UIInterfaceOrientationPortrait:
            return AVCaptureVideoOrientationPortrait;
            break;
        case UIInterfaceOrientationLandscapeLeft:
            return AVCaptureVideoOrientationLandscapeLeft;
            break;
        case UIInterfaceOrientationLandscapeRight:
            return AVCaptureVideoOrientationLandscapeRight;
            break;
        case UIInterfaceOrientationPortraitUpsideDown:
            return AVCaptureVideoOrientationPortraitUpsideDown;
            break;
    }
}

static const float CDZQRScanningTorchLevel = 0.25;
static const NSTimeInterval CDZQRScanningTorchActivationDelay = 0.25;

NSString * const CDZQRScanningErrorDomain = @"com.cdzombak.qrscanningviewcontroller";



@interface _CDZQRResult : NSObject <CDZQRResult>

@property (nonatomic, readonly) NSString *capturedString;
@property (nonatomic, copy, readonly) dispatch_block_t resumeHandler;

- (instancetype)initWithResult:(NSString *)result resumeHandler:(dispatch_block_t)resumeHandler;

@end

@implementation _CDZQRResult

- (instancetype)initWithResult:(NSString *)result resumeHandler:(dispatch_block_t)resumeHandler
{
    if (self = [super init]) {
        _capturedString = result;
        _resumeHandler = resumeHandler;
    }
    return self;
}

- (void)resumeScanning
{
    self.resumeHandler();
}

@end


@interface CDZQRScanningViewController () <AVCaptureMetadataOutputObjectsDelegate>

@property (nonatomic, readonly) NSMutableArray *overallCapturedStrings;

@property (nonatomic, readonly) AVCaptureSession *avSession;
@property (nonatomic, readonly) AVCaptureDevice *captureDevice;
@property (nonatomic, readonly) AVCaptureVideoPreviewLayer *previewLayer;

@end



@implementation CDZQRScanningViewController

+ (AVCaptureDevice *)frontFacingCamera
{
    for (AVCaptureDevice *device in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
        if (device.position == AVCaptureDevicePositionFront) {
            return device;
        }
    }

    return [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
}

+ (AVCaptureDevice *)backFacingCamera
{
    for (AVCaptureDevice *device in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
        if (device.position == AVCaptureDevicePositionBack) {
            return device;
        }
    }

    return [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
}

- (instancetype)initWithMetadataObjectTypes:(NSArray *)metadataObjectTypes
                                     device:(CDZQRCameraDevice)cameraDevice
                                 completion:(CDZQRCompletionHandler)completionHandler
{
    if (self = [super init]) {
        self.title = NSLocalizedString(@"Scan QR Code", @"");

        _metadataObjectTypes = metadataObjectTypes;
        _avSession = [[AVCaptureSession alloc] init];
        _completionHandler = completionHandler;
        _overallCapturedStrings = [NSMutableArray array];

        AVCaptureDevice *captureDevice = nil;
        switch (cameraDevice) {
            case CDZQRCameraDeviceFrontFacing:
                captureDevice = [CDZQRScanningViewController frontFacingCamera];
                break;
            case CDZQRCameraDeviceBackFacing:
                captureDevice = [CDZQRScanningViewController backFacingCamera];
        }

        _captureDevice = captureDevice;
        if ([_captureDevice isLowLightBoostSupported] && [_captureDevice lockForConfiguration:nil]) {
            _captureDevice.automaticallyEnablesLowLightBoostWhenAvailable = YES;
            [_captureDevice unlockForConfiguration];
        }
    }
    return self;
}

- (instancetype)initWithDevice:(CDZQRCameraDevice)cameraDevice
                    completion:(CDZQRCompletionHandler)completionHandler
{
    return [self initWithMetadataObjectTypes:@[ AVMetadataObjectTypeQRCode ] device:cameraDevice completion:completionHandler];
}

- (instancetype)initWithCompletion:(CDZQRCompletionHandler)completionHandler
{
    return [self initWithDevice:CDZQRCameraDeviceBackFacing completion:completionHandler];
}

- (void)dealloc
{
    [self.avSession stopRunning];
}

- (void)loadView
{
    [super loadView];

    _previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:self.avSession];
    _previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    _previewLayer.frame = self.view.bounds;
    [self.view.layer addSublayer:_previewLayer];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor blackColor];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(_cancelTapped:)];

    UILongPressGestureRecognizer *torchGestureRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleTorchRecognizerTap:)];
    torchGestureRecognizer.minimumPressDuration = CDZQRScanningTorchActivationDelay;
    [self.view addGestureRecognizer:torchGestureRecognizer];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        [self.avSession beginConfiguration];

        NSError *error = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:self.captureDevice error:&error];
        if (input && [self.avSession canAddInput:input]) {
            [self.avSession addInput:input];
        } else {
            NSLog(@"QRScanningViewController: Error getting input device: %@", error);
            [self.avSession commitConfiguration];

            dispatch_async(dispatch_get_main_queue(), ^{
                self.completionHandler(nil, error);
            });
            return;
        }

        AVCaptureMetadataOutput *output = [[AVCaptureMetadataOutput alloc] init];
        [self.avSession addOutput:output];
        for (NSString *type in self.metadataObjectTypes) {
            if (![output.availableMetadataObjectTypes containsObject:type]) {
                [self.avSession commitConfiguration];

                dispatch_async(dispatch_get_main_queue(), ^{
                    NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Unable to scan object of type %@", type] };
                    NSError *error = [NSError errorWithDomain:CDZQRScanningErrorDomain code:CDZQRScanningViewControllerErrorUnavailableMetadataObjectType userInfo:userInfo];
                    self.completionHandler(nil, error);
                });
                return;
            }
        }

        output.metadataObjectTypes = self.metadataObjectTypes;
        [output setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];

        [self.avSession commitConfiguration];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.view setNeedsLayout];
            [self.view layoutIfNeeded];

            [self.avSession startRunning];
        });
    });
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];

    CGRect layerRect = self.view.bounds;
    self.previewLayer.bounds = layerRect;
    self.previewLayer.position = CGPointMake(CGRectGetMidX(layerRect), CGRectGetMidY(layerRect));

    if (self.previewLayer.connection.isVideoOrientationSupported) {
        self.previewLayer.connection.videoOrientation = CDZVideoOrientationFromInterfaceOrientation([UIApplication sharedApplication].statusBarOrientation);
    }
}

#pragma mark - UI Actions

- (void)_cancelTapped:(UIBarButtonItem *)sender
{
    self.completionHandler(nil, nil);
}

#pragma mark - Torch

- (void)handleTorchRecognizerTap:(UIGestureRecognizer *)sender
{
    switch(sender.state) {
        case UIGestureRecognizerStateBegan:
            [self _turnTorchOn];
            break;
        case UIGestureRecognizerStateChanged:
        case UIGestureRecognizerStatePossible:
            // no-op
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateFailed:
        case UIGestureRecognizerStateCancelled:
            [self _turnTorchOff];
            break;
    }
}

- (void)_turnTorchOn
{
    if (self.captureDevice.hasTorch && self.captureDevice.torchAvailable && [self.captureDevice isTorchModeSupported:AVCaptureTorchModeOn] && [self.captureDevice lockForConfiguration:nil]) {
        [self.captureDevice setTorchModeOnWithLevel:CDZQRScanningTorchLevel error:nil];
        [self.captureDevice unlockForConfiguration];
    }
}

- (void)_turnTorchOff
{
    if (self.captureDevice.hasTorch && [self.captureDevice isTorchModeSupported:AVCaptureTorchModeOff] && [self.captureDevice lockForConfiguration:nil]) {
        self.captureDevice.torchMode = AVCaptureTorchModeOff;
        [self.captureDevice unlockForConfiguration];
    }
}

- (void)stopScanning
{
    _capturedString = nil;
    [self.avSession stopRunning];
}

- (void)resumeScanning
{
    _capturedString = nil;
    [self.avSession startRunning];
}

#pragma mark - AVCaptureMetadataOutputObjectsDelegate

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputMetadataObjects:(NSArray *)metadataObjects fromConnection:(AVCaptureConnection *)connection
{
    if (self.capturedString) {
        return;
    }

    NSString *result = nil;
    for (AVMetadataMachineReadableCodeObject *metadata in metadataObjects) {
        if ([self.metadataObjectTypes containsObject:metadata.type]) {
            result = metadata.stringValue;
            break;
        }
    }

    if (result && ![self.overallCapturedStrings containsObject:result]) {
        _capturedString = result;
        [self.overallCapturedStrings addObject:result];
        [self.avSession stopRunning];

        _CDZQRResult *result = [[_CDZQRResult alloc] initWithResult:_capturedString resumeHandler:^{
            _capturedString = nil;
            [self.avSession startRunning];
        }];
        
        self.completionHandler(result, nil);
    }
}

@end
