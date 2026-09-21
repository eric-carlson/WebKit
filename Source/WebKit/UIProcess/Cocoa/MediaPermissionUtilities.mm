/*
 * Copyright (C) 2020-2021 Apple Inc. All rights reserved.
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
#import "MediaPermissionUtilities.h"

#import "SandboxUtilities.h"
#import "WKWebViewInternal.h"
#import "WebPageProxy.h"
#import <WebCore/LocalizedStrings.h>
#import <WebCore/SecurityOriginData.h>
#import <mutex>
#import <wtf/BlockPtr.h>
#import <wtf/URLHelpers.h>
#import <wtf/cocoa/TypeCastsCocoa.h>
#import <wtf/spi/cf/CFBundleSPI.h>
#import <wtf/spi/darwin/SandboxSPI.h>

#if PLATFORM(IOS_FAMILY)
#import "UIKitUtilities.h"
#endif

#import "TCCSoftLink.h"
#import <pal/cocoa/AVFoundationSoftLink.h>
#import <pal/cocoa/SpeechSoftLink.h>

#if PLATFORM(MAC) && ENABLE(MEDIA_STREAM)
#import "WKCaptureDevicePreviewController.h"
#import <wtf/WeakObjCPtr.h>

static const CGFloat devicePopUpHeight = 25;
static const CGFloat audioLevelIndicatorHeight = 12;
static const CGFloat chooserElementSpacing = 8;
static const CGFloat previewBadgeInset = 8;
static const NSTimeInterval audioLevelUpdateInterval = 1.0 / 15;

@interface WKCaptureDeviceChooser : NSObject {
    RetainPtr<NSView> _view;
    RetainPtr<NSPopUpButton> _videoPopUp;
    RetainPtr<NSPopUpButton> _audioPopUp;
    RetainPtr<NSLevelIndicator> _audioLevelIndicator;
    RetainPtr<NSTimer> _audioLevelTimer;
    RetainPtr<NSButton> _allowButton;
    RetainPtr<WKCaptureDevicePreviewController> _preview;
    Vector<WebCore::CaptureDevice> _videoDevices;
    Vector<WebCore::CaptureDevice> _audioDevices;
    BOOL _showsVideo;
    BOOL _showsAudio;
}

- (instancetype)initWithVideoDevices:(Vector<WebCore::CaptureDevice>&&)videoDevices audioDevices:(Vector<WebCore::CaptureDevice>&&)audioDevices;
- (NSView *)view;
- (NSString *)selectedVideoDeviceID;
- (NSString *)selectedAudioDeviceID;
- (void)setAllowButton:(NSButton *)allowButton;
- (void)updateWithVideoDevices:(Vector<WebCore::CaptureDevice>&&)videoDevices audioDevices:(Vector<WebCore::CaptureDevice>&&)audioDevices;
- (void)stop;

@end

@implementation WKCaptureDeviceChooser

- (instancetype)initWithVideoDevices:(Vector<WebCore::CaptureDevice>&&)videoDevices audioDevices:(Vector<WebCore::CaptureDevice>&&)audioDevices
{
    if (!(self = [super init]))
        return nil;

    _videoDevices = WTF::move(videoDevices);
    _audioDevices = WTF::move(audioDevices);
    _showsVideo = !_videoDevices.isEmpty();
    _showsAudio = !_audioDevices.isEmpty();
    _preview = adoptNS([[WKCaptureDevicePreviewController alloc] init]);

    RetainPtr previewView = [_preview view];
    CGFloat width = NSWidth([previewView frame]);
    CGFloat previewHeight = NSHeight([previewView frame]);

    // Frames are laid out bottom-up before the container exists, because the container's
    // height depends on which of the two device types this request actually asked for.
    CGFloat y = 0;
    NSRect audioPopUpFrame = NSZeroRect;
    NSRect audioLevelFrame = NSZeroRect;
    NSRect videoPopUpFrame = NSZeroRect;
    NSRect previewFrame = NSZeroRect;

    if (_showsAudio) {
        audioPopUpFrame = NSMakeRect(0, y, width, devicePopUpHeight);
        y += devicePopUpHeight + chooserElementSpacing;
        audioLevelFrame = NSMakeRect(0, y, width, audioLevelIndicatorHeight);
        y += audioLevelIndicatorHeight + chooserElementSpacing;
    }

    if (_showsVideo) {
        videoPopUpFrame = NSMakeRect(0, y, width, devicePopUpHeight);
        y += devicePopUpHeight + chooserElementSpacing;
        previewFrame = NSMakeRect(0, y, width, previewHeight);
        y += previewHeight;
    }

    _view = adoptNS([[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, y)]);

    if (_showsVideo) {
        [previewView setFrameOrigin:previewFrame.origin];
        [_view addSubview:previewView.get()];

        RetainPtr badge = adoptNS([[NSTextField alloc] initWithFrame:NSZeroRect]);
        [badge setStringValue:WEB_UI_STRING_KEY(@"Preview", "Preview (usermedia)", @"Badge label identifying the live camera preview in the user media prompt").createNSString().get()];
        [badge setEditable:NO];
        [badge setSelectable:NO];
        [badge setBordered:NO];
        [badge setDrawsBackground:YES];
        [badge setBackgroundColor:[NSColor controlAccentColor]];
        [badge setTextColor:[NSColor alternateSelectedControlTextColor]];
        [badge sizeToFit];
        [badge setFrameOrigin:NSMakePoint(NSMaxX(previewFrame) - NSWidth([badge frame]) - previewBadgeInset, NSMaxY(previewFrame) - NSHeight([badge frame]) - previewBadgeInset)];
        [_view addSubview:badge.get()];

        _videoPopUp = adoptNS([[NSPopUpButton alloc] initWithFrame:videoPopUpFrame pullsDown:NO]);
        [_videoPopUp setTarget:self];
        [_videoPopUp setAction:@selector(_selectedVideoDeviceDidChange:)];
        [_view addSubview:_videoPopUp.get()];
    }

    if (_showsAudio) {
        _audioLevelIndicator = adoptNS([[NSLevelIndicator alloc] initWithFrame:audioLevelFrame]);
        [_audioLevelIndicator setLevelIndicatorStyle:NSLevelIndicatorStyleContinuousCapacity];
        [_audioLevelIndicator setMinValue:0];
        [_audioLevelIndicator setMaxValue:1];
        [_audioLevelIndicator setDoubleValue:0];
        [_audioLevelIndicator setEditable:NO];
        [_view addSubview:_audioLevelIndicator.get()];

        _audioPopUp = adoptNS([[NSPopUpButton alloc] initWithFrame:audioPopUpFrame pullsDown:NO]);
        [_audioPopUp setTarget:self];
        [_audioPopUp setAction:@selector(_selectedAudioDeviceDidChange:)];
        [_view addSubview:_audioPopUp.get()];
    }

    [self _rebuildMenusPreservingVideoSelection:nil audioSelection:nil];

    [_preview startWithVideoDeviceID:[self selectedVideoDeviceID] audioDeviceID:[self selectedAudioDeviceID]];

    if (_showsAudio) {
        // Weak, because NSTimer retains its block and the chooser owns the timer.
        WeakObjCPtr<WKCaptureDeviceChooser> weakSelf { self };
        _audioLevelTimer = [NSTimer scheduledTimerWithTimeInterval:audioLevelUpdateInterval repeats:YES block:makeBlockPtr([weakSelf](NSTimer *) mutable {
            if (RetainPtr strongSelf = weakSelf.get())
                [strongSelf _updateAudioLevel];
        }).get()];
    }

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

- (NSString *)_selectedDeviceIDForPopUp:(NSPopUpButton *)popUp devices:(const Vector<WebCore::CaptureDevice>&)devices
{
    if (NSString *deviceID = dynamic_objc_cast<NSString>([[popUp selectedItem] representedObject]))
        return deviceID;

    if (devices.isEmpty())
        return nil;

    return devices[0].persistentId().createNSString().autorelease();
}

- (NSString *)selectedVideoDeviceID
{
    return [self _selectedDeviceIDForPopUp:_videoPopUp.get() devices:_videoDevices];
}

- (NSString *)selectedAudioDeviceID
{
    return [self _selectedDeviceIDForPopUp:_audioPopUp.get() devices:_audioDevices];
}

- (void)_rebuildMenu:(NSPopUpButton *)popUp devices:(const Vector<WebCore::CaptureDevice>&)devices reselecting:(NSString *)deviceIDToReselect
{
    if (!popUp)
        return;

    // Menu items are built directly because -addItemWithTitle: drops duplicate titles,
    // and two devices can share a label while still needing separate entries.
    RetainPtr menu = adoptNS([[NSMenu alloc] init]);
    NSInteger indexToSelect = NSNotFound;

    for (auto& device : devices) {
        RetainPtr title = device.label().createNSString();
        RetainPtr item = adoptNS([[NSMenuItem alloc] initWithTitle:title.get() action:nil keyEquivalent:@""]);
        RetainPtr deviceID = device.persistentId().createNSString();
        [item setRepresentedObject:deviceID.get()];
        [item setToolTip:title.get()];

        if (indexToSelect == NSNotFound && deviceIDToReselect && [deviceID isEqualToString:deviceIDToReselect])
            indexToSelect = [menu numberOfItems];

        [menu addItem:item.get()];
    }

    [popUp setMenu:menu.get()];

    if (!devices.isEmpty())
        [popUp selectItemAtIndex:indexToSelect == NSNotFound ? 0 : indexToSelect];

    [popUp setHidden:devices.size() < 2];
    [popUp setEnabled:devices.size() > 1];
}

- (void)_rebuildMenusPreservingVideoSelection:(NSString *)videoDeviceID audioSelection:(NSString *)audioDeviceID
{
    [self _rebuildMenu:_videoPopUp.get() devices:_videoDevices reselecting:videoDeviceID];
    [self _rebuildMenu:_audioPopUp.get() devices:_audioDevices reselecting:audioDeviceID];
}

- (void)setAllowButton:(NSButton *)allowButton
{
    _allowButton = allowButton;
    [self _updateAllowButtonEnablement];
}

- (void)_updateAllowButtonEnablement
{
    // A kind the request asked for and that has since lost every device makes the request
    // unsatisfiable, so granting it would hand the page a stream it cannot build. This covers
    // a camera-and-microphone request losing only one of the two, not just losing everything.
    bool canStillSatisfyRequest = !(_showsVideo && _videoDevices.isEmpty()) && !(_showsAudio && _audioDevices.isEmpty());
    [_allowButton setEnabled:canStillSatisfyRequest];
}

- (void)updateWithVideoDevices:(Vector<WebCore::CaptureDevice>&&)videoDevices audioDevices:(Vector<WebCore::CaptureDevice>&&)audioDevices
{
    RetainPtr previousVideo = [self selectedVideoDeviceID];
    RetainPtr previousAudio = [self selectedAudioDeviceID];

    _videoDevices = WTF::move(videoDevices);
    _audioDevices = WTF::move(audioDevices);
    [self _rebuildMenusPreservingVideoSelection:previousVideo.get() audioSelection:previousAudio.get()];
    [self _updateAllowButtonEnablement];

    if (_videoDevices.isEmpty() && _audioDevices.isEmpty()) {
        [_preview stop];
        return;
    }

    // Only disturb a running device when the one being previewed is gone; otherwise the image
    // or meter would break on every unrelated attach or detach.
    RetainPtr nowVideo = [self selectedVideoDeviceID];
    if (![nowVideo isEqualToString:previousVideo.get()])
        [_preview switchToVideoDeviceID:nowVideo.get()];

    RetainPtr nowAudio = [self selectedAudioDeviceID];
    if (![nowAudio isEqualToString:previousAudio.get()])
        [_preview switchToAudioDeviceID:nowAudio.get()];
}

- (void)_updateAudioLevel
{
    [_audioLevelIndicator setDoubleValue:[_preview normalizedAudioLevel]];
}

- (void)_selectedVideoDeviceDidChange:(id)sender
{
    [_preview switchToVideoDeviceID:[self selectedVideoDeviceID]];
}

- (void)_selectedAudioDeviceDidChange:(id)sender
{
    [_preview switchToAudioDeviceID:[self selectedAudioDeviceID]];
}

- (void)stop
{
    [_audioLevelTimer invalidate];
    _audioLevelTimer = nil;
    [_preview stop];
}

@end

#endif // PLATFORM(MAC) && ENABLE(MEDIA_STREAM)

namespace WebKit {

bool checkSandboxRequirementForType(MediaPermissionType type)
{
#if PLATFORM(MAC)
    auto checkFunction = [](ASCIILiteral operation) {
        if (!currentProcessIsSandboxed())
            return true;

        int result = sandbox_check(getpid(), operation, static_cast<enum sandbox_filter_type>(SANDBOX_CHECK_NO_REPORT | SANDBOX_FILTER_NONE));
        if (result == -1)
            SAFE_WTFLOGALWAYS("Error checking '%s' sandbox access, errno=%ld", operation, (long)errno);
        return !result;
    };

    switch (type) {
    case MediaPermissionType::Audio:
        static bool isAudioEntitled = checkFunction("device-microphone"_s);
        return isAudioEntitled;
    case MediaPermissionType::Video:
        static bool isVideoEntitled = checkFunction("device-camera"_s);
        return isVideoEntitled;
    }
#endif
    return true;
}

bool checkUsageDescriptionStringForType(MediaPermissionType type)
{
    switch (type) {
    case MediaPermissionType::Audio:
        static TCCAccessPreflightResult audioAccess = TCCAccessPreflight(get_TCC_kTCCServiceMicrophoneSingleton(), NULL);
        if (audioAccess == kTCCAccessPreflightGranted)
            return true;
        static bool hasMicrophoneDescriptionString= dynamic_objc_cast<NSString>(NSBundle.mainBundle.infoDictionary[@"NSMicrophoneUsageDescription"]).length > 0;
        return hasMicrophoneDescriptionString;
    case MediaPermissionType::Video:
        static TCCAccessPreflightResult videoAccess = TCCAccessPreflight(get_TCC_kTCCServiceCameraSingleton(), NULL);
        if (videoAccess == kTCCAccessPreflightGranted)
            return true;
        static bool hasCameraDescriptionString = dynamic_objc_cast<NSString>(NSBundle.mainBundle.infoDictionary[@"NSCameraUsageDescription"]).length > 0;
        return hasCameraDescriptionString;
    }
}

bool checkUsageDescriptionStringForSpeechRecognition()
{
    return dynamic_objc_cast<NSString>(NSBundle.mainBundle.infoDictionary[@"NSSpeechRecognitionUsageDescription"]).length > 0;
}

static RetainPtr<NSString> visibleDomain(const String& host)
{
    auto domain = WTF::URLHelpers::userVisibleURL(host.utf8());
    return startsWithLettersIgnoringASCIICase(domain, "www."_s) ? StringView(domain).substring(4).createNSString() : domain.createNSString();
}

RetainPtr<NSString> applicationVisibleNameFromOrigin(const WebCore::SecurityOriginData& origin)
{
    if (origin.protocol() != "http"_s && origin.protocol() != "https"_s)
        return nil;

    return visibleDomain(origin.host());
}

RetainPtr<NSString> applicationVisibleName()
{
    RetainPtr appBundle = [NSBundle mainBundle];
    if (RetainPtr<NSString> displayName = appBundle.get().infoDictionary[bridge_cast(_kCFBundleDisplayNameKey)])
        return displayName;
    return appBundle.get().infoDictionary[bridge_cast(kCFBundleNameKey)];
}

static RetainPtr<NSString> alertMessageText(MediaPermissionReason reason, const WebCore::SecurityOriginData& origin)
{
    RetainPtr visibleOrigin = applicationVisibleNameFromOrigin(origin);
    if (!visibleOrigin)
        visibleOrigin = applicationVisibleName();

    switch (reason) {
    case MediaPermissionReason::Camera:
        SUPPRESS_UNRETAINED_ARG return adoptNS([[NSString alloc] initWithFormat:WEB_UI_NSSTRING(@"Allow “%@” to use your camera?", @"Message for user camera access prompt"), visibleOrigin.get()]);
    case MediaPermissionReason::CameraAndMicrophone:
        SUPPRESS_UNRETAINED_ARG return adoptNS([[NSString alloc] initWithFormat:WEB_UI_NSSTRING(@"Allow “%@” to use your camera and microphone?", @"Message for user media prompt"), visibleOrigin.get()]);
    case MediaPermissionReason::Microphone:
        SUPPRESS_UNRETAINED_ARG return adoptNS([[NSString alloc] initWithFormat:WEB_UI_NSSTRING(@"Allow “%@” to use your microphone?", @"Message for user microphone access prompt"), visibleOrigin.get()]);
    case MediaPermissionReason::ScreenCapture:
        SUPPRESS_UNRETAINED_ARG return adoptNS([[NSString alloc] initWithFormat:WEB_UI_NSSTRING(@"Allow “%@” to observe your screen?", @"Message for screen sharing prompt"), visibleOrigin.get()]);
    case MediaPermissionReason::DeviceOrientation:
        SUPPRESS_UNRETAINED_ARG return adoptNS([[NSString alloc] initWithFormat:WEB_UI_NSSTRING(@"“%@” Would Like to Access Motion and Orientation", @"Message for requesting access to the device motion and orientation"), visibleOrigin.get()]);
    case MediaPermissionReason::Geolocation:
        SUPPRESS_UNRETAINED_ARG return adoptNS([[NSString alloc] initWithFormat:WEB_UI_NSSTRING(@"Allow “%@” to use your current location?", @"Message for geolocation prompt"), visibleOrigin.get()]);
    case MediaPermissionReason::SpeechRecognition:
        SUPPRESS_UNRETAINED_ARG return adoptNS([[NSString alloc] initWithFormat:WEB_UI_NSSTRING(@"Allow “%@” to capture your audio and use it for speech recognition?", @"Message for spechrecognition prompt"), visibleDomain(origin.host()).get()]);
    }
}

static RetainPtr<NSString> allowButtonText(MediaPermissionReason reason)
{
    switch (reason) {
    case MediaPermissionReason::Camera:
    case MediaPermissionReason::CameraAndMicrophone:
    case MediaPermissionReason::Microphone:
        return WEB_UI_STRING_KEY(@"Allow", "Allow (usermedia)", @"Allow button title in user media prompt").createNSString();
    case MediaPermissionReason::ScreenCapture:
        return WEB_UI_STRING_KEY(@"Allow", "Allow (screensharing)", @"Allow button title in screen sharing prompt").createNSString();
    case MediaPermissionReason::DeviceOrientation:
        return WEB_UI_STRING_KEY(@"Allow", "Allow (device motion and orientation access)", @"Button title in Device Orientation Permission API prompt").createNSString();
    case MediaPermissionReason::Geolocation:
        return WEB_UI_STRING_KEY(@"Allow", "Allow (geolocation)", @"Allow button title in geolocation prompt").createNSString();
    case MediaPermissionReason::SpeechRecognition:
        return WEB_UI_STRING_KEY(@"Allow", "Allow (speechrecognition)", @"Allow button title in speech recognition prompt").createNSString();
    }
}

static RetainPtr<NSString> doNotAllowButtonText(MediaPermissionReason reason)
{
    switch (reason) {
    case MediaPermissionReason::Camera:
    case MediaPermissionReason::CameraAndMicrophone:
    case MediaPermissionReason::Microphone:
        return WEB_UI_STRING_KEY(@"Don’t Allow", "Don’t Allow (usermedia)", @"Disallow button title in user media prompt").createNSString();
    case MediaPermissionReason::ScreenCapture:
        return WEB_UI_STRING_KEY(@"Don’t Allow", "Don’t Allow (screensharing)", @"Disallow button title in screen sharing prompt").createNSString();
    case MediaPermissionReason::DeviceOrientation:
        return WEB_UI_STRING_KEY(@"Cancel", "Cancel (device motion and orientation access)", @"Button title in Device Orientation Permission API prompt").createNSString();
    case MediaPermissionReason::Geolocation:
        return WEB_UI_STRING_KEY(@"Don’t Allow", "Don’t Allow (geolocation)", @"Disallow button title in geolocation prompt").createNSString();
    case MediaPermissionReason::SpeechRecognition:
        return WEB_UI_STRING_KEY(@"Don’t Allow", "Don’t Allow (speechrecognition)", @"Disallow button title in speech recognition prompt").createNSString();
    }
}

void alertForPermission(WebPageProxy& page, MediaPermissionReason reason, const WebCore::SecurityOriginData& origin, CompletionHandler<void(bool)>&& completionHandler)
{
    ASSERT(isMainRunLoop());

#if PLATFORM(IOS_FAMILY)
    if (reason == MediaPermissionReason::DeviceOrientation) {
        if (auto& userPermissionHandler = page.deviceOrientationUserPermissionHandlerForTesting())
            return completionHandler(userPermissionHandler());
    }
#endif

    auto webView = page.cocoaView();
    if (!webView) {
        completionHandler(false);
        return;
    }
    
    RetainPtr alertTitle = alertMessageText(reason, origin);
    if (!alertTitle) {
        completionHandler(false);
        return;
    }

    RetainPtr allowButtonString = allowButtonText(reason);
    RetainPtr doNotAllowButtonString = doNotAllowButtonText(reason);
    auto completionBlock = makeBlockPtr(WTF::move(completionHandler));

#if PLATFORM(MAC)
    auto alert = adoptNS([NSAlert new]);
    [alert setMessageText:alertTitle.get()];
    RetainPtr button = [alert addButtonWithTitle:allowButtonString.get()];
    button.get().keyEquivalent = @"";
    button = [alert addButtonWithTitle:doNotAllowButtonString.get()];
    button.get().keyEquivalent = @"\E";
    [alert beginSheetModalForWindow:retainPtr([webView window]).get() completionHandler:[completionBlock](NSModalResponse returnCode) {
        auto shouldAllow = returnCode == NSAlertFirstButtonReturn;
        completionBlock(shouldAllow);
    }];
#else
    auto alert = WebKit::createUIAlertController(alertTitle.get(), nil);
    RetainPtr allowAction = [UIAlertAction actionWithTitle:allowButtonString.get() style:UIAlertActionStyleDefault handler:[completionBlock](UIAlertAction *action) {
        completionBlock(true);
    }];

    RetainPtr doNotAllowAction = [UIAlertAction actionWithTitle:doNotAllowButtonString.get() style:UIAlertActionStyleCancel handler:[completionBlock](UIAlertAction *action) {
        completionBlock(false);
    }];

    [alert addAction:doNotAllowAction.get()];
    [alert addAction:allowAction.get()];

#if PLATFORM(VISION)
    page.dispatchWillPresentModalUI();
#endif
    [[webView _wk_viewControllerForFullScreenPresentation] presentViewController:alert.get() animated:YES completion:nil];
#endif
}

#if PLATFORM(MAC) && ENABLE(MEDIA_STREAM)

void alertForPermissionWithCapturePreview(WebPageProxy& page, MediaPermissionReason reason, const WebCore::SecurityOriginData& origin, Vector<WebCore::CaptureDevice>&& eligibleVideoDevices, Vector<WebCore::CaptureDevice>&& eligibleAudioDevices, CompletionHandler<void(bool, String, String)>&& completionHandler, CapturePreviewDeviceListUpdater& deviceListUpdater)
{
    ASSERT(isMainRunLoop());

    RetainPtr webView = page.cocoaView();
    if (!webView) {
        completionHandler(false, { }, { });
        return;
    }

    RetainPtr alertTitle = alertMessageText(reason, origin);
    if (!alertTitle) {
        completionHandler(false, { }, { });
        return;
    }

    RetainPtr chooser = adoptNS([[WKCaptureDeviceChooser alloc] initWithVideoDevices:WTF::move(eligibleVideoDevices) audioDevices:WTF::move(eligibleAudioDevices)]);

    auto alert = adoptNS([NSAlert new]);
    [alert setMessageText:alertTitle.get()];
    RetainPtr allowButton = [alert addButtonWithTitle:allowButtonText(reason).get()];
    allowButton.get().keyEquivalent = @"";
    RetainPtr denyButton = [alert addButtonWithTitle:doNotAllowButtonText(reason).get()];
    denyButton.get().keyEquivalent = @"\E";
    [alert setAccessoryView:[chooser view]];
    [chooser setAllowButton:allowButton.get()];

    deviceListUpdater = [chooser](Vector<WebCore::CaptureDevice>&& videoDevices, Vector<WebCore::CaptureDevice>&& audioDevices) mutable {
        [chooser updateWithVideoDevices:WTF::move(videoDevices) audioDevices:WTF::move(audioDevices)];
    };

    auto completionBlock = makeBlockPtr([completionHandler = WTF::move(completionHandler), chooser](NSModalResponse returnCode) mutable {
        bool shouldAllow = returnCode == NSAlertFirstButtonReturn;
        RetainPtr selectedVideoDeviceID = shouldAllow ? [chooser selectedVideoDeviceID] : nil;
        RetainPtr selectedAudioDeviceID = shouldAllow ? [chooser selectedAudioDeviceID] : nil;

        // Stopping before the grant is reported means the capture that follows is the only
        // holder of these devices, so this never depends on concurrent access to one of them.
        [chooser stop];

        completionHandler(shouldAllow, selectedAudioDeviceID.get(), selectedVideoDeviceID.get());
    });

    [alert beginSheetModalForWindow:retainPtr([webView window]).get() completionHandler:completionBlock.get()];
}

#endif // PLATFORM(MAC) && ENABLE(MEDIA_STREAM)



void requestAVCaptureAccessForType(MediaPermissionType type, CompletionHandler<void(bool authorized)>&& completionHandler)
{
    ASSERT(isMainRunLoop());

#if HAVE(AVCAPTUREDEVICE)
    RetainPtr mediaType = type == MediaPermissionType::Audio ? AVMediaTypeAudio : AVMediaTypeVideo;
    auto decisionHandler = makeBlockPtr([completionHandler = WTF::move(completionHandler)](BOOL authorized) mutable {
        callOnMainRunLoop([completionHandler = WTF::move(completionHandler), authorized]() mutable {
            completionHandler(authorized);
        });
    });
    [PAL::getAVCaptureDeviceClassSingleton() requestAccessForMediaType:mediaType.get() completionHandler:decisionHandler.get()];
#else
    UNUSED_PARAM(type);
    completionHandler(false);
#endif
}

MediaPermissionResult checkAVCaptureAccessForType(MediaPermissionType type)
{
#if HAVE(AVCAPTUREDEVICE)
    RetainPtr mediaType = type == MediaPermissionType::Audio ? AVMediaTypeAudio : AVMediaTypeVideo;
    auto authorizationStatus = [PAL::getAVCaptureDeviceClassSingleton() authorizationStatusForMediaType:mediaType.get()];
    if (authorizationStatus == AVAuthorizationStatusDenied || authorizationStatus == AVAuthorizationStatusRestricted)
        return MediaPermissionResult::Denied;
    if (authorizationStatus == AVAuthorizationStatusNotDetermined)
        return MediaPermissionResult::Unknown;
    return MediaPermissionResult::Granted;
#else
    UNUSED_PARAM(type);
    return MediaPermissionResult::Denied;
#endif
}

#if HAVE(SPEECHRECOGNIZER)

void requestSpeechRecognitionAccess(CompletionHandler<void(bool authorized)>&& completionHandler)
{
    ASSERT(isMainRunLoop());

    auto decisionHandler = makeBlockPtr([completionHandler = WTF::move(completionHandler)](SFSpeechRecognizerAuthorizationStatus status) mutable {
        bool authorized = status == SFSpeechRecognizerAuthorizationStatusAuthorized;
        callOnMainRunLoop([completionHandler = WTF::move(completionHandler), authorized]() mutable {
            completionHandler(authorized);
        });
    });
    [PAL::getSFSpeechRecognizerClassSingleton() requestAuthorization:decisionHandler.get()];
}

MediaPermissionResult checkSpeechRecognitionServiceAccess()
{
    auto authorizationStatus = [PAL::getSFSpeechRecognizerClassSingleton() authorizationStatus];
IGNORE_WARNINGS_BEGIN("deprecated-enum-compare")
    if (authorizationStatus == SFSpeechRecognizerAuthorizationStatusDenied || authorizationStatus == SFSpeechRecognizerAuthorizationStatusRestricted)
        return MediaPermissionResult::Denied;
    if (authorizationStatus == SFSpeechRecognizerAuthorizationStatusAuthorized)
        return MediaPermissionResult::Granted;
IGNORE_WARNINGS_END
    return MediaPermissionResult::Unknown;
}

bool checkSpeechRecognitionServiceAvailability(const String& localeIdentifier)
{
    auto recognizer = localeIdentifier.isEmpty() ? adoptNS([PAL::allocSFSpeechRecognizerInstance() init]) : adoptNS([PAL::allocSFSpeechRecognizerInstance() initWithLocale:[NSLocale localeWithLocaleIdentifier:localeIdentifier.createNSString().get()]]);
    return recognizer && [recognizer isAvailable];
}

#endif // HAVE(SPEECHRECOGNIZER)

} // namespace WebKit
