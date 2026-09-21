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

#if PLATFORM(MAC) && ENABLE(MEDIA_STREAM)

#import "Logging.h"
#import "WKCapturePreviewURLSchemeHandler.h"
#import "WKNavigationDelegatePrivate.h"
#import "WKPreferencesPrivate.h"
#import "WKScriptMessage.h"
#import "WKScriptMessageHandler.h"
#import "WKUIDelegatePrivate.h"
#import "WKUserContentController.h"
#import "WKWebViewConfigurationPrivate.h"
#import "WKWebViewInternal.h"
#import "WKWebpagePreferencesPrivate.h"
#import "WKWebsiteDataStore.h"
#import "WebPageProxy.h"
#import "WebProcessPool.h"
#import "WebProcessProxy.h"
#import <WebCore/LocalizedStrings.h>
#import <wtf/BlockPtr.h>
#import <wtf/RetainPtr.h>
#import <wtf/text/WTFString.h>

static const CGFloat preferredPreviewWidth = 320;
static const CGFloat videoGroupHeight = 240 + 8 + 25;
static const CGFloat audioGroupHeight = 6 + 8 + 25;
static const CGFloat groupGap = 12;

static NSString * const capturePreviewMessageHandlerName = @"capturePreview";

static bool deviceListsAreEqual(const Vector<WebCore::CaptureDevice>& a, const Vector<WebCore::CaptureDevice>& b)
{
    if (a.size() != b.size())
        return false;

    for (size_t index = 0; index < a.size(); ++index) {
        if (a[index].persistentId() != b[index].persistentId())
            return false;
    }

    return true;
}

@interface WKCapturePreviewViewController () <WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler>
@end

@implementation WKCapturePreviewViewController {
    RetainPtr<WKWebView> _webView;
    RetainPtr<NSButton> _allowButton;

    Vector<WebCore::CaptureDevice> _videoDevices;
    Vector<WebCore::CaptureDevice> _audioDevices;

    BOOL _pageIsReady;
    BOOL _showsVideo;
    BOOL _showsAudio;

    // Index into _videoDevices / _audioDevices. The page's own deviceIds are salted for its
    // origin and are not comparable to ours, so the slot is the shared identity.
    NSInteger _selectedVideoIndex;
    NSInteger _selectedAudioIndex;
}

- (instancetype)initWithPage:(WebKit::WebPageProxy&)page videoDevices:(Vector<WebCore::CaptureDevice>&&)videoDevices audioDevices:(Vector<WebCore::CaptureDevice>&&)audioDevices
{
    if (!(self = [super init]))
        return nil;

    _videoDevices = WTF::move(videoDevices);
    _audioDevices = WTF::move(audioDevices);
    _showsVideo = !_videoDevices.isEmpty();
    _showsAudio = !_audioDevices.isEmpty();

    CGFloat height = 0;
    if (_showsVideo)
        height += videoGroupHeight;
    if (_showsAudio)
        height += audioGroupHeight + (_showsVideo ? groupGap : 0);

    RetainPtr configuration = adoptNS([[WKWebViewConfiguration alloc] init]);
    [configuration setURLSchemeHandler:adoptNS([[WKCapturePreviewURLSchemeHandler alloc] init]).get() forURLScheme:WKCapturePreviewScheme];
    [configuration setWebsiteDataStore:[WKWebsiteDataStore nonPersistentDataStore]];
    [[configuration userContentController] addScriptMessageHandler:self name:capturePreviewMessageHandlerName];

    // The preview page is served from a custom scheme, not https, so the secure-connection
    // requirement has to be lifted for it. This is WebKit's own page and loads nothing else.
    [[configuration preferences] _setMediaDevicesEnabled:YES];
    [[configuration preferences] _setMediaCaptureRequiresSecureConnection:NO];

    // Without this, getUserMedia waits on Document::whenVisible() and never starts: the
    // preview page inside the sheet is not treated as visible, so the promise never settles.
    // The rule exists to stop background pages capturing, which does not apply to WebKit's
    // own prompt UI.
    [[configuration preferences] _setGetUserMediaRequiresFocus:NO];

    // getUserMedia requires a secure context, which a custom scheme is not by default. This
    // has to happen before the preview's web process launches.
    page.legacyMainFrameProcess().processPool().registerURLSchemeAsSecure(String(WKCapturePreviewScheme));

    _webView = adoptNS([[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, preferredPreviewWidth, height) configuration:configuration.get()]);
    [_webView setUIDelegate:self];
    [_webView setNavigationDelegate:self];
    [_webView _setDrawsBackground:NO];

    // AppKit reports the alert's sheet window as occluded even while it is on screen, which
    // makes PageClientImpl::isViewVisible() false and leaves the page's media suspended, so the
    // preview never paints. Verified necessary: removing this blanks the preview even with the
    // autoplay policy below in place. Occlusion is not a useful signal for a view that exists
    // only for the lifetime of a modal sheet.
    [_webView _setWindowOcclusionDetectionEnabled:NO];

    _selectedVideoIndex = -1;
    _selectedAudioIndex = -1;

    RetainPtr url = adoptNS([[NSURL alloc] initWithString:WKCapturePreviewPageURLString]);
    [_webView loadRequest:[NSURLRequest requestWithURL:url.get()]];

    return self;
}

- (void)dealloc
{
    [self stop];
    [[[_webView configuration] userContentController] removeScriptMessageHandlerForName:capturePreviewMessageHandlerName];
    [super dealloc];
}

- (NSView *)view
{
    return _webView.get();
}

- (RetainPtr<NSArray>)_labelsForDevices:(const Vector<WebCore::CaptureDevice>&)devices
{
    RetainPtr result = adoptNS([[NSMutableArray alloc] initWithCapacity:devices.size()]);
    for (auto& device : devices)
        [result addObject:device.label().createNSString().get()];
    return result;
}

- (void)_sendDevices
{
    if (!_pageIsReady)
        return;

    RetainPtr payload = @{
        @"cameras": [self _labelsForDevices:_videoDevices].get(),
        @"microphones": [self _labelsForDevices:_audioDevices].get(),
        @"previewLabel": WEB_UI_STRING_KEY(@"Preview", "Preview (usermedia)", @"Badge label identifying the live camera preview in the user media prompt").createNSString().get(),
    };

    NSError *error = nil;
    RetainPtr data = [NSJSONSerialization dataWithJSONObject:payload.get() options:0 error:&error];
    if (!data) {
        RELEASE_LOG_ERROR(WebRTC, "WKCapturePreviewViewController unable to serialize device list");
        return;
    }

    RetainPtr json = adoptNS([[NSString alloc] initWithData:data.get() encoding:NSUTF8StringEncoding]);
    // setDevices is async, and evaluateJavaScript cannot serialize the promise it returns, so
    // the completion value is discarded explicitly.
    RetainPtr script = adoptNS([[NSString alloc] initWithFormat:@"window.setDevices(%@); undefined;", json.get()]);
    [_webView evaluateJavaScript:script.get() completionHandler:makeBlockPtr([](id, NSError *error) {
        if (error)
            RELEASE_LOG_ERROR(WebRTC, "WKCapturePreview setDevices failed: %s", [[error description] UTF8String]);
    }).get()];
}

static NSString *persistentUIDAtIndex(const Vector<WebCore::CaptureDevice>& devices, NSInteger index)
{
    if (index < 0 || static_cast<size_t>(index) >= devices.size())
        return nil;

    return devices[index].persistentId().createNSString().autorelease();
}

- (NSString *)selectedVideoDeviceUID
{
    return persistentUIDAtIndex(_videoDevices, _selectedVideoIndex);
}

- (NSString *)selectedAudioDeviceUID
{
    return persistentUIDAtIndex(_audioDevices, _selectedAudioIndex);
}

- (void)setAllowButton:(NSButton *)allowButton
{
    _allowButton = allowButton;
    [self _updateAllowButtonEnablement];
}

- (void)_updateAllowButtonEnablement
{
    // A kind the request asked for that has since lost every device makes the request
    // unsatisfiable, so granting it would hand the page a stream it cannot build.
    bool canStillSatisfyRequest = !(_showsVideo && _videoDevices.isEmpty()) && !(_showsAudio && _audioDevices.isEmpty());
    [_allowButton setEnabled:canStillSatisfyRequest];
}

- (void)updateWithVideoDevices:(Vector<WebCore::CaptureDevice>&&)videoDevices audioDevices:(Vector<WebCore::CaptureDevice>&&)audioDevices
{
    // Capture starting in the preview page can itself provoke a devices-changed notification,
    // so an unchanged list must not be resent: doing so would restart the preview in a loop.
    if (deviceListsAreEqual(videoDevices, _videoDevices) && deviceListsAreEqual(audioDevices, _audioDevices))
        return;

    _videoDevices = WTF::move(videoDevices);
    _audioDevices = WTF::move(audioDevices);

    [self _updateAllowButtonEnablement];

    // The page preserves its running device when that device is still in the new list, so no
    // selection bookkeeping is needed here.
    [self _sendDevices];
}

- (void)stop
{
    if (_webView)
        [_webView evaluateJavaScript:@"window.stopPreview()" completionHandler:nil];
}

#pragma mark WKScriptMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message
{
    RetainPtr body = dynamic_objc_cast<NSDictionary>(message.body);
    if (!body)
        return;

    RetainPtr name = dynamic_objc_cast<NSString>([body objectForKey:@"name"]);

    if ([name isEqualToString:@"ready"]) {
        _pageIsReady = YES;
        [self _sendDevices];
        return;
    }

    if ([name isEqualToString:@"selectionChanged"]) {
        _selectedVideoIndex = [dynamic_objc_cast<NSNumber>([body objectForKey:@"videoIndex"]) integerValue];
        _selectedAudioIndex = [dynamic_objc_cast<NSNumber>([body objectForKey:@"audioIndex"]) integerValue];
        return;
    }

    if ([name isEqualToString:@"previewFailed"]) {
        RetainPtr kind = dynamic_objc_cast<NSString>([body objectForKey:@"kind"]);
        RetainPtr reason = dynamic_objc_cast<NSString>([body objectForKey:@"message"]);
        RELEASE_LOG_ERROR(WebRTC, "WKCapturePreview preview failed for %s: %s", [kind UTF8String], [reason UTF8String]);
        return;
    }

}

#pragma mark WKUIDelegate

- (void)webView:(WKWebView *)webView requestMediaCapturePermissionForOrigin:(WKSecurityOrigin *)origin initiatedByFrame:(WKFrameInfo *)frame type:(WKMediaCaptureType)type decisionHandler:(void (^)(WKPermissionDecision))decisionHandler
{
    // Granting here is what keeps the preview from recursing into another permission prompt.
    // The page is WebKit's own and cannot be navigated elsewhere.
    decisionHandler(WKPermissionDecisionGrant);
}

#pragma mark WKNavigationDelegate

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction preferences:(WKWebpagePreferences *)preferences decisionHandler:(void (^)(WKNavigationActionPolicy, WKWebpagePreferences *))decisionHandler
{
    RetainPtr<NSURL> requestURL = navigationAction.request.URL;
    bool isPreviewPage = [[requestURL absoluteString] isEqualToString:WKCapturePreviewPageURLString];

    // The preview element is muted and driven by a MediaStream, but without this the element
    // is held back by the page-consent autoplay restriction and never starts, leaving a live
    // stream painting nothing.
    [preferences _setAutoplayPolicy:_WKWebsiteAutoplayPolicyAllow];

    decisionHandler(isPreviewPage ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel, preferences);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    RetainPtr window = [_webView window];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    RELEASE_LOG_ERROR(WebRTC, "WKCapturePreview didFailNavigation: %s", [[error description] UTF8String]);
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    RELEASE_LOG_ERROR(WebRTC, "WKCapturePreview didFailProvisionalNavigation: %s", [[error description] UTF8String]);
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView
{
    RELEASE_LOG_ERROR(WebRTC, "WKCapturePreview web content process terminated");
}

@end

#endif // PLATFORM(MAC) && ENABLE(MEDIA_STREAM)
