/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "config.h"
#import "WKCaptureDevicePreviewController.h"

#if PLATFORM(MAC) && ENABLE(MEDIA_STREAM)

#import "Logging.h"
#import <pal/cocoa/AVFoundationSoftLink.h>
#import <wtf/MathExtras.h>
#import <wtf/OSObjectPtr.h>
#import <wtf/RetainPtr.h>

static const CGFloat preferredPreviewWidth = 320;
static const CGFloat preferredPreviewHeight = 240;

// Quietest level shown as non-zero. Raw dBFS runs to -160, which would leave the meter
// visually pinned at the bottom for ordinary room noise.
static const float audioLevelFloorInDBFS = -60;

@implementation WKCaptureDevicePreviewController {
    RetainPtr<NSView> _view;
    RetainPtr<AVCaptureSession> _session;
    RetainPtr<AVCaptureDeviceInput> _videoInput;
    RetainPtr<AVCaptureDeviceInput> _audioInput;
    RetainPtr<AVCaptureAudioDataOutput> _audioOutput;
    RetainPtr<AVCaptureVideoPreviewLayer> _previewLayer;
    OSObjectPtr<dispatch_queue_t> _queue;
}

- (instancetype)init
{
    if (!(self = [super init]))
        return nil;

    _queue = adoptOSObject(dispatch_queue_create("com.apple.WebKit.CaptureDevicePreview", DISPATCH_QUEUE_SERIAL));

    _view = adoptNS([[NSView alloc] initWithFrame:NSMakeRect(0, 0, preferredPreviewWidth, preferredPreviewHeight)]);
    [_view setWantsLayer:YES];

    return self;
}

- (void)dealloc
{
    [self stop];
    [super dealloc];
}

- (NSView *)view
{
    return _view.get();
}

- (RetainPtr<AVCaptureDeviceInput>)_inputForDeviceID:(NSString *)persistentID
{
    if (!persistentID.length)
        return nil;

    RetainPtr device = [PAL::getAVCaptureDeviceClassSingleton() deviceWithUniqueID:persistentID];
    if (!device)
        return nil;

    NSError *error = nil;
    RetainPtr input = adoptNS([PAL::allocAVCaptureDeviceInputInstance() initWithDevice:device.get() error:&error]);
    if (!input)
        RELEASE_LOG_ERROR(WebRTC, "WKCaptureDevicePreviewController unable to create capture input");

    return input;
}

- (void)_addVideoInput:(RetainPtr<AVCaptureDeviceInput>&&)input
{
    if (![_session canAddInput:input.get()]) {
        RELEASE_LOG_ERROR(WebRTC, "WKCaptureDevicePreviewController unable to add video input to session");
        return;
    }

    [_session addInput:input.get()];
    _videoInput = WTF::move(input);

    _previewLayer = adoptNS([PAL::allocAVCaptureVideoPreviewLayerInstance() initWithSession:_session.get()]);
    [_previewLayer setVideoGravity:AVLayerVideoGravityResizeAspectFill];
    [_previewLayer setFrame:[_view bounds]];
    [_previewLayer setAutoresizingMask:kCALayerWidthSizable | kCALayerHeightSizable];
    [[_view layer] addSublayer:_previewLayer.get()];
}

- (void)_addAudioInput:(RetainPtr<AVCaptureDeviceInput>&&)input
{
    if (![_session canAddInput:input.get()]) {
        RELEASE_LOG_ERROR(WebRTC, "WKCaptureDevicePreviewController unable to add audio input to session");
        return;
    }

    [_session addInput:input.get()];
    _audioInput = WTF::move(input);

    if (_audioOutput)
        return;

    // The output carries no delegate; it exists so the session forms an audio connection,
    // which is what AVFoundation populates the channel power levels on.
    _audioOutput = adoptNS([PAL::allocAVCaptureAudioDataOutputInstance() init]);
    if ([_session canAddOutput:_audioOutput.get()])
        [_session addOutput:_audioOutput.get()];
    else {
        RELEASE_LOG_ERROR(WebRTC, "WKCaptureDevicePreviewController unable to add audio output to session");
        _audioOutput = nil;
    }
}

- (void)startWithVideoDeviceID:(NSString *)videoPersistentID audioDeviceID:(NSString *)audioPersistentID
{
    if (_session)
        return;

    RetainPtr videoInput = [self _inputForDeviceID:videoPersistentID];
    RetainPtr audioInput = [self _inputForDeviceID:audioPersistentID];
    if (!videoInput && !audioInput)
        return;

    _session = adoptNS([PAL::allocAVCaptureSessionInstance() init]);

    if (videoInput)
        [self _addVideoInput:WTF::move(videoInput)];
    if (audioInput)
        [self _addAudioInput:WTF::move(audioInput)];

    if (!_videoInput && !_audioInput) {
        _session = nil;
        return;
    }

    // -startRunning blocks until the devices are configured, so it must not run on the main
    // thread; the prompt has to appear without waiting for the camera or microphone.
    RetainPtr sessionToStart = _session;
    dispatch_async(_queue.get(), ^{
        [sessionToStart startRunning];
    });
}

- (void)switchToVideoDeviceID:(NSString *)persistentID
{
    if (!_session) {
        [self startWithVideoDeviceID:persistentID audioDeviceID:nil];
        return;
    }

    RetainPtr input = [self _inputForDeviceID:persistentID];
    if (!input)
        return;

    // Reconfiguring in place keeps the session running. Stopping and restarting would blank
    // the preview and redo device setup on every menu change.
    [_session beginConfiguration];

    RetainPtr previousInput = _videoInput;
    if (previousInput)
        [_session removeInput:previousInput.get()];

    if ([_session canAddInput:input.get()]) {
        [_session addInput:input.get()];
        _videoInput = WTF::move(input);
    } else if (previousInput) {
        RELEASE_LOG_ERROR(WebRTC, "WKCaptureDevicePreviewController unable to switch video input, restoring previous device");
        [_session addInput:previousInput.get()];
    }

    [_session commitConfiguration];
}

- (void)switchToAudioDeviceID:(NSString *)persistentID
{
    if (!_session) {
        [self startWithVideoDeviceID:nil audioDeviceID:persistentID];
        return;
    }

    RetainPtr input = [self _inputForDeviceID:persistentID];
    if (!input)
        return;

    [_session beginConfiguration];

    RetainPtr previousInput = _audioInput;
    if (previousInput)
        [_session removeInput:previousInput.get()];

    _audioInput = nil;
    [self _addAudioInput:WTF::move(input)];

    if (!_audioInput && previousInput) {
        [_session addInput:previousInput.get()];
        _audioInput = WTF::move(previousInput);
    }

    [_session commitConfiguration];
}

- (float)normalizedAudioLevel
{
    if (!_audioOutput || !_audioInput)
        return 0;

    RetainPtr connection = [_audioOutput connectionWithMediaType:AVMediaTypeAudio];
    RetainPtr channel = [[connection audioChannels] firstObject];
    if (!channel)
        return 0;

    float level = [channel averagePowerLevel];
    if (!std::isfinite(level) || level <= audioLevelFloorInDBFS)
        return 0;

    return clampTo<float>((level - audioLevelFloorInDBFS) / -audioLevelFloorInDBFS, 0, 1);
}

- (void)stop
{
    RetainPtr session = WTF::move(_session);
    if (!session)
        return;

    _videoInput = nil;
    _audioInput = nil;
    _audioOutput = nil;

    [_previewLayer removeFromSuperlayer];
    _previewLayer = nil;

    dispatch_async(_queue.get(), ^{
        [session stopRunning];
    });
}

@end

#endif // PLATFORM(MAC) && ENABLE(MEDIA_STREAM)
