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
#import "WKCapturePreviewViewController.h"

#if PLATFORM(IOS_FAMILY) && ENABLE(MEDIA_STREAM)

#import "LayerHostingContext.h"
#import "Logging.h"
#import <WebCore/LocalizedStrings.h>
#import <algorithm>
#import <cmath>
#import <pal/spi/cocoa/QuartzCoreSPI.h>
#import <wtf/WeakObjCPtr.h>
#import <wtf/cocoa/TypeCastsCocoa.h>

#if USE(EXTENSIONKIT)
#import <BrowserEngineKit/BELayerHierarchyHostingView.h>
#endif

enum class PreviewDeviceType : bool { Camera, Microphone };

constexpr CGFloat previewAspectRatio = 4.0 / 3.0;
constexpr CGFloat contentSpacing = 16;
constexpr CGFloat contentInset = 20;
constexpr CGFloat decisionButtonSpacing = 28;
constexpr CGFloat promptCornerRadius = 16;
constexpr CGFloat previewCornerRadius = 8;
constexpr CGFloat promptTopMargin = 24;
constexpr CGFloat sectionCornerRadius = 12;
constexpr CGFloat sectionInset = 12;
constexpr CGFloat audioLevelMeterHeight = 10;
constexpr CGFloat audioLevelIconSpacing = 10;
constexpr CGFloat previewBadgeInset = 8;
constexpr CGFloat previewBadgeHorizontalPadding = 8;
constexpr CGFloat previewBadgeVerticalPadding = 3;

// A form sheet takes its size from preferredContentSize, so the content has to declare a width for
// the preview and the device menus to be laid out against.
constexpr CGFloat preferredContentWidth = 380;

static CGFloat contentWidth()
{
    return preferredContentWidth - 2 * contentInset;
}

// The camera and microphone each sit in an inset section, so the preview is narrower than the
// content by that inset on both sides.
static CGFloat previewWidth()
{
    return contentWidth() - 2 * sectionInset;
}

// The preview is rendered by the GPU process into a layer hosted here, so this view owns no content
// of its own. The layer class matters: a CALayerHost cannot be added as a sublayer of an ordinary
// layer and still receive a context id.
@interface WKCapturePreviewLayerHostView : UIView
@end

@implementation WKCapturePreviewLayerHostView

+ (Class)layerClass
{
    return [CALayerHost class];
}

@end

// A level meter that is never narrower than it is tall, so it reads as a level at rest rather than
// as a divider. UIProgressView cannot do that: its track is a few points tall with square ends and
// no minimum fill.
@interface WKCapturePreviewAudioLevelView : UIView {
    RetainPtr<UIView> _fill;
    float _level;
}
- (void)setLevel:(float)level;
@end

@implementation WKCapturePreviewAudioLevelView

- (instancetype)init
{
    if (!(self = [super initWithFrame:CGRectZero]))
        return nil;

    _level = 0;
    [self setBackgroundColor:[UIColor secondarySystemFillColor]];
    [self setClipsToBounds:YES];

    _fill = adoptNS([[UIView alloc] init]);
    [_fill setBackgroundColor:[UIColor systemBlueColor]];
    [self addSubview:_fill.get()];

    return self;
}

- (CGSize)intrinsicContentSize
{
    return CGSizeMake(UIViewNoIntrinsicMetric, audioLevelMeterHeight);
}

- (void)setLevel:(float)level
{
    level = std::clamp(level, 0.f, 1.f);
    if (_level == level)
        return;

    _level = level;
    [self setNeedsLayout];
}

- (void)layoutSubviews
{
    [super layoutSubviews];

    CGRect bounds = [self bounds];
    CGFloat height = CGRectGetHeight(bounds);
    [[self layer] setCornerRadius:height / 2];

    [_fill setFrame:CGRectMake(0, 0, std::max(height, std::round(CGRectGetWidth(bounds) * _level)), height)];
    [[_fill layer] setCornerRadius:height / 2];
}

@end

@interface WKCapturePreviewPresentationController : UIPresentationController {
    RetainPtr<UIView> _dimmingView;
}
@end

@implementation WKCapturePreviewPresentationController

- (CGRect)frameOfPresentedViewInContainerView
{
    RetainPtr containerView = [self containerView];
    if (!containerView)
        return CGRectZero;

    CGRect bounds = [containerView bounds];
    CGSize contentSize = [[self presentedViewController] preferredContentSize];
    CGFloat originX = CGRectGetMinX(bounds) + std::round((CGRectGetWidth(bounds) - contentSize.width) / 2);
    CGFloat originY = CGRectGetMinY(bounds) + [containerView safeAreaInsets].top + promptTopMargin;
    return CGRectMake(originX, originY, contentSize.width, contentSize.height);
}

- (void)presentationTransitionWillBegin
{
    [super presentationTransitionWillBegin];

    RetainPtr containerView = [self containerView];
    _dimmingView = adoptNS([[UIView alloc] initWithFrame:[containerView bounds]]);
    [_dimmingView setBackgroundColor:[UIColor colorWithWhite:0 alpha:0.4]];
    [_dimmingView setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
    [_dimmingView setAlpha:0];
    [containerView insertSubview:_dimmingView.get() atIndex:0];

    [[[self presentedViewController] transitionCoordinator] animateAlongsideTransition:[dimmingView = _dimmingView](id<UIViewControllerTransitionCoordinatorContext>) {
        [dimmingView setAlpha:1];
    } completion:nil];
}

- (void)dismissalTransitionWillBegin
{
    [super dismissalTransitionWillBegin];

    [[[self presentedViewController] transitionCoordinator] animateAlongsideTransition:[dimmingView = _dimmingView](id<UIViewControllerTransitionCoordinatorContext>) {
        [dimmingView setAlpha:0];
    } completion:nil];
}

- (void)containerViewWillLayoutSubviews
{
    [super containerViewWillLayoutSubviews];
    [[self presentedView] setFrame:[self frameOfPresentedViewInContainerView]];
}

@end

@implementation WKCapturePreviewViewController {
    RetainPtr<NSString> _alertTitle;
    RetainPtr<NSString> _allowButtonTitle;
    RetainPtr<NSString> _denyButtonTitle;

    RetainPtr<UIStackView> _contentStack;
    RetainPtr<UIView> _previewContainer;
    RetainPtr<UIView> _previewBadge;
    RetainPtr<WKCapturePreviewLayerHostView> _previewLayerHost;
    WebKit::LayerHostingContextID _previewHostingContextID;
#if USE(EXTENSIONKIT)
    RetainPtr<BELayerHierarchyHostingView> _previewHostingView;
#endif
    RetainPtr<UIButton> _allowButton;
    RetainPtr<UIButton> _videoButton;
    RetainPtr<UIButton> _audioButton;
    RetainPtr<WKCapturePreviewAudioLevelView> _audioLevelMeter;

    Vector<WebCore::CaptureDevice> _videoDevices;
    Vector<WebCore::CaptureDevice> _audioDevices;
    size_t _selectedVideoDeviceIndex;
    size_t _selectedAudioDeviceIndex;
    BOOL _requestNeedsVideo;
    BOOL _requestNeedsAudio;

    Function<void(std::optional<WebCore::CaptureDevice>&&, std::optional<WebCore::CaptureDevice>&&)> _selectionChangedHandler;
    CompletionHandler<void(bool)> _decisionHandler;
}

- (instancetype)initWithTitle:(NSString *)alertTitle allowButtonTitle:(NSString *)allowButtonTitle denyButtonTitle:(NSString *)denyButtonTitle videoDevices:(Vector<WebCore::CaptureDevice>&&)videoDevices audioDevices:(Vector<WebCore::CaptureDevice>&&)audioDevices
{
    if (!(self = [super initWithNibName:nil bundle:nil]))
        return nil;

    _alertTitle = alertTitle;
    _allowButtonTitle = allowButtonTitle;
    _denyButtonTitle = denyButtonTitle;
    _videoDevices = WTF::move(videoDevices);
    _audioDevices = WTF::move(audioDevices);
    _requestNeedsVideo = !_videoDevices.isEmpty();
    _requestNeedsAudio = !_audioDevices.isEmpty();
    _selectedVideoDeviceIndex = 0;
    _selectedAudioDeviceIndex = 0;

    self.modalPresentationStyle = UIModalPresentationCustom;
    self.transitioningDelegate = self;
    // A permission request has to be answered, so the only ways out are the two buttons.
    self.modalInPresentation = YES;

    return self;
}

+ (CGSize)previewSize
{
    return CGSizeMake(previewWidth(), std::round(previewWidth() / previewAspectRatio));
}

- (void)dealloc
{
    if (_decisionHandler)
        _decisionHandler(false);
    [super dealloc];
}

- (std::optional<WebCore::CaptureDevice>)_selectedVideoDevice
{
    if (!_requestNeedsVideo || _selectedVideoDeviceIndex >= _videoDevices.size())
        return std::nullopt;
    return _videoDevices[_selectedVideoDeviceIndex];
}

- (std::optional<WebCore::CaptureDevice>)_selectedAudioDevice
{
    if (!_requestNeedsAudio || _selectedAudioDeviceIndex >= _audioDevices.size())
        return std::nullopt;
    return _audioDevices[_selectedAudioDeviceIndex];
}

- (NSString *)selectedVideoDeviceID
{
    auto device = [self _selectedVideoDevice];
    return device ? device->persistentId().createNSString().autorelease() : nil;
}

- (NSString *)selectedAudioDeviceID
{
    auto device = [self _selectedAudioDevice];
    return device ? device->persistentId().createNSString().autorelease() : nil;
}

- (void)setSelectionChangedHandler:(Function<void(std::optional<WebCore::CaptureDevice>&&, std::optional<WebCore::CaptureDevice>&&)>&&)handler
{
    _selectionChangedHandler = WTF::move(handler);
    if ([self isViewLoaded])
        [self _notifySelectionChanged];
}

- (void)setDecisionHandler:(CompletionHandler<void(bool)>&&)handler
{
    _decisionHandler = WTF::move(handler);
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    [[self view] setBackgroundColor:[UIColor systemGroupedBackgroundColor]];
    [[self view] setClipsToBounds:YES];
    [[[self view] layer] setCornerRadius:promptCornerRadius];

    RetainPtr titleLabel = adoptNS([[UILabel alloc] init]);
    [titleLabel setText:_alertTitle.get()];
    [titleLabel setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]];
    [titleLabel setNumberOfLines:0];
    [titleLabel setLineBreakMode:NSLineBreakByWordWrapping];
    // Without this a multi-line label reports a single line as its intrinsic size, so the prompt is
    // measured too short and the title is truncated rather than wrapped.
    [titleLabel setPreferredMaxLayoutWidth:contentWidth()];
    [titleLabel setTextAlignment:NSTextAlignmentCenter];

    _previewContainer = adoptNS([[UIView alloc] init]);
    [_previewContainer setBackgroundColor:[UIColor blackColor]];
    [_previewContainer setClipsToBounds:YES];
    [[_previewContainer layer] setCornerRadius:previewCornerRadius];

    RetainPtr buttonRow = adoptNS([[UIStackView alloc] init]);
    [buttonRow setAxis:UILayoutConstraintAxisHorizontal];
    [buttonRow setDistribution:UIStackViewDistributionFillEqually];
    [buttonRow setSpacing:contentSpacing];

    RetainPtr denyConfiguration = [UIButtonConfiguration grayButtonConfiguration];
    [denyConfiguration setTitle:_denyButtonTitle.get()];
    [denyConfiguration setCornerStyle:UIButtonConfigurationCornerStyleMedium];
    RetainPtr denyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [denyButton setConfiguration:denyConfiguration.get()];
    [denyButton addTarget:self action:@selector(deny) forControlEvents:UIControlEventTouchUpInside];

    RetainPtr allowConfiguration = [UIButtonConfiguration filledButtonConfiguration];
    [allowConfiguration setTitle:_allowButtonTitle.get()];
    [allowConfiguration setCornerStyle:UIButtonConfigurationCornerStyleMedium];
    _allowButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_allowButton setConfiguration:allowConfiguration.get()];
    [_allowButton addTarget:self action:@selector(_allow) forControlEvents:UIControlEventTouchUpInside];

    [buttonRow addArrangedSubview:denyButton.get()];
    [buttonRow addArrangedSubview:_allowButton.get()];

    _contentStack = adoptNS([[UIStackView alloc] init]);
    [_contentStack setAxis:UILayoutConstraintAxisVertical];
    [_contentStack setSpacing:contentSpacing];
    [_contentStack setTranslatesAutoresizingMaskIntoConstraints:NO];
    [_contentStack addArrangedSubview:titleLabel.get()];

    RetainPtr<UIView> lastViewBeforeDecisionButtons = titleLabel;

    if (_requestNeedsVideo) {
        _videoButton = [self _createDeviceButtonForDeviceType:PreviewDeviceType::Camera];

        _previewBadge = adoptNS([[UIView alloc] init]);
        [_previewBadge setBackgroundColor:[UIColor systemBlueColor]];
        [_previewBadge setUserInteractionEnabled:NO];
        [_previewBadge setTranslatesAutoresizingMaskIntoConstraints:NO];

        RetainPtr badgeLabel = adoptNS([[UILabel alloc] init]);
        [badgeLabel setText:WEB_UI_STRING_KEY(@"Preview", "Preview (usermedia)", @"Badge label identifying the live camera preview in the user media prompt").createNSString().get()];
        [badgeLabel setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1]];
        [badgeLabel setTextColor:[UIColor whiteColor]];
        [badgeLabel setTranslatesAutoresizingMaskIntoConstraints:NO];
        [_previewBadge addSubview:badgeLabel.get()];
        [_previewContainer addSubview:_previewBadge.get()];
        [NSLayoutConstraint activateConstraints:@[
            [[badgeLabel topAnchor] constraintEqualToAnchor:[_previewBadge topAnchor] constant:previewBadgeVerticalPadding],
            [[badgeLabel bottomAnchor] constraintEqualToAnchor:[_previewBadge bottomAnchor] constant:-previewBadgeVerticalPadding],
            [[badgeLabel leadingAnchor] constraintEqualToAnchor:[_previewBadge leadingAnchor] constant:previewBadgeHorizontalPadding],
            [[badgeLabel trailingAnchor] constraintEqualToAnchor:[_previewBadge trailingAnchor] constant:-previewBadgeHorizontalPadding],
            [[_previewBadge topAnchor] constraintEqualToAnchor:[_previewContainer topAnchor] constant:previewBadgeInset],
            [[_previewBadge leadingAnchor] constraintEqualToAnchor:[_previewContainer leadingAnchor] constant:previewBadgeInset],
        ]];

        RetainPtr cameraStack = adoptNS([[UIStackView alloc] init]);
        [cameraStack setAxis:UILayoutConstraintAxisVertical];
        [cameraStack setSpacing:sectionInset];
        [cameraStack addArrangedSubview:_previewContainer.get()];
        [cameraStack addArrangedSubview:_videoButton.get()];

        RetainPtr cameraSection = [self _createSectionWithContentView:cameraStack.get()];
        [_contentStack addArrangedSubview:cameraSection.get()];
        lastViewBeforeDecisionButtons = cameraSection;
    }

    if (_requestNeedsAudio) {
        _audioButton = [self _createDeviceButtonForDeviceType:PreviewDeviceType::Microphone];

        RetainPtr microphoneIcon = adoptNS([[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"mic" withConfiguration:[UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleBody]]]);
        [microphoneIcon setTintColor:[UIColor secondaryLabelColor]];
        // Without this the stack has two views it may stretch, and it picks the icon.
        [microphoneIcon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

        _audioLevelMeter = adoptNS([[WKCapturePreviewAudioLevelView alloc] init]);

        RetainPtr meterRow = adoptNS([[UIStackView alloc] init]);
        [meterRow setAxis:UILayoutConstraintAxisHorizontal];
        [meterRow setAlignment:UIStackViewAlignmentCenter];
        [meterRow setSpacing:audioLevelIconSpacing];
        [meterRow addArrangedSubview:microphoneIcon.get()];
        [meterRow addArrangedSubview:_audioLevelMeter.get()];

        RetainPtr microphoneStack = adoptNS([[UIStackView alloc] init]);
        [microphoneStack setAxis:UILayoutConstraintAxisVertical];
        [microphoneStack setSpacing:sectionInset];
        [microphoneStack addArrangedSubview:meterRow.get()];
        [microphoneStack addArrangedSubview:_audioButton.get()];

        RetainPtr microphoneSection = [self _createSectionWithContentView:microphoneStack.get()];
        [_contentStack addArrangedSubview:microphoneSection.get()];
        lastViewBeforeDecisionButtons = microphoneSection;
    }

    [_contentStack addArrangedSubview:buttonRow.get()];
    [_contentStack setCustomSpacing:decisionButtonSpacing afterView:lastViewBeforeDecisionButtons.get()];
    [[self view] addSubview:_contentStack.get()];

    // Pinned to the view rather than its layout margins guide, which would inset the stack by a
    // further unknown amount: contentWidth() has to be the width the content really gets, or the
    // title measures as one line and then truncates, and the preview layer stops filling its
    // container.
    RetainPtr view = [self view];
    NSMutableArray *constraints = [NSMutableArray array];
    [constraints addObjectsFromArray:@[
        [[_contentStack topAnchor] constraintEqualToAnchor:[view topAnchor] constant:contentInset],
        [[_contentStack leadingAnchor] constraintEqualToAnchor:[view leadingAnchor] constant:contentInset],
        [[_contentStack trailingAnchor] constraintEqualToAnchor:[view trailingAnchor] constant:-contentInset],
        [[_contentStack bottomAnchor] constraintLessThanOrEqualToAnchor:[view bottomAnchor] constant:-contentInset],
    ]];
    if (_requestNeedsVideo) {
        // Not required: if the sheet is ever shorter than the content, the preview should give way
        // rather than the title being pushed out of view.
        RetainPtr aspectRatio = [[_previewContainer widthAnchor] constraintEqualToAnchor:[_previewContainer heightAnchor] multiplier:previewAspectRatio];
        [aspectRatio setPriority:UILayoutPriorityRequired - 1];
        [constraints addObject:aspectRatio.get()];
    }
    [NSLayoutConstraint activateConstraints:constraints];

    [self _updatePreferredContentSize];
    [self _notifySelectionChanged];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];

    // Half the measured height rather than a constant, so the ends stay semicircular at any text size.
    [[_previewBadge layer] setCornerRadius:CGRectGetHeight([_previewBadge bounds]) / 2];
}

- (void)_updatePreferredContentSize
{
    // A form sheet is sized from preferredContentSize, and without it the sheet opens at a default
    // size too short for the content: the title clips and the device menus collide.
    CGSize fittingSize = [_contentStack systemLayoutSizeFittingSize:CGSizeMake(contentWidth(), UILayoutFittingCompressedSize.height) withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    self.preferredContentSize = CGSizeMake(preferredContentWidth, fittingSize.height + 2 * contentInset);
}

- (UIPresentationController *)presentationControllerForPresentedViewController:(UIViewController *)presented presentingViewController:(UIViewController *)presenting sourceViewController:(UIViewController *)source
{
    return adoptNS([[WKCapturePreviewPresentationController alloc] initWithPresentedViewController:presented presentingViewController:presenting]).autorelease();
}

- (UIView *)_createSectionWithContentView:(UIView *)contentView
{
    RetainPtr section = adoptNS([[UIView alloc] init]);
    [section setBackgroundColor:[UIColor secondarySystemGroupedBackgroundColor]];
    [[section layer] setCornerRadius:sectionCornerRadius];

    [contentView setTranslatesAutoresizingMaskIntoConstraints:NO];
    [section addSubview:contentView];
    [NSLayoutConstraint activateConstraints:@[
        [[contentView topAnchor] constraintEqualToAnchor:[section topAnchor] constant:sectionInset],
        [[contentView bottomAnchor] constraintEqualToAnchor:[section bottomAnchor] constant:-sectionInset],
        [[contentView leadingAnchor] constraintEqualToAnchor:[section leadingAnchor] constant:sectionInset],
        [[contentView trailingAnchor] constraintEqualToAnchor:[section trailingAnchor] constant:-sectionInset],
    ]];

    return section.autorelease();
}

- (UIButton *)_createDeviceButtonForDeviceType:(PreviewDeviceType)deviceType
{
    RetainPtr button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setShowsMenuAsPrimaryAction:YES];

    RetainPtr configuration = [UIButtonConfiguration grayButtonConfiguration];
    [configuration setImage:[UIImage systemImageNamed:@"chevron.up.chevron.down"]];
    [configuration setImagePlacement:NSDirectionalRectEdgeTrailing];
    [configuration setImagePadding:contentSpacing / 2];
    [configuration setCornerStyle:UIButtonConfigurationCornerStyleMedium];
    [button setConfiguration:configuration.get()];

    [self _updateMenuForButton:button.get() deviceType:deviceType];
    return button.autorelease();
}

- (void)_updateMenuForButton:(UIButton *)button deviceType:(PreviewDeviceType)deviceType
{
    bool isCamera = deviceType == PreviewDeviceType::Camera;
    auto& devices = isCamera ? _videoDevices : _audioDevices;
    size_t selectedIndex = isCamera ? _selectedVideoDeviceIndex : _selectedAudioDeviceIndex;

    // Actions are built per device rather than from labels so that two devices sharing a label still
    // get separate entries, and so the index survives a device list update.
    NSMutableArray<UIAction *> *actions = [NSMutableArray arrayWithCapacity:devices.size()];
    for (size_t index = 0; index < devices.size(); ++index) {
        RetainPtr title = devices[index].label().createNSString();
        RetainPtr action = [UIAction actionWithTitle:title.get() image:nil identifier:nil handler:[weakSelf = WeakObjCPtr<WKCapturePreviewViewController>(self), deviceType, index](UIAction *) {
            RetainPtr strongSelf = weakSelf.get();
            if (!strongSelf)
                return;
            [strongSelf _didSelectDeviceAtIndex:index deviceType:deviceType];
        }];
        [action setState:index == selectedIndex ? UIMenuElementStateOn : UIMenuElementStateOff];
        [actions addObject:action.get()];
    }

    [button setMenu:[UIMenu menuWithTitle:@"" children:actions]];
    if (selectedIndex < devices.size()) {
        RetainPtr configuration = [button configuration];
        [configuration setTitle:devices[selectedIndex].label().createNSString().get()];
        [button setConfiguration:configuration.get()];
    }
}

- (void)_didSelectDeviceAtIndex:(size_t)index deviceType:(PreviewDeviceType)deviceType
{
    bool isCamera = deviceType == PreviewDeviceType::Camera;
    if (isCamera)
        _selectedVideoDeviceIndex = index;
    else
        _selectedAudioDeviceIndex = index;

    [self _updateMenuForButton:isCamera ? _videoButton.get() : _audioButton.get() deviceType:deviceType];
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

    _selectionChangedHandler([self _selectedVideoDevice], [self _selectedAudioDevice]);
}

- (void)setPreviewHostingContext:(const WebCore::HostingContext&)hostingContext gpuProcessIdentifier:(ProcessID)gpuProcessIdentifier
{
    // An unchanged context id means the video source was untouched, as when only the microphone
    // selection moved; rebuilding the view then would flicker the preview for no reason.
    if (_previewLayerHost && hostingContext.contextID == _previewHostingContextID)
        return;

    _previewHostingContextID = hostingContext.contextID;

    // The hosting view is rebuilt per context: it is bound to one context id, so switching devices
    // produces a new one rather than retargeting the old.
    [_previewLayerHost removeFromSuperview];
    _previewLayerHost = nil;
#if USE(EXTENSIONKIT)
    _previewHostingView = nil;
#endif

    if (!hostingContext.contextID)
        return;

    _previewLayerHost = adoptNS([[WKCapturePreviewLayerHostView alloc] init]);
    [_previewLayerHost setUserInteractionEnabled:NO];
    [_previewLayerHost setTranslatesAutoresizingMaskIntoConstraints:NO];
    // Behind the badge rather than on top of it: the hosting view is rebuilt on every camera change,
    // and adding it last would bury the badge from the second camera onwards.
    [_previewContainer insertSubview:_previewLayerHost.get() atIndex:0];
    [NSLayoutConstraint activateConstraints:@[
        [[_previewLayerHost topAnchor] constraintEqualToAnchor:[_previewContainer topAnchor]],
        [[_previewLayerHost bottomAnchor] constraintEqualToAnchor:[_previewContainer bottomAnchor]],
        [[_previewLayerHost leadingAnchor] constraintEqualToAnchor:[_previewContainer leadingAnchor]],
        [[_previewLayerHost trailingAnchor] constraintEqualToAnchor:[_previewContainer trailingAnchor]],
    ]];

#if USE(EXTENSIONKIT)
    _previewHostingView = adoptNS([[BELayerHierarchyHostingView alloc] init]);
    [_previewHostingView setTranslatesAutoresizingMaskIntoConstraints:NO];
    [_previewLayerHost addSubview:_previewHostingView.get()];
    [NSLayoutConstraint activateConstraints:@[
        [[_previewHostingView topAnchor] constraintEqualToAnchor:[_previewLayerHost topAnchor]],
        [[_previewHostingView bottomAnchor] constraintEqualToAnchor:[_previewLayerHost bottomAnchor]],
        [[_previewHostingView leadingAnchor] constraintEqualToAnchor:[_previewLayerHost leadingAnchor]],
        [[_previewHostingView trailingAnchor] constraintEqualToAnchor:[_previewLayerHost trailingAnchor]],
    ]];

    RetainPtr<BELayerHierarchyHandle> layerHandle;
#if ENABLE(MACH_PORT_LAYER_HOSTING)
    UNUSED_PARAM(gpuProcessIdentifier);
    layerHandle = WebKit::LayerHostingContext::createHostingHandle(WTF::MachSendRightAnnotated { hostingContext.sendRightAnnotated });
#else
    layerHandle = WebKit::LayerHostingContext::createHostingHandle(gpuProcessIdentifier, hostingContext.contextID);
#endif
    if (!layerHandle) {
        RELEASE_LOG_ERROR(WebRTC, "CapturePreview unable to create a layer hosting handle for contextID=%u", hostingContext.contextID);
        return;
    }
    [_previewHostingView setHandle:layerHandle.get()];
#else
    UNUSED_PARAM(gpuProcessIdentifier);
    [checked_objc_cast<CALayerHost>([_previewLayerHost layer]) setContextId:hostingContext.contextID];
#endif
}

- (void)updateWithVideoDevices:(Vector<WebCore::CaptureDevice>&&)videoDevices audioDevices:(Vector<WebCore::CaptureDevice>&&)audioDevices
{
    // The selected device is preserved by identity, not by index: an earlier device being unplugged
    // would otherwise silently move the selection to a different camera.
    auto selectedDeviceID = [](const Vector<WebCore::CaptureDevice>& devices, size_t index) {
        return index < devices.size() ? devices[index].persistentId() : String { };
    };
    String selectedVideoDeviceID = selectedDeviceID(_videoDevices, _selectedVideoDeviceIndex);
    String selectedAudioDeviceID = selectedDeviceID(_audioDevices, _selectedAudioDeviceIndex);

    _videoDevices = WTF::move(videoDevices);
    _audioDevices = WTF::move(audioDevices);

    auto indexOfDevice = [](const Vector<WebCore::CaptureDevice>& devices, const String& deviceID) -> size_t {
        if (deviceID.isEmpty())
            return 0;
        size_t index = devices.findIf([&deviceID](auto& device) {
            return device.persistentId() == deviceID;
        });
        return index == notFound ? 0 : index;
    };

    _selectedVideoDeviceIndex = indexOfDevice(_videoDevices, selectedVideoDeviceID);
    _selectedAudioDeviceIndex = indexOfDevice(_audioDevices, selectedAudioDeviceID);

    if (_videoButton)
        [self _updateMenuForButton:_videoButton.get() deviceType:PreviewDeviceType::Camera];
    if (_audioButton)
        [self _updateMenuForButton:_audioButton.get() deviceType:PreviewDeviceType::Microphone];

    // A meter left at its last value after the microphone was unplugged would read as a live signal
    // from a device that is gone.
    if (_audioDevices.isEmpty())
        [self setAudioLevel:0];

    if ([self isViewLoaded]) {
        [self _updateAllowButtonEnablement];
        [self _updatePreferredContentSize];
    }

    [self _notifySelectionChanged];
}

- (void)_updateAllowButtonEnablement
{
    // Unplugging the last device of a requested kind leaves nothing to grant, so Allow must not stay
    // tappable with a stale label.
    bool canStillSatisfyRequest = !(_requestNeedsVideo && _videoDevices.isEmpty()) && !(_requestNeedsAudio && _audioDevices.isEmpty());
    [_allowButton setEnabled:canStillSatisfyRequest];
}

- (void)_allow
{
    if (auto handler = WTF::move(_decisionHandler))
        handler(true);
}

- (void)deny
{
    if (auto handler = WTF::move(_decisionHandler))
        handler(false);
}

- (void)stop
{
    _selectionChangedHandler = nullptr;
    [self setAudioLevel:0];
    [self setPreviewHostingContext:WebCore::HostingContext { } gpuProcessIdentifier:0];
}

@end

#endif // PLATFORM(IOS_FAMILY) && ENABLE(MEDIA_STREAM)
