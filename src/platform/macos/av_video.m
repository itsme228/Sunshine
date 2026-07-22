/**
 * @file src/platform/macos/av_video.m
 * @brief Definitions for video capture on macOS.
 */
// local includes
#import "av_video.h"

@implementation AVVideo

- (id)initWithDisplay:(CGDirectDisplayID)displayID frameRate:(int)frameRate {
  self = [super init];

  CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
  if (!mode) {
    [self release];
    return nil;
  }

  self.displayID = displayID;
  self.pixelFormat = kCVPixelFormatType_32BGRA;
  self.frameWidth = (int) CGDisplayModeGetPixelWidth(mode);
  self.frameHeight = (int) CGDisplayModeGetPixelHeight(mode);
  self.minFrameDuration = CMTimeMake(1, frameRate);
  self.session = [[AVCaptureSession alloc] init];
  self.videoOutputs = [[NSMapTable alloc] init];
  self.captureCallbacks = [[NSMapTable alloc] init];
  self.captureSignals = [[NSMapTable alloc] init];

  CFRelease(mode);

  AVCaptureScreenInput *screenInput = [[AVCaptureScreenInput alloc] initWithDisplayID:self.displayID];
  [screenInput setMinFrameDuration:self.minFrameDuration];

  if ([self.session canAddInput:screenInput]) {
    [self.session addInput:screenInput];
  } else {
    [screenInput release];
    return nil;
  }

  [self.session startRunning];

  return self;
}

- (id)initWithCameraUniqueID:(NSString *)uniqueID frameRate:(int)frameRate {
  self = [super init];

  AVCaptureDevice *device = [AVCaptureDevice deviceWithUniqueID:uniqueID];
  if (!device) {
    [self release];
    return nil;
  }

  CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription);

  self.displayID = kCGNullDirectDisplay;
  self.pixelFormat = kCVPixelFormatType_32BGRA;
  self.frameWidth = (int) dims.width;
  self.frameHeight = (int) dims.height;
  self.minFrameDuration = CMTimeMake(1, frameRate);
  self.session = [[AVCaptureSession alloc] init];
  self.videoOutputs = [[NSMapTable alloc] init];
  self.captureCallbacks = [[NSMapTable alloc] init];
  self.captureSignals = [[NSMapTable alloc] init];

  NSError *error = nil;
  AVCaptureDeviceInput *deviceInput = [[AVCaptureDeviceInput alloc] initWithDevice:device error:&error];
  if (!deviceInput) {
    [self release];
    return nil;
  }

  if ([self.session canAddInput:deviceInput]) {
    [self.session addInput:deviceInput];
  } else {
    [deviceInput release];
    [self release];
    return nil;
  }

  // Best-effort: pin the camera's own frame rate for lowest latency instead of
  // relying solely on the AVCaptureVideoDataOutput min frame duration below.
  // Many cameras (most built-in FaceTime cameras included) only expose a
  // single fixed-rate range (e.g. 30fps, min == max) for their active
  // format -- setting a duration outside [minFrameDuration, maxFrameDuration]
  // is a hard error, not a clamp, and throws NSInvalidArgumentException
  // straight through Objective-C's exception mechanism (uncaught, since nothing
  // here is inside a @try), crashing the whole process. Clamp the requested
  // rate into whatever range the active format actually supports first.
  if ([device lockForConfiguration:&error]) {
    for (AVFrameRateRange *range in device.activeFormat.videoSupportedFrameRateRanges) {
      CMTime clamped = self.minFrameDuration;
      if (CMTimeCompare(clamped, range.minFrameDuration) < 0) {
        clamped = range.minFrameDuration;
      } else if (CMTimeCompare(clamped, range.maxFrameDuration) > 0) {
        clamped = range.maxFrameDuration;
      }
      device.activeVideoMinFrameDuration = clamped;
      device.activeVideoMaxFrameDuration = clamped;
      self.minFrameDuration = clamped;
      break;
    }
    [device unlockForConfiguration];
  }

  [self.session startRunning];

  return self;
}

- (void)dealloc {
  [self.videoOutputs release];
  [self.captureCallbacks release];
  [self.captureSignals release];
  [self.session stopRunning];
  [super dealloc];
}

- (void)setFrameWidth:(int)frameWidth frameHeight:(int)frameHeight {
  self.frameWidth = frameWidth;
  self.frameHeight = frameHeight;
}

- (dispatch_semaphore_t)capture:(FrameCallbackBlock)frameCallback {
  @synchronized(self) {
    AVCaptureVideoDataOutput *videoOutput = [[AVCaptureVideoDataOutput alloc] init];

    [videoOutput setVideoSettings:@{
      (NSString *) kCVPixelBufferPixelFormatTypeKey: [NSNumber numberWithUnsignedInt:self.pixelFormat],
      (NSString *) kCVPixelBufferWidthKey: [NSNumber numberWithInt:self.frameWidth],
      (NSString *) kCVPixelBufferHeightKey: [NSNumber numberWithInt:self.frameHeight],
      (NSString *) AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
    }];

    dispatch_queue_attr_t qos = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, DISPATCH_QUEUE_PRIORITY_HIGH);
    dispatch_queue_t recordingQueue = dispatch_queue_create("videoCaptureQueue", qos);
    [videoOutput setSampleBufferDelegate:self queue:recordingQueue];

    [self.session stopRunning];

    if ([self.session canAddOutput:videoOutput]) {
      [self.session addOutput:videoOutput];
    } else {
      [videoOutput release];
      return nil;
    }

    AVCaptureConnection *videoConnection = [videoOutput connectionWithMediaType:AVMediaTypeVideo];
    dispatch_semaphore_t signal = dispatch_semaphore_create(0);

    [self.videoOutputs setObject:videoOutput forKey:videoConnection];
    [self.captureCallbacks setObject:frameCallback forKey:videoConnection];
    [self.captureSignals setObject:signal forKey:videoConnection];

    [self.session startRunning];

    return signal;
  }
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
  didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
         fromConnection:(AVCaptureConnection *)connection {
  FrameCallbackBlock callback = [self.captureCallbacks objectForKey:connection];

  if (callback != nil) {
    if (!callback(sampleBuffer)) {
      @synchronized(self) {
        [self.session stopRunning];
        [self.captureCallbacks removeObjectForKey:connection];
        [self.session removeOutput:[self.videoOutputs objectForKey:connection]];
        [self.videoOutputs removeObjectForKey:connection];
        dispatch_semaphore_signal([self.captureSignals objectForKey:connection]);
        [self.captureSignals removeObjectForKey:connection];
        [self.session startRunning];
      }
    }
  }
}

@end
