#import "CameraRenderController.h"
#import <CoreVideo/CVOpenGLESTextureCache.h>
#import <GLKit/GLKit.h>
#import <OpenGLES/ES2/glext.h>

@implementation CameraRenderController
@synthesize context = _context;
@synthesize delegate;


- (CameraRenderController *)init {
  if (self = [super init]) {
    self.renderLock = [[NSLock alloc] init];
  }
  return self;
}

- (void)loadView {
    
    [super loadView];
    if (self.view == nil) {
        self.view = [[UIView alloc] init];
    }
    
    self.glkView = [[GLKView alloc] init];
    [self.glkView setBackgroundColor:[UIColor blackColor]];
    
    [self.view setBackgroundColor:[UIColor yellowColor]];
    [self.view addSubview:self.glkView];
}

- (void)viewDidLoad {
  [super viewDidLoad];

  self.context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];

  if (!self.context) {
    NSLog(@"Failed to create ES context");
  }

  CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, self.context, NULL, &_videoTextureCache);
  if (err) {
    NSLog(@"Error at CVOpenGLESTextureCacheCreate %d", err);
    return;
  }

  self.glkView.context = self.context;
  self.glkView.drawableDepthFormat = GLKViewDrawableDepthFormat24;
  self.glkView.contentMode = UIViewContentModeScaleToFill;

  glGenRenderbuffers(1, &_renderBuffer);
  glBindRenderbuffer(GL_RENDERBUFFER, _renderBuffer);

  self.ciContext = [CIContext contextWithEAGLContext:self.context];

  if (self.dragEnabled) {
    //add drag action listener
    NSLog(@"Enabling view dragging");
    UIPanGestureRecognizer *drag = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.glkView addGestureRecognizer:drag];
  }

  if (self.tapToTakePicture) {
    //tap to take picture
    UITapGestureRecognizer *takePictureTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTakePictureTap:)];
    [self.glkView addGestureRecognizer:takePictureTap];
  }

  self.glkView.userInteractionEnabled = self.dragEnabled || self.tapToTakePicture;
}

- (void) viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(appplicationIsActive:)
                                               name:UIApplicationDidBecomeActiveNotification
                                             object:nil];

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(applicationEnteredForeground:)
                                               name:UIApplicationWillEnterForegroundNotification
                                             object:nil];

  dispatch_async(self.sessionManager.sessionQueue, ^{
      NSLog(@"Starting session");
      [self.sessionManager.session startRunning];
      });
}

- (void) viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];

  [[NSNotificationCenter defaultCenter] removeObserver:self
                                                  name:UIApplicationDidBecomeActiveNotification
                                                object:nil];

  [[NSNotificationCenter defaultCenter] removeObserver:self
                                                  name:UIApplicationWillEnterForegroundNotification
                                                object:nil];

  dispatch_async(self.sessionManager.sessionQueue, ^{
      NSLog(@"Stopping session");
      [self.sessionManager.session stopRunning];
      });
}

- (void) handleTakePictureTap:(UITapGestureRecognizer*)recognizer {
  NSLog(@"handleTakePictureTap");
  [self.delegate invokeTakePicture];
}

- (IBAction)handlePan:(UIPanGestureRecognizer *)recognizer {
        CGPoint translation = [recognizer translationInView:self.view];
        recognizer.view.center = CGPointMake(recognizer.view.center.x + translation.x,
            recognizer.view.center.y + translation.y);
        [recognizer setTranslation:CGPointMake(0, 0) inView:self.view];
}

- (void) appplicationIsActive:(NSNotification *)notification {
  dispatch_async(self.sessionManager.sessionQueue, ^{
      NSLog(@"Starting session");
      [self.sessionManager.session startRunning];
      });
}

- (void) applicationEnteredForeground:(NSNotification *)notification {
  dispatch_async(self.sessionManager.sessionQueue, ^{
      NSLog(@"Stopping session");
      [self.sessionManager.session stopRunning];
      });
}

-(void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
  if ([self.renderLock tryLock]) {
    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)CMSampleBufferGetImageBuffer(sampleBuffer);
    CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];


    CGFloat scaleHeight = self.view.frame.size.height/image.extent.size.height;
    CGFloat scaleWidth = self.view.frame.size.width/image.extent.size.width;

    CGFloat scale, x, y;
    if (scaleHeight < scaleWidth) {
      scale = scaleWidth;
      x = 0;
      y = ((scale * image.extent.size.height) - self.view.frame.size.height ) / 2;
    } else {
      scale = scaleHeight;
      x = ((scale * image.extent.size.width) - self.view.frame.size.width )/ 2;
      y = 0;
    }

    // scale - translate
    CGAffineTransform xscale = CGAffineTransformMakeScale(scale, scale);
    CGAffineTransform xlate = CGAffineTransformMakeTranslation(-x, -y);
    CGAffineTransform xform =  CGAffineTransformConcat(xscale, xlate);

    CIFilter *centerFilter = [CIFilter filterWithName:@"CIAffineTransform"  keysAndValues:
      kCIInputImageKey, image,
      kCIInputTransformKey, [NSValue valueWithBytes:&xform objCType:@encode(CGAffineTransform)],
      nil];

    CIImage *transformedImage = [centerFilter outputImage];

    // crop
    CIFilter *cropFilter = [CIFilter filterWithName:@"CICrop"];
    CIVector *cropRect = [CIVector vectorWithX:0 Y:0 Z:self.view.frame.size.width W:self.view.frame.size.height];
    [cropFilter setValue:transformedImage forKey:kCIInputImageKey];
    [cropFilter setValue:cropRect forKey:@"inputRectangle"];
    CIImage *croppedImage = [cropFilter outputImage];

    //fix front mirroring
    if (self.sessionManager.defaultCamera == AVCaptureDevicePositionFront) {
      CGAffineTransform matrix = CGAffineTransformTranslate(CGAffineTransformMakeScale(-1, 1), 0, croppedImage.extent.size.height);
      croppedImage = [croppedImage imageByApplyingTransform:matrix];
    }

    self.latestFrame = croppedImage;

    CGFloat pointScale;
    if ([[UIScreen mainScreen] respondsToSelector:@selector(nativeScale)]) {
      pointScale = [[UIScreen mainScreen] nativeScale];
    } else {
      pointScale = [[UIScreen mainScreen] scale];
    }
    CGRect dest = CGRectMake(0, 0, self.view.frame.size.width*pointScale, self.view.frame.size.height*pointScale);

    [self.ciContext drawImage:croppedImage inRect:dest fromRect:[croppedImage extent]];
    [self.context presentRenderbuffer:GL_RENDERBUFFER];
    [self.glkView display];
    [self.renderLock unlock];
  }
}

- (void)viewDidUnload {
  [super viewDidUnload];

  if ([EAGLContext currentContext] == self.context) {
    [EAGLContext setCurrentContext:nil];
  }
  self.context = nil;
}

- (void)didReceiveMemoryWarning {
  [super didReceiveMemoryWarning];
  // Release any cached data, images, etc. that aren't in use.
}

- (BOOL)shouldAutorotate {
  return YES;
}

-(void) willRotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration {
  [self.sessionManager updateOrientation:[self.sessionManager getCurrentOrientation:toInterfaceOrientation]];
}

@end
