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

#import "CapturePreviewDeviceSelection.h"
#import "CapturePreviewLevelMeterState.h"
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
#import <wtf/Box.h>
#import <wtf/CallbackAggregator.h>
#import <wtf/URLHelpers.h>
#import <wtf/WeakObjCPtr.h>
#import <wtf/cocoa/TypeCastsCocoa.h>
#import <wtf/spi/cf/CFBundleSPI.h>
#import <wtf/spi/darwin/SandboxSPI.h>

#if PLATFORM(IOS_FAMILY)
#import "UIKitUtilities.h"
#if ENABLE(MEDIA_STREAM) && !PLATFORM(APPLETV)
#import "WKCapturePreviewViewController.h"
#endif
#endif

#import "TCCSoftLink.h"
#import <pal/cocoa/AVFoundationSoftLink.h>
#import <pal/cocoa/SpeechSoftLink.h>

#if PLATFORM(MAC) && ENABLE(MEDIA_STREAM)
constexpr CGFloat previewWidth = 320;
constexpr CGFloat previewHeight = 180;
constexpr CGFloat chooserElementSpacing = 8;
constexpr CGFloat sectionCornerRadius = 12;
constexpr CGFloat sectionInset = 12;
constexpr CGFloat audioLevelIconSpacing = 10;
constexpr CGFloat previewCornerRadius = 8;
constexpr CGFloat previewBadgeInset = 8;
constexpr CGFloat previewBadgeHorizontalPadding = 6;
constexpr CGFloat previewBadgeVerticalPadding = 2;
// More than half any badge height; the drawing clamps it, so the badge is a capsule.
constexpr CGFloat previewBadgeCapsuleCornerRadius = 100;
constexpr CGFloat promptSheetInset = 16;
constexpr CGFloat promptSheetTopInset = 20;
constexpr CGFloat promptSheetSpacing = 16;
constexpr CGFloat promptSheetInformativeTextSpacing = 9;
constexpr CGFloat promptSheetButtonSpacing = 6;
constexpr CGFloat promptSheetMinimumContentWidth = 260;
constexpr CGFloat promptSheetMaximumContentWidth = 420;
constexpr CGFloat promptSheetMinimumScrolledHeight = 120;
constexpr CGFloat promptSheetScreenMargin = 32;

// NSStackView does not stretch its views to its own width.
static void pinToWidthOfStack(NSView *view, NSStackView *stack)
{
    [NSLayoutConstraint activateConstraints:@[
        [[view leadingAnchor] constraintEqualToAnchor:[stack leadingAnchor]],
        [[view trailingAnchor] constraintEqualToAnchor:[stack trailingAnchor]],
    ]];
}

@interface WKCaptureDeviceChooserLevelView : NSView {
    WebKit::CapturePreviewLevelMeterState _state;
}
- (void)setLevel:(float)level;
- (void)reset;
@end

@implementation WKCaptureDeviceChooserLevelView

- (NSSize)intrinsicContentSize
{
    return NSMakeSize(NSViewNoIntrinsicMetric, WebKit::CapturePreviewLevelMeterState::height);
}

- (BOOL)isAccessibilityElement
{
    return YES;
}

- (NSAccessibilityRole)accessibilityRole
{
    return NSAccessibilityLevelIndicatorRole;
}

- (NSString *)accessibilityLabel
{
    return WEB_UI_STRING_KEY(@"Microphone level", "Microphone level (usermedia accessibility label)", @"Accessibility label for the microphone level meter in the user media prompt").createNSString().autorelease();
}

- (id)accessibilityValue
{
    return @(std::round(_state.levelFraction() * 100));
}

- (NSString *)accessibilityValueDescription
{
    return [NSNumberFormatter localizedStringFromNumber:@(_state.levelFraction()) numberStyle:NSNumberFormatterPercentStyle];
}

- (id)accessibilityMinValue
{
    return @0;
}

- (id)accessibilityMaxValue
{
    return @100;
}

- (void)setLevel:(float)level
{
    if (_state.update(level, MonotonicTime::now()))
        [self setNeedsDisplay:YES];
}

- (void)reset
{
    if (_state.reset())
        [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)rect
{
    using State = WebKit::CapturePreviewLevelMeterState;
    NSRect bounds = [self bounds];
    CGFloat radius = State::segmentWidth / 2;

    for (unsigned index = 0; index < State::segmentCount; ++index) {
        switch (_state.segment(index)) {
        case State::Segment::Peak:
            [[NSColor controlAccentColor] setFill];
            break;
        case State::Segment::Lit:
            [[NSColor secondaryLabelColor] setFill];
            break;
        case State::Segment::Unlit:
            [[NSColor quaternaryLabelColor] setFill];
            break;
        }

        NSRect segment = NSMakeRect(NSMinX(bounds) + State::segmentX(index, NSWidth(bounds)), NSMinY(bounds), State::segmentWidth, NSHeight(bounds));
        [[NSBezierPath bezierPathWithRoundedRect:segment xRadius:radius yRadius:radius] fill];
    }
}

@end

// Draws its own rounded background instead of using NSBox, whose contentViewMargins position the
// content view by frame and so leave a constraint based content view unresolved.
@interface WKCaptureDeviceChooserRoundedView : NSView {
    RetainPtr<NSColor> _fillColor;
    CGFloat _cornerRadius;
}
- (instancetype)initWithFillColor:(NSColor *)fillColor cornerRadius:(CGFloat)cornerRadius;
@end

@implementation WKCaptureDeviceChooserRoundedView

- (instancetype)initWithFillColor:(NSColor *)fillColor cornerRadius:(CGFloat)cornerRadius
{
    if (!(self = [super initWithFrame:NSZeroRect]))
        return nil;

    _fillColor = fillColor;
    _cornerRadius = cornerRadius;
    [self setTranslatesAutoresizingMaskIntoConstraints:NO];

    return self;
}

- (void)drawRect:(NSRect)rect
{
    NSRect bounds = [self bounds];
    CGFloat radius = std::min(_cornerRadius, NSHeight(bounds) / 2);

    [_fillColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:bounds xRadius:radius yRadius:radius] fill];
}

@end

@interface WKCaptureDeviceChooser : NSObject {
    RetainPtr<NSView> _view;
    RetainPtr<NSPopUpButton> _videoPopUp;
    RetainPtr<NSPopUpButton> _audioPopUp;
    RetainPtr<WKCaptureDeviceChooserLevelView> _audioLevelMeter;
    RetainPtr<NSArray<NSButton *>> _allowButtons;

    RetainPtr<NSView> _previewContainer;
    RetainPtr<CALayer> _previewLayerHost;
    WebKit::LayerHostingContextID _previewHostingContextID;
    Function<void(std::optional<WebCore::CaptureDevice>&& videoDevice, std::optional<WebCore::CaptureDevice>&& audioDevice)> _selectionChangedHandler;

    WebKit::CapturePreviewDeviceSelection _selection;
    // Capture waits for the prompt to be on screen, so the camera is never on behind a sheet still queued.
    BOOL _isPreviewing;
    BOOL _hasStopped;
}

- (instancetype)initWithVideoDevices:(Vector<WebCore::CaptureDevice>&&)videoDevices audioDevices:(Vector<WebCore::CaptureDevice>&&)audioDevices;
- (NSView *)view;
- (NSString *)selectedVideoDeviceID;
- (NSString *)selectedAudioDeviceID;
- (void)setAllowButtons:(NSArray<NSButton *> *)allowButtons;
- (void)setPreviewHostingContext:(const WebCore::HostingContext&)hostingContext gpuProcessIdentifier:(ProcessID)gpuProcessIdentifier;
- (void)setSelectionChangedHandler:(Function<void(std::optional<WebCore::CaptureDevice>&& videoDevice, std::optional<WebCore::CaptureDevice>&& audioDevice)>&&)handler;
- (void)setAudioLevel:(float)level;
- (void)updateWithVideoDevices:(Vector<WebCore::CaptureDevice>&&)videoDevices audioDevices:(Vector<WebCore::CaptureDevice>&&)audioDevices;
- (void)beginPreview;
- (void)stop;
- (BOOL)isStopped;
- (CGSize)previewSize;

@end

@implementation WKCaptureDeviceChooser

- (instancetype)initWithVideoDevices:(Vector<WebCore::CaptureDevice>&&)videoDevices audioDevices:(Vector<WebCore::CaptureDevice>&&)audioDevices
{
    if (!(self = [super init]))
        return nil;

    _selection = { WTF::move(videoDevices), WTF::move(audioDevices) };

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

    if (_selection.requestNeeds(WebKit::CapturePreviewDeviceType::Camera)) {
        RetainPtr badgeLabel = adoptNS([[NSTextField alloc] initWithFrame:NSZeroRect]);
        [badgeLabel setStringValue:WEB_UI_STRING_KEY(@"Preview", "Preview (usermedia)", @"Badge label identifying the live camera preview in the user media prompt").createNSString().get()];
        [badgeLabel setEditable:NO];
        [badgeLabel setSelectable:NO];
        [badgeLabel setBordered:NO];
        [badgeLabel setDrawsBackground:NO];
        [badgeLabel setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
        [badgeLabel setTextColor:[NSColor alternateSelectedControlTextColor]];
        [badgeLabel setTranslatesAutoresizingMaskIntoConstraints:NO];

        RetainPtr badge = adoptNS([[WKCaptureDeviceChooserRoundedView alloc] initWithFillColor:[NSColor controlAccentColor] cornerRadius:previewBadgeCapsuleCornerRadius]);
        [badge addSubview:badgeLabel.get()];
        [_previewContainer addSubview:badge.get()];

        _videoPopUp = adoptNS([[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO]);
        [_videoPopUp setTarget:self];
        [_videoPopUp setAction:@selector(_selectedVideoDeviceDidChange:)];
        // The selected item is only the device's name, which says nothing about what the menu chooses.
        [_videoPopUp setAccessibilityLabel:WEB_UI_STRING_KEY(@"Camera", "Camera (usermedia accessibility label)", @"Accessibility label for the camera menu in the user media prompt").createNSString().get()];
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

    if (_selection.requestNeeds(WebKit::CapturePreviewDeviceType::Microphone)) {
        RetainPtr microphoneIcon = adoptNS([[NSImageView alloc] init]);
        [microphoneIcon setImage:[NSImage imageWithSystemSymbolName:@"mic" accessibilityDescription:nil]];
        [microphoneIcon setContentTintColor:[NSColor secondaryLabelColor]];
        // Decorative: the meter and the menu beside it carry the meaning.
        [microphoneIcon setAccessibilityElement:NO];
        [microphoneIcon setTranslatesAutoresizingMaskIntoConstraints:NO];
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
        [_audioPopUp setAccessibilityLabel:WEB_UI_STRING_KEY(@"Microphone", "Microphone (usermedia accessibility label)", @"Accessibility label for the microphone menu in the user media prompt").createNSString().get()];
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

    // Centered rather than pinned to the sides, because the prompt can be wider than the preview: a
    // long message, or a microphone-only request, which has no preview to set the width.
    [NSLayoutConstraint activateConstraints:@[
        [[contentStack topAnchor] constraintEqualToAnchor:[_view topAnchor]],
        [[contentStack bottomAnchor] constraintEqualToAnchor:[_view bottomAnchor]],
        [[contentStack centerXAnchor] constraintEqualToAnchor:[_view centerXAnchor]],
        [[contentStack leadingAnchor] constraintGreaterThanOrEqualToAnchor:[_view leadingAnchor]],
        [[contentStack trailingAnchor] constraintLessThanOrEqualToAnchor:[_view trailingAnchor]],
    ]];
    [_view layoutSubtreeIfNeeded];
    [_view setFrameSize:[_view fittingSize]];

    [self _rebuildMenus];

    return self;
}

- (NSView *)_createSectionWithContentView:(NSView *)contentView
{
    RetainPtr section = adoptNS([[WKCaptureDeviceChooserRoundedView alloc] initWithFillColor:[NSColor quaternarySystemFillColor] cornerRadius:sectionCornerRadius]);
    [section addSubview:contentView];
    [NSLayoutConstraint activateConstraints:@[
        [[contentView topAnchor] constraintEqualToAnchor:[section topAnchor] constant:sectionInset],
        [[contentView bottomAnchor] constraintEqualToAnchor:[section bottomAnchor] constant:-sectionInset],
        [[contentView leadingAnchor] constraintEqualToAnchor:[section leadingAnchor] constant:sectionInset],
        [[contentView trailingAnchor] constraintEqualToAnchor:[section trailingAnchor] constant:-sectionInset],
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

- (NSString *)selectedVideoDeviceID
{
    return nsStringNilIfEmpty(_selection.selectedDeviceID(WebKit::CapturePreviewDeviceType::Camera)).autorelease();
}

- (NSString *)selectedAudioDeviceID
{
    return nsStringNilIfEmpty(_selection.selectedDeviceID(WebKit::CapturePreviewDeviceType::Microphone)).autorelease();
}

- (void)_rebuildMenu:(NSPopUpButton *)popUp type:(WebKit::CapturePreviewDeviceType)type
{
    if (!popUp)
        return;

    // Menu items are built directly because -addItemWithTitle: drops duplicate titles,
    // and two devices can share a label while still needing separate entries. Built in device order,
    // so an item's index is the device's index.
    auto& devices = _selection.devices(type);
    RetainPtr menu = adoptNS([[NSMenu alloc] init]);
    for (auto& device : devices) {
        RetainPtr title = device.label().createNSString();
        RetainPtr item = adoptNS([[NSMenuItem alloc] initWithTitle:title.get() action:nil keyEquivalent:@""]);
        [item setToolTip:title.get()];
        [menu addItem:item.get()];
    }

    [popUp setMenu:menu.get()];

    if (!devices.isEmpty())
        [popUp selectItemAtIndex:_selection.selectedIndex(type)];

    // Shown even for a single device, so the user can see which one will be shared.
    [popUp setHidden:devices.isEmpty()];
    [popUp setEnabled:devices.size() > 1];
}

- (void)_rebuildMenus
{
    [self _rebuildMenu:_videoPopUp.get() type:WebKit::CapturePreviewDeviceType::Camera];
    [self _rebuildMenu:_audioPopUp.get() type:WebKit::CapturePreviewDeviceType::Microphone];
}

- (void)setAllowButtons:(NSArray<NSButton *> *)allowButtons
{
    _allowButtons = allowButtons;
    [self _updateAllowButtonEnablement];
}

- (void)_updateAllowButtonEnablement
{
    bool canStillSatisfyRequest = _selection.canStillSatisfyRequest();
    for (NSButton *allowButton in _allowButtons.get())
        [allowButton setEnabled:canStillSatisfyRequest];
}

- (void)updateWithVideoDevices:(Vector<WebCore::CaptureDevice>&&)videoDevices audioDevices:(Vector<WebCore::CaptureDevice>&&)audioDevices
{
    bool previewNeedsRestart = _selection.update(WTF::move(videoDevices), WTF::move(audioDevices));
    [self _rebuildMenus];
    [self _updateAllowButtonEnablement];

    // A level or peak left showing after the microphone was unplugged would read as a live signal
    // from a device that is no longer available.
    if (_selection.devices(WebKit::CapturePreviewDeviceType::Microphone).isEmpty())
        [_audioLevelMeter reset];

    if (previewNeedsRestart)
        [self _notifySelectionChanged];
}

- (void)setPreviewHostingContext:(const WebCore::HostingContext&)hostingContext gpuProcessIdentifier:(ProcessID)gpuProcessIdentifier
{
    UNUSED_PARAM(gpuProcessIdentifier);
    // A start that was still in flight can reply after the prompt stopped; its layer must not come back.
    if (_hasStopped && hostingContext.contextID)
        return;
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
    if (_hasStopped)
        return;
    _selectionChangedHandler = WTF::move(handler);
    [self _notifySelectionChanged];
}

- (BOOL)isStopped
{
    return _hasStopped;
}

- (CGSize)previewSize
{
    return CGSizeMake(previewWidth, previewHeight);
}

- (void)setAudioLevel:(float)level
{
    [_audioLevelMeter setLevel:level];
}

- (void)beginPreview
{
    if (_isPreviewing || _hasStopped)
        return;
    _isPreviewing = YES;
    [self _notifySelectionChanged];
}

- (void)_notifySelectionChanged
{
    if (!_selectionChangedHandler || !_isPreviewing || _hasStopped)
        return;

    _selectionChangedHandler(_selection.selectedDevice(WebKit::CapturePreviewDeviceType::Camera), _selection.selectedDevice(WebKit::CapturePreviewDeviceType::Microphone));
}

- (void)_popUp:(NSPopUpButton *)popUp didSelectDeviceOfType:(WebKit::CapturePreviewDeviceType)type
{
    NSInteger index = [popUp indexOfSelectedItem];
    if (index < 0 || static_cast<size_t>(index) >= _selection.devices(type).size())
        return;

    _selection.select(type, index);
    [self _notifySelectionChanged];
}

- (void)_selectedVideoDeviceDidChange:(id)sender
{
    [self _popUp:_videoPopUp.get() didSelectDeviceOfType:WebKit::CapturePreviewDeviceType::Camera];
}

- (void)_selectedAudioDeviceDidChange:(id)sender
{
    [self _popUp:_audioPopUp.get() didSelectDeviceOfType:WebKit::CapturePreviewDeviceType::Microphone];
}

- (void)stop
{
    _hasStopped = YES;
    _selectionChangedHandler = nullptr;
    [self setPreviewHostingContext:WebCore::HostingContext { } gpuProcessIdentifier:0];
    [_audioLevelMeter reset];
}

@end

// NSAlert puts two buttons side by side and cannot be told to stack them. Each button here ends the
// sheet with the response NSAlert would have given it.
@interface WKCapturePreviewPromptSheet : NSObject {
    RetainPtr<NSString> _messageText;
    RetainPtr<NSString> _informativeText;
    RetainPtr<NSView> _accessoryView;
    RetainPtr<NSStackView> _buttonStack;
    RetainPtr<NSPanel> _window;
    WeakObjCPtr<NSWindow> _parentWindow;
    BlockPtr<void()> _didPresentHandler;
    BlockPtr<void(NSModalResponse)> _completionHandler;
    RetainPtr<id> _occlusionObserver;
    CGFloat _widestButtonWidth;
}

- (instancetype)initWithMessageText:(NSString *)messageText informativeText:(NSString *)informativeText accessoryView:(NSView *)accessoryView;
- (NSButton *)addButtonWithTitle:(NSString *)title response:(NSModalResponse)response;
- (void)beginSheetModalForWindow:(NSWindow *)parentWindow didPresentHandler:(void (^)(void))didPresentHandler completionHandler:(void (^)(NSModalResponse))completionHandler;
- (void)dismissWithResponse:(NSModalResponse)response;

@end

@implementation WKCapturePreviewPromptSheet

- (instancetype)initWithMessageText:(NSString *)messageText informativeText:(NSString *)informativeText accessoryView:(NSView *)accessoryView
{
    if (!(self = [super init]))
        return nil;

    _messageText = messageText;
    _informativeText = informativeText;
    _accessoryView = accessoryView;

    _buttonStack = adoptNS([[NSStackView alloc] init]);
    [_buttonStack setOrientation:NSUserInterfaceLayoutOrientationVertical];
    [_buttonStack setDistribution:NSStackViewDistributionFill];
    [_buttonStack setSpacing:promptSheetButtonSpacing];
    [_buttonStack setTranslatesAutoresizingMaskIntoConstraints:NO];

    return self;
}

- (NSButton *)addButtonWithTitle:(NSString *)title response:(NSModalResponse)response
{
    RetainPtr button = [NSButton buttonWithTitle:title target:self action:@selector(_buttonClicked:)];
    [button setTag:response];
    [button setKeyEquivalent:@""];
    [button setControlSize:NSControlSizeLarge];
    [button setToolTip:title];
    [button setTranslatesAutoresizingMaskIntoConstraints:NO];
    _widestButtonWidth = std::max(_widestButtonWidth, [button fittingSize].width);
    [_buttonStack addArrangedSubview:button.get()];
    pinToWidthOfStack(button.get(), _buttonStack.get());
    return button.autorelease();
}

- (void)dealloc
{
    [self _stopObservingPresentation];
    [super dealloc];
}

- (void)beginSheetModalForWindow:(NSWindow *)parentWindow didPresentHandler:(void (^)(void))didPresentHandler completionHandler:(void (^)(NSModalResponse))completionHandler
{
    // An audio-only chooser has no intrinsic width, so the sheet sets a minimum. Button titles can come
    // from the application and don't wrap, so the sheet widens for them up to a limit; beyond it they
    // truncate, and the tooltip and VoiceOver still give the whole title.
    CGFloat contentWidth = std::max({ promptSheetMinimumContentWidth, NSWidth([_accessoryView frame]), std::min(_widestButtonWidth, promptSheetMaximumContentWidth) });

    RetainPtr<NSMutableArray<NSView *>> arrangedViews = adoptNS([[NSMutableArray alloc] init]);

    RetainPtr messageLabel = [NSTextField wrappingLabelWithString:_messageText.get()];
    [messageLabel setFont:[NSFont boldSystemFontOfSize:[NSFont systemFontSize]]];
    [messageLabel setSelectable:NO];
    // Without this the label measures as one line, and the sheet is sized too short to show it.
    [messageLabel setPreferredMaxLayoutWidth:contentWidth];
    [messageLabel setTranslatesAutoresizingMaskIntoConstraints:NO];
    [arrangedViews addObject:messageLabel.get()];

    if (_informativeText) {
        RetainPtr informativeLabel = [NSTextField wrappingLabelWithString:_informativeText.get()];
        [informativeLabel setFont:[NSFont systemFontOfSize:[NSFont systemFontSize]]];
        [informativeLabel setSelectable:NO];
        [informativeLabel setPreferredMaxLayoutWidth:contentWidth];
        [informativeLabel setTranslatesAutoresizingMaskIntoConstraints:NO];
        [arrangedViews addObject:informativeLabel.get()];
    }

    [_accessoryView setTranslatesAutoresizingMaskIntoConstraints:NO];
    [arrangedViews addObject:_accessoryView.get()];

    RetainPtr scrolledStack = adoptNS([[NSStackView alloc] init]);
    [scrolledStack setOrientation:NSUserInterfaceLayoutOrientationVertical];
    [scrolledStack setDistribution:NSStackViewDistributionFill];
    [scrolledStack setSpacing:promptSheetSpacing];
    [scrolledStack setTranslatesAutoresizingMaskIntoConstraints:NO];
    for (NSView *view in arrangedViews.get()) {
        [scrolledStack addArrangedSubview:view];
        pinToWidthOfStack(view, scrolledStack.get());
    }
    // Kept close to the message, as NSAlert does, so the two read as one block of text.
    if (_informativeText)
        [scrolledStack setCustomSpacing:promptSheetInformativeTextSpacing afterView:messageLabel.get()];

    // Long informative text, both devices and extra buttons can be taller than a small screen. Only the
    // text and devices scroll, so the buttons always stay reachable.
    RetainPtr scrollView = adoptNS([[NSScrollView alloc] initWithFrame:NSZeroRect]);
    [scrollView setTranslatesAutoresizingMaskIntoConstraints:NO];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setAutohidesScrollers:YES];
    [scrollView setDrawsBackground:NO];
    [scrollView setDocumentView:scrolledStack.get()];
    RetainPtr clipView = [scrollView contentView];
    [NSLayoutConstraint activateConstraints:@[
        [[scrolledStack topAnchor] constraintEqualToAnchor:[clipView topAnchor]],
        [[scrolledStack leadingAnchor] constraintEqualToAnchor:[clipView leadingAnchor]],
        [[scrolledStack widthAnchor] constraintEqualToConstant:contentWidth],
    ]];
    [scrolledStack layoutSubtreeIfNeeded];

    RetainPtr screen = [parentWindow screen] ?: [NSScreen mainScreen];
    CGFloat availableHeight = NSHeight([screen visibleFrame]) - promptSheetTopInset - promptSheetInset - promptSheetScreenMargin - promptSheetSpacing - [_buttonStack fittingSize].height;
    CGFloat scrolledHeight = std::min([scrolledStack fittingSize].height, std::max(availableHeight, promptSheetMinimumScrolledHeight));
    [[[scrollView heightAnchor] constraintEqualToConstant:scrolledHeight] setActive:YES];

    RetainPtr contentStack = adoptNS([[NSStackView alloc] init]);
    [contentStack setOrientation:NSUserInterfaceLayoutOrientationVertical];
    [contentStack setDistribution:NSStackViewDistributionFill];
    [contentStack setSpacing:promptSheetSpacing];
    [contentStack setTranslatesAutoresizingMaskIntoConstraints:NO];
    for (NSView *view in @[ scrollView.get(), _buttonStack.get() ]) {
        [contentStack addArrangedSubview:view];
        pinToWidthOfStack(view, contentStack.get());
    }

    RetainPtr contentView = adoptNS([[NSView alloc] initWithFrame:NSZeroRect]);
    [contentView addSubview:contentStack.get()];
    [NSLayoutConstraint activateConstraints:@[
        [[contentStack topAnchor] constraintEqualToAnchor:[contentView topAnchor] constant:promptSheetTopInset],
        [[contentStack bottomAnchor] constraintEqualToAnchor:[contentView bottomAnchor] constant:-promptSheetInset],
        [[contentStack leadingAnchor] constraintEqualToAnchor:[contentView leadingAnchor] constant:promptSheetInset],
        [[contentStack trailingAnchor] constraintEqualToAnchor:[contentView trailingAnchor] constant:-promptSheetInset],
        [[contentStack widthAnchor] constraintEqualToConstant:contentWidth],
    ]];

    _window = adoptNS([[NSPanel alloc] initWithContentRect:NSZeroRect styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES]);
    [_window setReleasedWhenClosed:NO];
    [_window setContentView:contentView.get()];
    [contentView layoutSubtreeIfNeeded];
    [_window setContentSize:[contentView fittingSize]];

    _parentWindow = parentWindow;
    _didPresentHandler = makeBlockPtr(didPresentHandler);
    // A queued sheet is not on screen yet, so presentation is taken from the panel becoming visible.
    _occlusionObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidChangeOcclusionStateNotification object:_window.get() queue:nil usingBlock:makeBlockPtr([weakSelf = WeakObjCPtr<WKCapturePreviewPromptSheet>(self)](NSNotification *) {
        [weakSelf.get() _presentationMayHaveChanged];
    }).get()];

    _completionHandler = makeBlockPtr(completionHandler);
    [parentWindow beginSheet:_window.get() completionHandler:makeBlockPtr([weakSelf = WeakObjCPtr<WKCapturePreviewPromptSheet>(self)](NSModalResponse returnCode) {
        [weakSelf.get() _finishWithResponse:returnCode];
    }).get()];

    [self _presentationMayHaveChanged];
}

- (void)_presentationMayHaveChanged
{
    if (!_didPresentHandler || !([_window occlusionState] & NSWindowOcclusionStateVisible))
        return;

    auto didPresentHandler = std::exchange(_didPresentHandler, nullptr);
    [self _stopObservingPresentation];
    didPresentHandler();
}

- (void)_stopObservingPresentation
{
    _didPresentHandler = nullptr;
    if (RetainPtr observer = std::exchange(_occlusionObserver, nil))
        [[NSNotificationCenter defaultCenter] removeObserver:observer.get()];
}

- (void)_finishWithResponse:(NSModalResponse)response
{
    [self _stopObservingPresentation];
    if (auto completionHandler = std::exchange(_completionHandler, nullptr))
        completionHandler(response);
}

- (void)dismissWithResponse:(NSModalResponse)response
{
    if (!_completionHandler)
        return;

    // A sheet still in the queue has no sheet parent yet, so the window it was begun on is used.
    RetainPtr parentWindow = [_window sheetParent] ?: _parentWindow.get().get();
    if (parentWindow) {
        [parentWindow endSheet:_window.get() returnCode:response];
        return;
    }

    // With no window left to end the sheet on, AppKit would never call back and the request would
    // never be answered.
    [_window orderOut:nil];
    [self _finishWithResponse:response];
}

- (void)_buttonClicked:(NSButton *)sender
{
    [[_window sheetParent] endSheet:_window.get() returnCode:[sender tag]];
}

@end

#endif // PLATFORM(MAC) && ENABLE(MEDIA_STREAM)

#if ENABLE(MEDIA_STREAM)

// Stands in for the sheet or view controller in API tests, so the real preview runs with no UI.
@interface WKCapturePreviewPromptForTesting : NSObject {
    WebKit::CapturePreviewDeviceSelection _selection;
    Function<void(std::optional<WebCore::CaptureDevice>&&, std::optional<WebCore::CaptureDevice>&&)> _selectionChangedHandler;
    uint32_t _previewHostingContextID;
    unsigned _previewLayerCount;
    unsigned _audioLevelUpdateCount;
    BOOL _isPreviewing;
    BOOL _hasStopped;
}

- (instancetype)initWithVideoDevices:(Vector<WebCore::CaptureDevice>&&)videoDevices audioDevices:(Vector<WebCore::CaptureDevice>&&)audioDevices;
- (const WebKit::CapturePreviewDeviceSelection&)selection;
- (NSString *)selectedVideoDeviceID;
- (NSString *)selectedAudioDeviceID;
- (unsigned)previewLayerCount;
- (unsigned)audioLevelUpdateCount;
- (BOOL)hasPreviewLayer;
- (void)setPreviewHostingContext:(const WebCore::HostingContext&)hostingContext gpuProcessIdentifier:(ProcessID)gpuProcessIdentifier;
- (void)setSelectionChangedHandler:(Function<void(std::optional<WebCore::CaptureDevice>&& videoDevice, std::optional<WebCore::CaptureDevice>&& audioDevice)>&&)handler;
- (void)setAudioLevel:(float)level;
- (void)updateWithVideoDevices:(Vector<WebCore::CaptureDevice>&&)videoDevices audioDevices:(Vector<WebCore::CaptureDevice>&&)audioDevices;
- (void)selectDeviceOfType:(WebKit::CapturePreviewDeviceType)type atIndex:(size_t)index;
- (void)beginPreview;
- (void)stop;
- (BOOL)isStopped;
- (CGSize)previewSize;

@end

@implementation WKCapturePreviewPromptForTesting

- (instancetype)initWithVideoDevices:(Vector<WebCore::CaptureDevice>&&)videoDevices audioDevices:(Vector<WebCore::CaptureDevice>&&)audioDevices
{
    if (!(self = [super init]))
        return nil;

    _selection = { WTF::move(videoDevices), WTF::move(audioDevices) };
    return self;
}

- (const WebKit::CapturePreviewDeviceSelection&)selection
{
    return _selection;
}

- (NSString *)selectedVideoDeviceID
{
    return nsStringNilIfEmpty(_selection.selectedDeviceID(WebKit::CapturePreviewDeviceType::Camera)).autorelease();
}

- (NSString *)selectedAudioDeviceID
{
    return nsStringNilIfEmpty(_selection.selectedDeviceID(WebKit::CapturePreviewDeviceType::Microphone)).autorelease();
}

- (unsigned)previewLayerCount
{
    return _previewLayerCount;
}

- (unsigned)audioLevelUpdateCount
{
    return _audioLevelUpdateCount;
}

- (BOOL)hasPreviewLayer
{
    return !!_previewHostingContextID;
}

- (void)setPreviewHostingContext:(const WebCore::HostingContext&)hostingContext gpuProcessIdentifier:(ProcessID)gpuProcessIdentifier
{
    UNUSED_PARAM(gpuProcessIdentifier);
    if (_hasStopped && hostingContext.contextID)
        return;
    if (hostingContext.contextID && hostingContext.contextID != _previewHostingContextID)
        ++_previewLayerCount;
    _previewHostingContextID = hostingContext.contextID;
}

- (void)setSelectionChangedHandler:(Function<void(std::optional<WebCore::CaptureDevice>&&, std::optional<WebCore::CaptureDevice>&&)>&&)handler
{
    if (_hasStopped)
        return;
    _selectionChangedHandler = WTF::move(handler);
    [self _notifySelectionChanged];
}

- (void)setAudioLevel:(float)level
{
    UNUSED_PARAM(level);
    if (!_hasStopped)
        ++_audioLevelUpdateCount;
}

- (void)updateWithVideoDevices:(Vector<WebCore::CaptureDevice>&&)videoDevices audioDevices:(Vector<WebCore::CaptureDevice>&&)audioDevices
{
    if (_selection.update(WTF::move(videoDevices), WTF::move(audioDevices)))
        [self _notifySelectionChanged];
}

- (void)selectDeviceOfType:(WebKit::CapturePreviewDeviceType)type atIndex:(size_t)index
{
    if (index >= _selection.devices(type).size() || index == _selection.selectedIndex(type))
        return;
    _selection.select(type, index);
    [self _notifySelectionChanged];
}

- (void)beginPreview
{
    if (_isPreviewing || _hasStopped)
        return;
    _isPreviewing = YES;
    [self _notifySelectionChanged];
}

- (void)stop
{
    _hasStopped = YES;
    _selectionChangedHandler = nullptr;
    _previewHostingContextID = 0;
}

- (BOOL)isStopped
{
    return _hasStopped;
}

- (CGSize)previewSize
{
    return CGSizeMake(320, 180);
}

- (void)_notifySelectionChanged
{
    if (!_selectionChangedHandler || !_isPreviewing || _hasStopped)
        return;

    _selectionChangedHandler(_selection.selectedDevice(WebKit::CapturePreviewDeviceType::Camera), _selection.selectedDevice(WebKit::CapturePreviewDeviceType::Microphone));
}

@end

#endif // ENABLE(MEDIA_STREAM)

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
    auto domain = WTF::URLHelpers::userVisibleURL(host.utf8().span());
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
    if (RetainPtr displayName = dynamic_objc_cast<NSString>(appBundle.get().infoDictionary[bridge_cast(_kCFBundleDisplayNameKey)]))
        return displayName;
    return dynamic_objc_cast<NSString>(appBundle.get().infoDictionary[bridge_cast(kCFBundleNameKey)]);
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

#if PLATFORM(MAC)
static MediaPermissionPromptResult promptResultForAlertResponse(NSModalResponse returnCode, const Vector<MediaPermissionPromptAdditionalAction>& additionalActions)
{
    if (returnCode == NSAlertFirstButtonReturn)
        return { .granted = true, .wasAnswered = true };
    if (returnCode == NSAlertSecondButtonReturn)
        return { .granted = false, .wasAnswered = true };
    // What the dismisser ends the sheet with: the prompt closed without an answer.
    if (returnCode == NSModalResponseAbort)
        return { };

    // Additional actions respond third onward wherever they appear, so the built-in two keep the
    // responses AppKit documents and an additional action's index falls out of the response.
    size_t index = returnCode - NSAlertThirdButtonReturn;
    if (index >= additionalActions.size()) {
        ASSERT_NOT_REACHED();
        return { };
    }

    return {
        .granted = additionalActions[index].decision == MediaPermissionPromptAdditionalAction::Decision::Allow,
        .wasAnswered = true,
        .chosenAdditionalActionIndex = index,
    };
}
#endif

static RetainPtr<NSString> promptMessageText(const PermissionPromptRequest& request)
{
    if (!request.customization.messageText.isNull())
        return request.customization.messageText.createNSString();
    return alertMessageText(request.reason, request.origin);
}

static RetainPtr<NSString> promptAllowButtonText(const PermissionPromptRequest& request)
{
    if (!request.customization.allowButtonTitle.isNull())
        return request.customization.allowButtonTitle.createNSString();
    return allowButtonText(request.reason);
}

static RetainPtr<NSString> promptDenyButtonText(const PermissionPromptRequest& request)
{
    if (!request.customization.denyButtonTitle.isNull())
        return request.customization.denyButtonTitle.createNSString();
    return doNotAllowButtonText(request.reason);
}

static RetainPtr<NSString> promptInformativeText(const PermissionPromptRequest& request)
{
    if (request.customization.informativeText.isNull())
        return nil;
    return request.customization.informativeText.createNSString();
}

void alertForPermission(WebPageProxy& page, PermissionPromptRequest&& request, CompletionHandler<void(MediaPermissionPromptResult&&)>&& completionHandler)
{
    ASSERT(isMainRunLoop());

#if PLATFORM(IOS_FAMILY)
    if (request.reason == MediaPermissionReason::DeviceOrientation) {
        if (auto& userPermissionHandler = page.deviceOrientationUserPermissionHandlerForTesting())
            return completionHandler({ .granted = userPermissionHandler() });
    }
#endif

    RetainPtr webView = page.cocoaView();
    if (!webView)
        return completionHandler({ });

    RetainPtr alertTitle = promptMessageText(request);
    if (!alertTitle)
        return completionHandler({ });

    RetainPtr allowButtonString = promptAllowButtonText(request);
    RetainPtr doNotAllowButtonString = promptDenyButtonText(request);
    auto completionBlock = makeBlockPtr(WTF::move(completionHandler));

#if PLATFORM(MAC)
    RetainPtr alert = adoptNS([NSAlert new]);
    [alert setMessageText:alertTitle.get()];
    if (RetainPtr informativeText = promptInformativeText(request))
        [alert setInformativeText:informativeText.get()];
    RetainPtr button = [alert addButtonWithTitle:allowButtonString.get()];
    [button setKeyEquivalent:@""];
    // Tags keep the responses promptResultForAlertResponse expects, which would otherwise follow position.
    for (size_t index = 0; index < request.customization.additionalActions.size(); ++index) {
        button = [alert addButtonWithTitle:request.customization.additionalActions[index].title.createNSString().get()];
        // Cleared so AppKit does not hand Return to a button the application supplied.
        [button setKeyEquivalent:@""];
        [button setTag:NSAlertThirdButtonReturn + index];
    }
    button = [alert addButtonWithTitle:doNotAllowButtonString.get()];
    [button setKeyEquivalent:@"\E"];
    [button setTag:NSAlertSecondButtonReturn];

    [alert beginSheetModalForWindow:retainPtr([webView window]).get() completionHandler:[completionBlock, additionalActions = WTF::move(request.customization.additionalActions)](NSModalResponse returnCode) {
        completionBlock(promptResultForAlertResponse(returnCode, additionalActions));
    }];
#else
    RetainPtr alert = WebKit::createUIAlertController(alertTitle.get(), promptInformativeText(request).get());
    RetainPtr allowAction = [UIAlertAction actionWithTitle:allowButtonString.get() style:UIAlertActionStyleDefault handler:[completionBlock](UIAlertAction *) {
        completionBlock({ .granted = true, .wasAnswered = true });
    }];

    RetainPtr doNotAllowAction = [UIAlertAction actionWithTitle:doNotAllowButtonString.get() style:UIAlertActionStyleCancel handler:[completionBlock](UIAlertAction *) {
        completionBlock({ .granted = false, .wasAnswered = true });
    }];

    [alert addAction:allowAction.get()];

    for (size_t index = 0; index < request.customization.additionalActions.size(); ++index) {
        auto& action = request.customization.additionalActions[index];
        bool granted = action.decision == MediaPermissionPromptAdditionalAction::Decision::Allow;
        [alert addAction:[UIAlertAction actionWithTitle:action.title.createNSString().get() style:UIAlertActionStyleDefault handler:[completionBlock, index, granted](UIAlertAction *) {
            completionBlock({ .granted = granted, .wasAnswered = true, .chosenAdditionalActionIndex = index });
        }]];
    }

    [alert addAction:doNotAllowAction.get()];

#if PLATFORM(VISION)
    page.dispatchWillPresentModalUI();
#endif
    [[webView _wk_viewControllerForFullScreenPresentation] presentViewController:alert.get() animated:YES completion:nil];
#endif
}

void alertForPermission(WebPageProxy& page, MediaPermissionReason reason, const WebCore::SecurityOriginData& origin, CompletionHandler<void(bool)>&& completionHandler)
{
    alertForPermission(page, { .reason = reason, .origin = origin }, [completionHandler = WTF::move(completionHandler)](MediaPermissionPromptResult&& result) mutable {
        completionHandler(result.granted);
    });
}

#if ENABLE(MEDIA_STREAM)

// Capture in progress in any page is paused while the preview runs, with the same pause an application
// gets from -[WKWebView setMicrophoneCaptureState:], so the preview has the devices to itself: otherwise
// the preview's microphone retargets the unit another page is capturing from.
//
// The page identifier is fixed when the prompt opens. The live one changes on a provisional page swap,
// and a preview started under one identifier can only be stopped under the same one.
class CapturePreviewSession : public RefCounted<CapturePreviewSession> {
public:
    static Ref<CapturePreviewSession> create(WebCore::PageIdentifier pageIdentifier) { return adoptRef(*new CapturePreviewSession(pageIdentifier)); }
    ~CapturePreviewSession() { resume(); }

    WebCore::PageIdentifier pageIdentifier() const { return m_pageIdentifier; }

    void pause(WebCore::MediaProducerMutedStateFlags captureKinds, CompletionHandler<void()>&& completionHandler)
    {
        Ref callbackAggregator = CallbackAggregator::create(WTF::move(completionHandler));
        for (Ref process : WebProcessProxy::allProcesses()) {
            for (Ref page : process->pages()) {
                if (m_pausedPages.add(page.get()).isNewEntry)
                    page->beginCapturePreviewPause();
                page->pauseCaptureForCapturePreview(captureKinds, [callbackAggregator] { });
            }
        }
    }

    void resume()
    {
        for (Ref page : std::exchange(m_pausedPages, { }))
            page->endCapturePreviewPause();
    }

    unsigned nextSelection() { return ++m_selectionCount; }
    bool isLatestSelection(unsigned selection) const { return selection == m_selectionCount; }

    // Every process a page has frames in reports the GPU process exiting, so only the first restarts.
    bool connectTo(const GPUProcessProxy& gpuProcess)
    {
        if (m_gpuProcessIdentifier == gpuProcess.coreProcessIdentifier())
            return false;
        m_gpuProcessIdentifier = gpuProcess.coreProcessIdentifier();
        return true;
    }

private:
    explicit CapturePreviewSession(WebCore::PageIdentifier pageIdentifier)
        : m_pageIdentifier(pageIdentifier)
    {
    }

    WebCore::PageIdentifier m_pageIdentifier;
    WeakHashSet<WebPageProxy> m_pausedPages;
    unsigned m_selectionCount { 0 };
    Markable<WebCore::ProcessIdentifier> m_gpuProcessIdentifier;
};

template<typename Prompt>
static void connectPreviewToGPUProcess(WebPageProxy& page, Prompt *prompt, const WebCore::SecurityOriginData& origin, CapturePreviewSession& session)
{
    Ref gpuProcess = page.legacyMainFrameProcess().processPool().ensureGPUProcess();
    if (!session.connectTo(gpuProcess))
        return;

    gpuProcess->setCapturePreviewAudioLevelHandler(session.pageIdentifier(), [weakPrompt = WeakObjCPtr<Prompt>(prompt)](float level) {
        [weakPrompt.get() setAudioLevel:level];
    });

    [prompt setSelectionChangedHandler:[pageForPreview = WeakPtr { page }, weakPrompt = WeakObjCPtr<Prompt>(prompt), origin, session = Ref { session }](std::optional<WebCore::CaptureDevice>&& videoDevice, std::optional<WebCore::CaptureDevice>&& audioDevice) mutable {
        if (!pageForPreview || !weakPrompt.get())
            return;

        WebCore::MediaProducerMutedStateFlags captureKinds;
        if (videoDevice)
            captureKinds.add(WebCore::MediaProducerMutedState::VideoCaptureIsMuted);
        if (audioDevice)
            captureKinds.add(WebCore::MediaProducerMutedState::AudioCaptureIsMuted);

        // Started once the other pages have released the devices. A later selection supersedes this one
        // even if its pause finishes first.
        unsigned selection = session->nextSelection();
        session->pause(captureKinds, [pageForPreview, weakPrompt, origin, session, selection, videoDevice = WTF::move(videoDevice), audioDevice = WTF::move(audioDevice)] mutable {
            RefPtr page = pageForPreview;
            RetainPtr prompt = weakPrompt.get();
            if (!page || !prompt || [prompt isStopped] || !session->isLatestSelection(selection))
                return;

            // Re-fetched rather than captured: a GPU process that crashed mid-prompt is replaced, and a
            // captured Ref would keep addressing the dead one.
            Ref gpuProcess = page->legacyMainFrameProcess().processPool().ensureGPUProcess();
            CGSize previewSize = [prompt previewSize];
            gpuProcess->startCapturePreview(WTF::move(videoDevice), WTF::move(audioDevice), session->pageIdentifier(), WebCore::IntSize(static_cast<int>(previewSize.width), static_cast<int>(previewSize.height)), page->orientationForMediaCapture(), origin,
                [weakPrompt, gpuProcessIdentifier = gpuProcess->processID()](WebCore::HostingContext hostingContext) mutable {
                    [weakPrompt.get() setPreviewHostingContext:hostingContext gpuProcessIdentifier:gpuProcessIdentifier];
                });
        });
    }];
}

// Reported only once the GPU process has released the devices: the stop and the capture a grant
// starts arrive on different connections, so nothing else orders them.
template<typename Prompt>
static void stopPreviewAndReport(Prompt *prompt, CapturePreviewSession& session, MediaPermissionPromptResult&& result, CompletionHandler<void(MediaPermissionPromptResult&&)>&& completionHandler)
{
    if (result.granted) {
        result.selectedAudioDeviceUID = [prompt selectedAudioDeviceID];
        result.selectedVideoDeviceUID = [prompt selectedVideoDeviceID];
    }
    [prompt stop];

    // The preview's own stop may never arrive: the GPU process may have exited while it ran.
    auto stopRotationMonitoring = [pageIdentifier = session.pageIdentifier()] {
        if (RefPtr page = WebProcessProxy::webPage(pageIdentifier))
            page->stopMonitoringCaptureDeviceRotationForCapturePreview();
    };

    // Reached through the process rather than the page, which may already be gone when the prompt is
    // dismissed during teardown.
    RefPtr gpuProcess = GPUProcessProxy::singletonIfCreated();
    if (!gpuProcess) {
        stopRotationMonitoring();
        session.resume();
        return completionHandler(WTF::move(result));
    }

    gpuProcess->stopCapturePreview(session.pageIdentifier(), [stopRotationMonitoring = WTF::move(stopRotationMonitoring), session = Ref { session }, result = WTF::move(result), completionHandler = WTF::move(completionHandler)] mutable {
        stopRotationMonitoring();
        session->resume();
        completionHandler(WTF::move(result));
    });
}

template<typename Prompt>
static CapturePreviewDeviceListUpdater deviceListUpdater(Prompt *prompt)
{
    return [weakPrompt = WeakObjCPtr<Prompt>(prompt)](Vector<WebCore::CaptureDevice>&& videoDevices, Vector<WebCore::CaptureDevice>&& audioDevices) mutable {
        [weakPrompt.get() updateWithVideoDevices:WTF::move(videoDevices) audioDevices:WTF::move(audioDevices)];
    };
}

// The level handler was installed on the process that exited.
template<typename Prompt>
static CapturePreviewRestarter previewRestarter(WebPageProxy& page, Prompt *prompt, const WebCore::SecurityOriginData& origin, CapturePreviewSession& session)
{
    return [weakPage = WeakPtr { page }, weakPrompt = WeakObjCPtr<Prompt>(prompt), origin, session = Ref { session }] {
        RefPtr page = weakPage;
        RetainPtr prompt = weakPrompt.get();
        // Answered but still waiting for the old process to confirm the stop.
        if (!page || !prompt || [prompt isStopped])
            return;
        connectPreviewToGPUProcess(*page, prompt.get(), origin, session);
    };
}

class CapturePreviewPromptForTesting final : public MediaPermissionPromptForTesting {
public:
    static Ref<CapturePreviewPromptForTesting> create(String&& title, String&& informativeText, Vector<String>&& buttonTitles, bool showsPreview, RetainPtr<WKCapturePreviewPromptForTesting>&& prompt, RefPtr<CapturePreviewSession>&& session, Vector<MediaPermissionPromptAdditionalAction>&& additionalActions, CompletionHandler<void(MediaPermissionPromptResult&&)>&& completionHandler)
    {
        return adoptRef(*new CapturePreviewPromptForTesting(WTF::move(title), WTF::move(informativeText), WTF::move(buttonTitles), showsPreview, WTF::move(prompt), WTF::move(session), WTF::move(additionalActions), WTF::move(completionHandler)));
    }

    Vector<Device> cameras() const final { return devicesForTesting(CapturePreviewDeviceType::Camera); }
    Vector<Device> microphones() const final { return devicesForTesting(CapturePreviewDeviceType::Microphone); }
    String selectedCameraID() const final { return [m_prompt selection].selectedDeviceID(CapturePreviewDeviceType::Camera); }
    String selectedMicrophoneID() const final { return [m_prompt selection].selectedDeviceID(CapturePreviewDeviceType::Microphone); }
    unsigned audioLevelUpdateCount() const final { return [m_prompt audioLevelUpdateCount]; }
    unsigned previewLayerCount() const final { return [m_prompt previewLayerCount]; }
    bool hasPreviewLayer() const final { return [m_prompt hasPreviewLayer]; }

    void selectCamera(size_t index) final { [m_prompt selectDeviceOfType:CapturePreviewDeviceType::Camera atIndex:index]; }
    void selectMicrophone(size_t index) final { [m_prompt selectDeviceOfType:CapturePreviewDeviceType::Microphone atIndex:index]; }

    void respond(MediaPermissionPromptResponseForTesting&& response) final
    {
        MediaPermissionPromptResult result;
        if (auto index = response.buttonIndex) {
            result.wasAnswered = true;
            if (!*index)
                result.granted = true;
            else if (*index <= m_additionalActions.size()) {
                result.chosenAdditionalActionIndex = *index - 1;
                result.granted = m_additionalActions[*index - 1].decision == MediaPermissionPromptAdditionalAction::Decision::Allow;
            }
        }
        selectDevice(CapturePreviewDeviceType::Camera, response.cameraPersistentID);
        selectDevice(CapturePreviewDeviceType::Microphone, response.microphonePersistentID);
        finish(WTF::move(result));
    }

    void dismiss() { finish({ }); }

private:
    CapturePreviewPromptForTesting(String&& title, String&& informativeText, Vector<String>&& buttonTitles, bool showsPreview, RetainPtr<WKCapturePreviewPromptForTesting>&& prompt, RefPtr<CapturePreviewSession>&& session, Vector<MediaPermissionPromptAdditionalAction>&& additionalActions, CompletionHandler<void(MediaPermissionPromptResult&&)>&& completionHandler)
        : MediaPermissionPromptForTesting(WTF::move(title), WTF::move(informativeText), WTF::move(buttonTitles), showsPreview)
        , m_prompt(WTF::move(prompt))
        , m_session(WTF::move(session))
        , m_additionalActions(WTF::move(additionalActions))
        , m_completionHandler(WTF::move(completionHandler))
    {
    }

    Vector<Device> devicesForTesting(CapturePreviewDeviceType type) const
    {
        return WTF::map([m_prompt selection].devices(type), [](auto& device) {
            return Device { device.persistentId(), device.label() };
        });
    }

    void selectDevice(CapturePreviewDeviceType type, const String& persistentID)
    {
        if (persistentID.isNull())
            return;
        size_t index = [m_prompt selection].devices(type).findIf([&](auto& device) {
            return device.persistentId() == persistentID;
        });
        if (index != notFound)
            [m_prompt selectDeviceOfType:type atIndex:index];
    }

    void finish(MediaPermissionPromptResult&& result)
    {
        auto completionHandler = std::exchange(m_completionHandler, nullptr);
        if (!completionHandler)
            return;

        if (RefPtr session = m_session) {
            stopPreviewAndReport(m_prompt.get(), *session, WTF::move(result), WTF::move(completionHandler));
            return;
        }

        if (result.granted && showsPreview()) {
            result.selectedAudioDeviceUID = [m_prompt selection].selectedDeviceID(CapturePreviewDeviceType::Microphone);
            result.selectedVideoDeviceUID = [m_prompt selection].selectedDeviceID(CapturePreviewDeviceType::Camera);
        }
        [m_prompt stop];
        completionHandler(WTF::move(result));
    }

    RetainPtr<WKCapturePreviewPromptForTesting> m_prompt;
    RefPtr<CapturePreviewSession> m_session;
    Vector<MediaPermissionPromptAdditionalAction> m_additionalActions;
    CompletionHandler<void(MediaPermissionPromptResult&&)> m_completionHandler;
};

CapturePreviewPromptHandles alertForPermissionForTesting(WebPageProxy& page, CapturePreviewPromptRequest&& request, bool showsPreview, CompletionHandler<void(MediaPermissionPromptResult&&)>&& completionHandler)
{
    PermissionPromptRequest textRequest { .reason = request.reason, .origin = request.origin, .customization = request.customization };
    Vector<String> buttonTitles;
    buttonTitles.append(promptAllowButtonText(textRequest).get());
    for (auto& action : request.customization.additionalActions)
        buttonTitles.append(action.title);
    buttonTitles.append(promptDenyButtonText(textRequest).get());

    // The plain prompt has no device menus.
    Vector<WebCore::CaptureDevice> videoDevices;
    Vector<WebCore::CaptureDevice> audioDevices;
    if (showsPreview) {
        videoDevices = WTF::move(request.eligibleVideoDevices);
        audioDevices = WTF::move(request.eligibleAudioDevices);
    }
    RetainPtr prompt = adoptNS([[WKCapturePreviewPromptForTesting alloc] initWithVideoDevices:WTF::move(videoDevices) audioDevices:WTF::move(audioDevices)]);

    RefPtr<CapturePreviewSession> session;
    if (showsPreview && page.mediaPermissionPromptRunsPreviewForTesting()) {
        session = CapturePreviewSession::create(page.webPageIDInMainFrameProcess());
        connectPreviewToGPUProcess(page, prompt.get(), request.origin, *session);
        [prompt beginPreview];
    }

    Ref testingPrompt = CapturePreviewPromptForTesting::create(promptMessageText(textRequest).get(), promptInformativeText(textRequest).get(), WTF::move(buttonTitles), showsPreview, RetainPtr { prompt }, RefPtr { session }, WTF::move(request.customization.additionalActions), WTF::move(completionHandler));
    page.mediaPermissionPromptHandlerForTesting()(testingPrompt.copyRef());

    return {
        .deviceListUpdater = session ? deviceListUpdater(prompt.get()) : nullptr,
        .promptDismisser = [testingPrompt] {
            testingPrompt->dismiss();
        },
        .previewRestarter = session ? previewRestarter(page, prompt.get(), request.origin, *session) : nullptr,
    };
}

#endif

#if PLATFORM(MAC) && ENABLE(MEDIA_STREAM)

CapturePreviewPromptHandles alertForPermissionWithCapturePreview(WebPageProxy& page, CapturePreviewPromptRequest&& request, CompletionHandler<void(MediaPermissionPromptResult&&)>&& completionHandler)
{
    ASSERT(isMainRunLoop());

    RetainPtr webView = page.cocoaView();
    RetainPtr parentWindow = [webView window];
    if (!parentWindow) {
        completionHandler({ });
        return { };
    }

    PermissionPromptRequest textRequest { .reason = request.reason, .origin = request.origin, .customization = request.customization };
    RetainPtr alertTitle = promptMessageText(textRequest);
    if (!alertTitle) {
        completionHandler({ });
        return { };
    }

    RetainPtr chooser = adoptNS([[WKCaptureDeviceChooser alloc] initWithVideoDevices:WTF::move(request.eligibleVideoDevices) audioDevices:WTF::move(request.eligibleAudioDevices)]);

    RetainPtr sheet = adoptNS([[WKCapturePreviewPromptSheet alloc] initWithMessageText:alertTitle.get() informativeText:promptInformativeText(textRequest).get() accessoryView:[chooser view]]);
    RetainPtr allowButton = [sheet addButtonWithTitle:promptAllowButtonText(textRequest).get() response:NSAlertFirstButtonReturn];

    RetainPtr allowButtons = adoptNS([[NSMutableArray alloc] initWithObjects:allowButton.get(), nil]);
    for (size_t index = 0; index < request.customization.additionalActions.size(); ++index) {
        auto& action = request.customization.additionalActions[index];
        RetainPtr additionalButton = [sheet addButtonWithTitle:action.title.createNSString().get() response:NSAlertThirdButtonReturn + index];
        if (action.decision == MediaPermissionPromptAdditionalAction::Decision::Allow)
            [allowButtons addObject:additionalButton.get()];
    }

    RetainPtr denyButton = [sheet addButtonWithTitle:promptDenyButtonText(textRequest).get() response:NSAlertSecondButtonReturn];
    [denyButton setKeyEquivalent:@"\E"];

    [chooser setAllowButtons:allowButtons.get()];

    Ref session = CapturePreviewSession::create(page.webPageIDInMainFrameProcess());
    connectPreviewToGPUProcess(page, chooser.get(), request.origin, session);

    // Holds the sheet while it is up: it is the target of its own buttons, which do not retain it.
    auto completionBlock = makeBlockPtr([completionHandler = WTF::move(completionHandler), chooser, sheet, session, additionalActions = WTF::move(request.customization.additionalActions)](NSModalResponse returnCode) mutable {
        stopPreviewAndReport(chooser.get(), session, promptResultForAlertResponse(returnCode, additionalActions), WTF::move(completionHandler));
    });

    [sheet beginSheetModalForWindow:parentWindow.get() didPresentHandler:makeBlockPtr([weakChooser = WeakObjCPtr<WKCaptureDeviceChooser>(chooser.get())] {
        [weakChooser.get() beginPreview];
    }).get() completionHandler:completionBlock.get()];

    return {
        .deviceListUpdater = deviceListUpdater(chooser.get()),
        .promptDismisser = [sheet = WTF::move(sheet)] {
            [sheet dismissWithResponse:NSModalResponseAbort];
        },
        .previewRestarter = previewRestarter(page, chooser.get(), request.origin, session),
    };
}

#elif PLATFORM(IOS_FAMILY) && ENABLE(MEDIA_STREAM) && !PLATFORM(APPLETV)

CapturePreviewPromptHandles alertForPermissionWithCapturePreview(WebPageProxy& page, CapturePreviewPromptRequest&& request, CompletionHandler<void(MediaPermissionPromptResult&&)>&& completionHandler)
{
    ASSERT(isMainRunLoop());

    RetainPtr webView = page.cocoaView();
    if (!webView) {
        completionHandler({ });
        return { };
    }

    PermissionPromptRequest textRequest { .reason = request.reason, .origin = request.origin, .customization = request.customization };
    RetainPtr alertTitle = promptMessageText(textRequest);
    if (!alertTitle) {
        completionHandler({ });
        return { };
    }

    RetainPtr presentingViewController = [webView _wk_viewControllerForFullScreenPresentation];
    if (!presentingViewController) {
        completionHandler({ });
        return { };
    }

    RetainPtr controller = adoptNS([[WKCapturePreviewViewController alloc] initWithAvailableSize:[presentingViewController view].safeAreaLayoutGuide.layoutFrame.size title:alertTitle.get() informativeText:promptInformativeText(textRequest).get() allowButtonTitle:promptAllowButtonText(textRequest).get() denyButtonTitle:promptDenyButtonText(textRequest).get() additionalActions:WTF::move(request.customization.additionalActions) videoDevices:WTF::move(request.eligibleVideoDevices) audioDevices:WTF::move(request.eligibleAudioDevices)]);

    Ref session = CapturePreviewSession::create(page.webPageIDInMainFrameProcess());
    connectPreviewToGPUProcess(page, controller.get(), request.origin, session);

    [controller setDecisionHandler:[completionHandler = WTF::move(completionHandler), weakController = WeakObjCPtr<WKCapturePreviewViewController>(controller.get()), session](MediaPermissionPromptResult&& result) mutable {
        RetainPtr controller = weakController.get();
        stopPreviewAndReport(controller.get(), session, WTF::move(result), WTF::move(completionHandler));
        [controller dismissWhenPossible];
    }];

#if PLATFORM(VISION)
    page.dispatchWillPresentModalUI();
#endif
    [presentingViewController presentViewController:controller.get() animated:YES completion:nil];

    return {
        .deviceListUpdater = deviceListUpdater(controller.get()),
        // Weak: a controller that never presented is then freed, and its -dealloc reports that nobody answered.
        .promptDismisser = [weakController = WeakObjCPtr<WKCapturePreviewViewController>(controller.get())] {
            [weakController.get() dismissWithoutAnswer];
        },
        .previewRestarter = previewRestarter(page, controller.get(), request.origin, session),
    };
}

#elif PLATFORM(APPLETV) && ENABLE(MEDIA_STREAM)

// tvOS lacks the colors and the layer hosting the preview prompt uses, so it gets the plain prompt.
CapturePreviewPromptHandles alertForPermissionWithCapturePreview(WebPageProxy& page, CapturePreviewPromptRequest&& request, CompletionHandler<void(MediaPermissionPromptResult&&)>&& completionHandler)
{
    alertForPermission(page, { .reason = request.reason, .origin = request.origin, .customization = WTF::move(request.customization) }, WTF::move(completionHandler));
    return { };
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
