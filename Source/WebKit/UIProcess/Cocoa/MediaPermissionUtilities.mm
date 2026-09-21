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

#import "GPUProcessProxy.h"
#import "LayerHostingContext.h"
#import "Logging.h"
#import "SandboxUtilities.h"
#import "WKWebViewInternal.h"
#import "WebPageProxy.h"
#import "WebProcessPool.h"
#import "WebProcessProxy.h"
#import <WebCore/HostingContext.h>
#import <WebCore/IntSize.h>
#import <WebCore/LocalizedStrings.h>
#import <WebCore/SecurityOriginData.h>
#import <algorithm>
#import <mutex>
#import <wtf/BlockPtr.h>
#import <wtf/URLHelpers.h>
#import <wtf/WeakObjCPtr.h>
#import <wtf/cocoa/TypeCastsCocoa.h>
#import <wtf/spi/cf/CFBundleSPI.h>
#import <wtf/spi/darwin/SandboxSPI.h>

#if PLATFORM(IOS_FAMILY)
#import "UIKitUtilities.h"
#if ENABLE(MEDIA_STREAM)
#import "WKCapturePreviewViewController.h"
#endif
#endif

#import "TCCSoftLink.h"
#import <pal/cocoa/AVFoundationSoftLink.h>
#import <pal/cocoa/SpeechSoftLink.h>

#if PLATFORM(MAC) && ENABLE(MEDIA_STREAM)
constexpr CGFloat previewWidth = 320;
constexpr CGFloat previewHeight = 180;
#endif

#if PLATFORM(MAC) && ENABLE(MEDIA_STREAM)
constexpr CGFloat chooserElementSpacing = 8;
constexpr CGFloat sectionCornerRadius = 8;
constexpr CGFloat sectionInset = 12;
constexpr CGFloat audioLevelMeterHeight = 10;
constexpr CGFloat audioLevelIconSpacing = 10;
constexpr CGFloat previewCornerRadius = 8;
constexpr CGFloat previewBadgeInset = 8;
constexpr CGFloat previewBadgeHorizontalPadding = 6;
constexpr CGFloat previewBadgeVerticalPadding = 2;
constexpr CGFloat previewBadgeCornerRadius = 100;
constexpr CGFloat sectionBandThickness = 8;
constexpr CGFloat sectionBandCornerRadius = sectionCornerRadius + sectionBandThickness;

// NSStackView only aligns its views; it does not make them share the stack's width, and its default
// distribution spreads them apart rather than packing them at the spacing.
static void pinToWidthOfStack(NSView *view, NSStackView *stack)
{
    [NSLayoutConstraint activateConstraints:@[
        [[view leadingAnchor] constraintEqualToAnchor:[stack leadingAnchor]],
        [[view trailingAnchor] constraintEqualToAnchor:[stack trailingAnchor]],
    ]];
}

// A level meter that is never narrower than it is tall, so it reads as a level at rest rather than
// as a divider. NSLevelIndicator cannot do that: it is a few points tall with square ends and no
// minimum fill.
@interface WKCaptureDeviceChooserLevelView : NSView {
    float _level;
}
- (void)setLevel:(float)level;
@end

@implementation WKCaptureDeviceChooserLevelView

- (NSSize)intrinsicContentSize
{
    return NSMakeSize(NSViewNoIntrinsicMetric, audioLevelMeterHeight);
}

- (void)setLevel:(float)level
{
    level = std::clamp(level, 0.f, 1.f);
    if (_level == level)
        return;

    _level = level;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)rect
{
    NSRect bounds = [self bounds];
    CGFloat radius = NSHeight(bounds) / 2;

    [[NSColor quaternaryLabelColor] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:bounds xRadius:radius yRadius:radius] fill];

    NSRect fill = bounds;
    fill.size.width = std::max(NSHeight(bounds), std::round(NSWidth(bounds) * _level));
    [[NSColor controlAccentColor] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:fill xRadius:radius yRadius:radius] fill];
}

@end

// Draws its own rounded background instead of using NSBox, whose contentViewMargins position the
// content view by frame and so leave a constraint based content view unresolved.
@interface WKCaptureDeviceChooserRoundedView : NSView {
    RetainPtr<NSColor> _fillColor;
    CGFloat _cornerRadius;
    CGFloat _bandThickness;
}
- (instancetype)initWithFillColor:(NSColor *)fillColor cornerRadius:(CGFloat)cornerRadius bandThickness:(CGFloat)bandThickness;
@end

@implementation WKCaptureDeviceChooserRoundedView

- (instancetype)initWithFillColor:(NSColor *)fillColor cornerRadius:(CGFloat)cornerRadius bandThickness:(CGFloat)bandThickness
{
    if (!(self = [super initWithFrame:NSZeroRect]))
        return nil;

    _fillColor = fillColor;
    _cornerRadius = cornerRadius;
    _bandThickness = bandThickness;
    [self setTranslatesAutoresizingMaskIntoConstraints:NO];

    return self;
}

- (void)drawRect:(NSRect)rect
{
    NSRect bounds = [self bounds];
    // Clamped so a radius meant to round the ends completely cannot overdraw a short view.
    CGFloat radius = std::min(_cornerRadius, NSHeight(bounds) / 2);

    RetainPtr path = [NSBezierPath bezierPathWithRoundedRect:bounds xRadius:radius yRadius:radius];
    if (_bandThickness > 0) {
        // Only the band is drawn, so whatever is behind shows through the middle. That is the one way
        // to be certain the middle matches the alert: its backdrop cannot be sampled or named.
        NSRect inside = NSInsetRect(bounds, _bandThickness, _bandThickness);
        CGFloat insideRadius = std::max<CGFloat>(0, radius - _bandThickness);
        [path appendBezierPathWithRoundedRect:inside xRadius:insideRadius yRadius:insideRadius];
        [path setWindingRule:NSWindingRuleEvenOdd];
    }

    [_fillColor setFill];
    [path fill];
}

@end

@interface WKCaptureDeviceChooser : NSObject {
    RetainPtr<NSView> _view;
    RetainPtr<NSPopUpButton> _videoPopUp;
    RetainPtr<NSPopUpButton> _audioPopUp;
    RetainPtr<WKCaptureDeviceChooserLevelView> _audioLevelMeter;
    RetainPtr<NSButton> _allowButton;

    // The preview itself is rendered by the GPU process into a layer hosted here, so the
    // chooser only owns the space it occupies.
    RetainPtr<NSView> _previewContainer;
    RetainPtr<CALayer> _previewLayerHost;
    WebKit::LayerHostingContextID _previewHostingContextID;
    Function<void(std::optional<WebCore::CaptureDevice>&& videoDevice, std::optional<WebCore::CaptureDevice>&& audioDevice)> _selectionChangedHandler;

    Vector<WebCore::CaptureDevice> _videoDevices;
    Vector<WebCore::CaptureDevice> _audioDevices;
    BOOL _requestNeedsVideo;
    BOOL _requestNeedsAudio;
}

- (instancetype)initWithVideoDevices:(Vector<WebCore::CaptureDevice>&&)videoDevices audioDevices:(Vector<WebCore::CaptureDevice>&&)audioDevices;
- (NSView *)view;
- (NSString *)selectedVideoDeviceID;
- (NSString *)selectedAudioDeviceID;
- (void)setAllowButton:(NSButton *)allowButton;
- (NSView *)previewContainer;
- (void)setPreviewHostingContext:(const WebCore::HostingContext&)hostingContext;
- (void)setSelectionChangedHandler:(Function<void(std::optional<WebCore::CaptureDevice>&& videoDevice, std::optional<WebCore::CaptureDevice>&& audioDevice)>&&)handler;
- (void)setAudioLevel:(float)level;
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
    // A kind the request asked for but has no devices for never reaches the prompt:
    // validateRequestConstraintsAfterEnumeration fails the request first. So a non-empty list means
    // the request wants that kind, and an empty one means it does not.
    _requestNeedsVideo = !_videoDevices.isEmpty();
    _requestNeedsAudio = !_audioDevices.isEmpty();

    _previewContainer = adoptNS([[NSView alloc] initWithFrame:NSMakeRect(0, 0, previewWidth, previewHeight)]);
    [_previewContainer setWantsLayer:YES];
    [[_previewContainer layer] setBackgroundColor:[NSColor blackColor].CGColor];
    [[_previewContainer layer] setCornerRadius:previewCornerRadius];
    [[_previewContainer layer] setMasksToBounds:YES];
    [_previewContainer setTranslatesAutoresizingMaskIntoConstraints:NO];

    RetainPtr contentStack = adoptNS([[NSStackView alloc] init]);
    [contentStack setOrientation:NSUserInterfaceLayoutOrientationVertical];
    [contentStack setDistribution:NSStackViewDistributionFill];
    [contentStack setSpacing:chooserElementSpacing];
    [contentStack setTranslatesAutoresizingMaskIntoConstraints:NO];

    if (_requestNeedsVideo) {
        RetainPtr badgeLabel = adoptNS([[NSTextField alloc] initWithFrame:NSZeroRect]);
        [badgeLabel setStringValue:WEB_UI_STRING_KEY(@"Preview", "Preview (usermedia)", @"Badge label identifying the live camera preview in the user media prompt").createNSString().get()];
        [badgeLabel setEditable:NO];
        [badgeLabel setSelectable:NO];
        [badgeLabel setBordered:NO];
        [badgeLabel setDrawsBackground:NO];
        [badgeLabel setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
        [badgeLabel setTextColor:[NSColor alternateSelectedControlTextColor]];
        [badgeLabel setTranslatesAutoresizingMaskIntoConstraints:NO];

        RetainPtr badge = adoptNS([[WKCaptureDeviceChooserRoundedView alloc] initWithFillColor:[NSColor controlAccentColor] cornerRadius:previewBadgeCornerRadius bandThickness:0]);
        [badge addSubview:badgeLabel.get()];
        [_previewContainer addSubview:badge.get()];

        _videoPopUp = adoptNS([[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO]);
        [_videoPopUp setTarget:self];
        [_videoPopUp setAction:@selector(_selectedVideoDeviceDidChange:)];
        [_videoPopUp setTranslatesAutoresizingMaskIntoConstraints:NO];

        RetainPtr cameraStack = adoptNS([[NSStackView alloc] init]);
        [cameraStack setOrientation:NSUserInterfaceLayoutOrientationVertical];
        [cameraStack setDistribution:NSStackViewDistributionFill];
        [cameraStack setSpacing:sectionInset];
        [cameraStack setTranslatesAutoresizingMaskIntoConstraints:NO];
        [cameraStack addArrangedSubview:_previewContainer.get()];
        [cameraStack addArrangedSubview:_videoPopUp.get()];
        pinToWidthOfStack(_previewContainer.get(), cameraStack.get());
        pinToWidthOfStack(_videoPopUp.get(), cameraStack.get());

        RetainPtr cameraSection = [self _createSectionWithContentView:cameraStack.get()];
        [contentStack addArrangedSubview:cameraSection.get()];
        pinToWidthOfStack(cameraSection.get(), contentStack.get());

        [NSLayoutConstraint activateConstraints:@[
            // The hosted layer is built at this size by the GPU process, so the container has to be
            // exactly that or the image is scaled.
            [[_previewContainer widthAnchor] constraintEqualToConstant:previewWidth],
            [[_previewContainer heightAnchor] constraintEqualToConstant:previewHeight],
            [[badgeLabel topAnchor] constraintEqualToAnchor:[badge topAnchor] constant:previewBadgeVerticalPadding],
            [[badgeLabel bottomAnchor] constraintEqualToAnchor:[badge bottomAnchor] constant:-previewBadgeVerticalPadding],
            [[badgeLabel leadingAnchor] constraintEqualToAnchor:[badge leadingAnchor] constant:previewBadgeHorizontalPadding],
            [[badgeLabel trailingAnchor] constraintEqualToAnchor:[badge trailingAnchor] constant:-previewBadgeHorizontalPadding],
            [[badge topAnchor] constraintEqualToAnchor:[_previewContainer topAnchor] constant:previewBadgeInset],
            [[badge leadingAnchor] constraintEqualToAnchor:[_previewContainer leadingAnchor] constant:previewBadgeInset],
        ]];
    }

    if (_requestNeedsAudio) {
        RetainPtr microphoneIcon = adoptNS([[NSImageView alloc] init]);
        [microphoneIcon setImage:[NSImage imageWithSystemSymbolName:@"mic" accessibilityDescription:nil]];
        [microphoneIcon setContentTintColor:[NSColor secondaryLabelColor]];
        [microphoneIcon setTranslatesAutoresizingMaskIntoConstraints:NO];
        // Without this the row has two views it may stretch, and it picks the icon.
        [microphoneIcon setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];

        _audioLevelMeter = adoptNS([[WKCaptureDeviceChooserLevelView alloc] initWithFrame:NSZeroRect]);
        [_audioLevelMeter setTranslatesAutoresizingMaskIntoConstraints:NO];

        RetainPtr meterRow = adoptNS([[NSStackView alloc] init]);
        [meterRow setOrientation:NSUserInterfaceLayoutOrientationHorizontal];
        [meterRow setDistribution:NSStackViewDistributionFill];
        [meterRow setAlignment:NSLayoutAttributeCenterY];
        [meterRow setSpacing:audioLevelIconSpacing];
        [meterRow setTranslatesAutoresizingMaskIntoConstraints:NO];
        [meterRow addArrangedSubview:microphoneIcon.get()];
        [meterRow addArrangedSubview:_audioLevelMeter.get()];

        _audioPopUp = adoptNS([[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO]);
        [_audioPopUp setTarget:self];
        [_audioPopUp setAction:@selector(_selectedAudioDeviceDidChange:)];
        [_audioPopUp setTranslatesAutoresizingMaskIntoConstraints:NO];

        RetainPtr microphoneStack = adoptNS([[NSStackView alloc] init]);
        [microphoneStack setOrientation:NSUserInterfaceLayoutOrientationVertical];
        [microphoneStack setDistribution:NSStackViewDistributionFill];
        [microphoneStack setSpacing:sectionInset];
        [microphoneStack setTranslatesAutoresizingMaskIntoConstraints:NO];
        [microphoneStack addArrangedSubview:meterRow.get()];
        [microphoneStack addArrangedSubview:_audioPopUp.get()];
        pinToWidthOfStack(meterRow.get(), microphoneStack.get());
        pinToWidthOfStack(_audioPopUp.get(), microphoneStack.get());

        RetainPtr microphoneSection = [self _createSectionWithContentView:microphoneStack.get()];
        [contentStack addArrangedSubview:microphoneSection.get()];
        pinToWidthOfStack(microphoneSection.get(), contentStack.get());
    }

    _view = adoptNS([[NSView alloc] initWithFrame:NSZeroRect]);
    [_view addSubview:contentStack.get()];
    // Centred rather than pinned to the sides, because NSAlert widens its accessory view to the
    // width the message text needs, which is wider than the preview.
    [NSLayoutConstraint activateConstraints:@[
        [[contentStack topAnchor] constraintEqualToAnchor:[_view topAnchor]],
        [[contentStack bottomAnchor] constraintEqualToAnchor:[_view bottomAnchor]],
        [[contentStack centerXAnchor] constraintEqualToAnchor:[_view centerXAnchor]],
        [[contentStack leadingAnchor] constraintGreaterThanOrEqualToAnchor:[_view leadingAnchor]],
        [[contentStack trailingAnchor] constraintLessThanOrEqualToAnchor:[_view trailingAnchor]],
    ]];
    [_view layoutSubtreeIfNeeded];
    [_view setFrameSize:[_view fittingSize]];

    [self _rebuildMenusPreservingVideoSelection:nil audioSelection:nil];

    return self;
}

- (NSView *)_createSectionWithContentView:(NSView *)contentView
{
    RetainPtr section = adoptNS([[WKCaptureDeviceChooserRoundedView alloc] initWithFillColor:[NSColor separatorColor] cornerRadius:sectionBandCornerRadius bandThickness:sectionBandThickness]);
    [section addSubview:contentView];
    CGFloat contentInset = sectionBandThickness + sectionInset;
    [NSLayoutConstraint activateConstraints:@[
        [[contentView topAnchor] constraintEqualToAnchor:[section topAnchor] constant:contentInset],
        [[contentView bottomAnchor] constraintEqualToAnchor:[section bottomAnchor] constant:-contentInset],
        [[contentView leadingAnchor] constraintEqualToAnchor:[section leadingAnchor] constant:contentInset],
        [[contentView trailingAnchor] constraintEqualToAnchor:[section trailingAnchor] constant:-contentInset],
    ]];
    return section.autorelease();
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

- (std::optional<WebCore::CaptureDevice>)_selectedDeviceForPopUp:(NSPopUpButton *)popUp devices:(const Vector<WebCore::CaptureDevice>&)devices
{
    if (RetainPtr deviceID = dynamic_objc_cast<NSString>([[popUp selectedItem] representedObject])) {
        String identifier { deviceID.get() };
        size_t index = devices.findIf([&identifier](auto& device) {
            return device.persistentId() == identifier;
        });
        if (index != notFound)
            return devices[index];
    }

    if (devices.isEmpty())
        return std::nullopt;

    return devices[0];
}

- (NSString *)_selectedDeviceIDForPopUp:(NSPopUpButton *)popUp devices:(const Vector<WebCore::CaptureDevice>&)devices
{
    auto device = [self _selectedDeviceForPopUp:popUp devices:devices];
    return device ? device->persistentId().createNSString().autorelease() : nil;
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
    bool canStillSatisfyRequest = !(_requestNeedsVideo && _videoDevices.isEmpty()) && !(_requestNeedsAudio && _audioDevices.isEmpty());
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

    // A meter left at its last value after the microphone was unplugged would read as a live signal
    // from a device that is gone.
    if (_audioDevices.isEmpty())
        [self setAudioLevel:0];

    if (_videoDevices.isEmpty() && _audioDevices.isEmpty())
        return;

    // Only disturb a running device when the one being previewed is gone; otherwise the image
    // or meter would flash on every unrelated attach or detach.
    auto isSameDeviceID = [](NSString *a, NSString *b) {
        // Messaging nil returns NO, so two absent selections must be compared explicitly.
        if (!a || !b)
            return !a && !b;
        return [a isEqualToString:b];
    };

    RetainPtr nowVideo = [self selectedVideoDeviceID];
    RetainPtr nowAudio = [self selectedAudioDeviceID];
    if (!isSameDeviceID(nowVideo.get(), previousVideo.get()) || !isSameDeviceID(nowAudio.get(), previousAudio.get()))
        [self _notifySelectionChanged];
}

- (NSView *)previewContainer
{
    return _previewContainer.get();
}

- (void)setPreviewHostingContext:(const WebCore::HostingContext&)hostingContext
{
    // An unchanged context id means the video source was untouched, as when only the microphone
    // selection moved; rebuilding the layer then would flicker the preview for no reason.
    if (_previewLayerHost && hostingContext.contextID == _previewHostingContextID)
        return;

    _previewHostingContextID = hostingContext.contextID;

    // The hosting layer is rebuilt per context: a render layer is bound to one context id, so
    // switching devices produces a new one rather than retargeting the old.
    [_previewLayerHost removeFromSuperlayer];
    _previewLayerHost = nil;

    if (!hostingContext.contextID)
        return;

    _previewLayerHost = WebKit::LayerHostingContext::createPlatformLayerForHostingContext(hostingContext.contextID);
    if (!_previewLayerHost) {
        RELEASE_LOG_ERROR(WebRTC, "CapturePreview unable to create a hosting layer for contextID=%u", hostingContext.contextID);
        return;
    }

    [_previewLayerHost setFrame:[_previewContainer bounds]];
    [_previewLayerHost setAutoresizingMask:kCALayerWidthSizable | kCALayerHeightSizable];
    [[_previewContainer layer] insertSublayer:_previewLayerHost.get() atIndex:0];
}

- (void)setSelectionChangedHandler:(Function<void(std::optional<WebCore::CaptureDevice>&&, std::optional<WebCore::CaptureDevice>&&)>&&)handler
{
    _selectionChangedHandler = WTF::move(handler);
    [self _notifySelectionChanged];
}

- (void)setAudioLevel:(float)level
{
    [_audioLevelMeter setLevel:level];
}

- (void)_notifySelectionChanged
{
    if (!_selectionChangedHandler)
        return;

    _selectionChangedHandler([self _selectedDeviceForPopUp:_videoPopUp.get() devices:_videoDevices], [self _selectedDeviceForPopUp:_audioPopUp.get() devices:_audioDevices]);
}

- (void)_selectedVideoDeviceDidChange:(id)sender
{
    [self _notifySelectionChanged];
}

- (void)_selectedAudioDeviceDidChange:(id)sender
{
    [self _notifySelectionChanged];
}

- (void)stop
{
    _selectionChangedHandler = nullptr;
    [self setPreviewHostingContext:WebCore::HostingContext { }];
    [self setAudioLevel:0];
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

CapturePreviewPromptHandles alertForPermissionWithCapturePreview(WebPageProxy& page, CapturePreviewPromptRequest&& request, CompletionHandler<void(CapturePreviewPromptResult&&)>&& completionHandler)
{
    ASSERT(isMainRunLoop());

    RetainPtr webView = page.cocoaView();
    if (!webView) {
        completionHandler({ });
        return { };
    }

    RetainPtr alertTitle = alertMessageText(request.reason, request.origin);
    if (!alertTitle) {
        completionHandler({ });
        return { };
    }

    RetainPtr chooser = adoptNS([[WKCaptureDeviceChooser alloc] initWithVideoDevices:WTF::move(request.eligibleVideoDevices) audioDevices:WTF::move(request.eligibleAudioDevices)]);

    RetainPtr alert = adoptNS([NSAlert new]);
    [alert setMessageText:alertTitle.get()];
    RetainPtr allowButton = [alert addButtonWithTitle:allowButtonText(request.reason).get()];
    [allowButton setKeyEquivalent:@""];
    RetainPtr denyButton = [alert addButtonWithTitle:doNotAllowButtonText(request.reason).get()];
    [denyButton setKeyEquivalent:@"\E"];
    [alert setAccessoryView:[chooser view]];
    [chooser setAllowButton:allowButton.get()];

    // The preview is captured and rendered by the GPU process, so the chooser only reports
    // which devices the user picked and the GPU process is told to follow.
    Ref gpuProcess = page.legacyMainFrameProcess().processPool().ensureGPUProcess();
    WeakPtr pageForPreview { page };

    gpuProcess->setCapturePreviewAudioLevelHandler([weakChooser = WeakObjCPtr<WKCaptureDeviceChooser>(chooser.get())](float level) {
        [weakChooser.get() setAudioLevel:level];
    });
    [chooser setSelectionChangedHandler:[pageForPreview, weakChooser = WeakObjCPtr<WKCaptureDeviceChooser>(chooser.get())](std::optional<WebCore::CaptureDevice>&& videoDevice, std::optional<WebCore::CaptureDevice>&& audioDevice) mutable {
        if (!pageForPreview)
            return;

        // Re-fetched rather than captured: a GPU process that crashed mid-prompt is replaced, and a
        // captured Ref would keep addressing the dead one.
        Ref gpuProcess = pageForPreview->legacyMainFrameProcess().processPool().ensureGPUProcess();
        gpuProcess->startCapturePreview(WTF::move(videoDevice), WTF::move(audioDevice), pageForPreview->webPageIDInMainFrameProcess(),
            WebCore::IntSize(static_cast<int>(previewWidth), static_cast<int>(previewHeight)), pageForPreview->orientationForMediaCapture(),
            [weakChooser](WebCore::HostingContext hostingContext) mutable {
                [weakChooser.get() setPreviewHostingContext:hostingContext];
            });
    }];

    auto completionBlock = makeBlockPtr([completionHandler = WTF::move(completionHandler), chooser, pageForPreview, pageIdentifier = page.webPageIDInMainFrameProcess()](NSModalResponse returnCode) mutable {
        bool shouldAllow = returnCode == NSAlertFirstButtonReturn;
        RetainPtr selectedVideoDeviceID = shouldAllow ? [chooser selectedVideoDeviceID] : nil;
        RetainPtr selectedAudioDeviceID = shouldAllow ? [chooser selectedAudioDeviceID] : nil;

        // Stopping before the request is reported means the capture that follows is the only
        // holder of these devices, so this never depends on concurrent access to one of them.
        if (RefPtr gpuProcess = pageForPreview ? pageForPreview->legacyMainFrameProcess().processPool().gpuProcess() : nullptr)
            gpuProcess->stopCapturePreview(pageIdentifier);
        [chooser stop];

        completionHandler({ .granted = shouldAllow, .selectedAudioDeviceUID = selectedAudioDeviceID.get(), .selectedVideoDeviceUID = selectedVideoDeviceID.get() });
    });

    [alert beginSheetModalForWindow:retainPtr([webView window]).get() completionHandler:completionBlock.get()];

    return {
        .deviceListUpdater = [weakChooser = WeakObjCPtr<WKCaptureDeviceChooser>(chooser.get())](Vector<WebCore::CaptureDevice>&& videoDevices, Vector<WebCore::CaptureDevice>&& audioDevices) mutable {
            [weakChooser.get() updateWithVideoDevices:WTF::move(videoDevices) audioDevices:WTF::move(audioDevices)];
        },
        .promptDismisser = [alert = WTF::move(alert)] {
            // Ending the sheet runs completionBlock, which stops the preview and reports the denial.
            RetainPtr alertWindow = [alert window];
            [[alertWindow sheetParent] endSheet:alertWindow.get() returnCode:NSAlertSecondButtonReturn];
        }
    };
}

#elif PLATFORM(IOS_FAMILY) && ENABLE(MEDIA_STREAM)

CapturePreviewPromptHandles alertForPermissionWithCapturePreview(WebPageProxy& page, CapturePreviewPromptRequest&& request, CompletionHandler<void(CapturePreviewPromptResult&&)>&& completionHandler)
{
    ASSERT(isMainRunLoop());

    RetainPtr webView = page.cocoaView();
    if (!webView) {
        completionHandler({ });
        return { };
    }

    RetainPtr alertTitle = alertMessageText(request.reason, request.origin);
    if (!alertTitle) {
        completionHandler({ });
        return { };
    }

    RetainPtr presentingViewController = [webView _wk_viewControllerForFullScreenPresentation];
    if (!presentingViewController) {
        completionHandler({ });
        return { };
    }

    RetainPtr controller = adoptNS([[WKCapturePreviewViewController alloc] initWithTitle:alertTitle.get() allowButtonTitle:allowButtonText(request.reason).get() denyButtonTitle:doNotAllowButtonText(request.reason).get() videoDevices:WTF::move(request.eligibleVideoDevices) audioDevices:WTF::move(request.eligibleAudioDevices)]);

    // The preview is captured and rendered by the GPU process, so the controller only reports which
    // devices the user picked and the GPU process is told to follow.
    Ref gpuProcess = page.legacyMainFrameProcess().processPool().ensureGPUProcess();
    WeakPtr pageForPreview { page };

    gpuProcess->setCapturePreviewAudioLevelHandler([weakController = WeakObjCPtr<WKCapturePreviewViewController>(controller.get())](float level) {
        [weakController.get() setAudioLevel:level];
    });
    [controller setSelectionChangedHandler:[pageForPreview, weakController = WeakObjCPtr<WKCapturePreviewViewController>(controller.get())](std::optional<WebCore::CaptureDevice>&& videoDevice, std::optional<WebCore::CaptureDevice>&& audioDevice) mutable {
        if (!pageForPreview)
            return;

        // Re-fetched rather than captured: a GPU process that crashed mid-prompt is replaced, and a
        // captured Ref would keep addressing the dead one.
        Ref gpuProcess = pageForPreview->legacyMainFrameProcess().processPool().ensureGPUProcess();

        CGSize previewSize = [WKCapturePreviewViewController previewSize];
        gpuProcess->startCapturePreview(WTF::move(videoDevice), WTF::move(audioDevice), pageForPreview->webPageIDInMainFrameProcess(),
            WebCore::IntSize(static_cast<int>(previewSize.width), static_cast<int>(previewSize.height)), pageForPreview->orientationForMediaCapture(),
            [weakController, gpuProcessIdentifier = gpuProcess->processID()](WebCore::HostingContext hostingContext) mutable {
                [weakController.get() setPreviewHostingContext:hostingContext gpuProcessIdentifier:gpuProcessIdentifier];
            });
    }];

    [controller setDecisionHandler:[completionHandler = WTF::move(completionHandler), weakController = WeakObjCPtr<WKCapturePreviewViewController>(controller.get()), pageForPreview, pageIdentifier = page.webPageIDInMainFrameProcess()](bool granted) mutable {
        RetainPtr controller = weakController.get();
        RetainPtr selectedVideoDeviceID = granted ? [controller selectedVideoDeviceID] : nil;
        RetainPtr selectedAudioDeviceID = granted ? [controller selectedAudioDeviceID] : nil;

        // Stopping before the request is reported means the capture that follows is the only holder
        // of these devices, so this never depends on concurrent access to one of them.
        if (RefPtr gpuProcess = pageForPreview ? pageForPreview->legacyMainFrameProcess().processPool().gpuProcess() : nullptr)
            gpuProcess->stopCapturePreview(pageIdentifier);
        [controller stop];
        [controller dismissViewControllerAnimated:YES completion:nil];

        completionHandler({ .granted = granted, .selectedAudioDeviceUID = selectedAudioDeviceID.get(), .selectedVideoDeviceUID = selectedVideoDeviceID.get() });
    }];

#if PLATFORM(VISION)
    page.dispatchWillPresentModalUI();
#endif
    [presentingViewController presentViewController:controller.get() animated:YES completion:nil];

    return {
        .deviceListUpdater = [weakController = WeakObjCPtr<WKCapturePreviewViewController>(controller.get())](Vector<WebCore::CaptureDevice>&& videoDevices, Vector<WebCore::CaptureDevice>&& audioDevices) mutable {
            [weakController.get() updateWithVideoDevices:WTF::move(videoDevices) audioDevices:WTF::move(audioDevices)];
        },
        .promptDismisser = [controller = WTF::move(controller)] {
            // -deny runs the full stop-and-dismiss path, so nothing is left behind.
            [controller deny];
        }
    };
}

#endif // (PLATFORM(MAC) || PLATFORM(IOS_FAMILY)) && ENABLE(MEDIA_STREAM)

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
