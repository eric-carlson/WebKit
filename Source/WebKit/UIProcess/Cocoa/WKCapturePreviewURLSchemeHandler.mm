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
#import "WKCapturePreviewURLSchemeHandler.h"

#if PLATFORM(MAC) && ENABLE(MEDIA_STREAM)

#import "Logging.h"
#import "WKURLSchemeTask.h"
#import <WebCore/MIMETypeRegistry.h>
#import <wtf/RetainPtr.h>
#import <wtf/text/WTFString.h>

NSString * const WKCapturePreviewScheme = @"webkit-capture-preview";
NSString * const WKCapturePreviewPageURLString = @"webkit-capture-preview:///CapturePreview.html";

static NSString * const capturePreviewResourceDirectory = @"CapturePreview";

@implementation WKCapturePreviewURLSchemeHandler {
    RetainPtr<NSBundle> _bundle;
}

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id <WKURLSchemeTask>)urlSchemeTask
{
    if (!_bundle) {
        _bundle = [NSBundle bundleForClass:NSClassFromString(@"WKWebView")];
        RELEASE_ASSERT(_bundle);
    }

    RetainPtr<NSURL> requestURL = urlSchemeTask.request.URL;

    // Only a flat file name is honored, so a crafted path cannot escape the resource
    // directory. The page is WebKit's own and never requests anything nested.
    RetainPtr requestedName = retainPtr(requestURL.get().lastPathComponent);
    if (![requestedName length] || [requestedName containsString:@".."]) {
        [urlSchemeTask didFailWithError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSURLErrorBadURL userInfo:nil]];
        return;
    }

    RetainPtr fileURL = [_bundle URLForResource:[requestedName stringByDeletingPathExtension] withExtension:retainPtr(requestedName.get().pathExtension).get() subdirectory:capturePreviewResourceDirectory];
    if (!fileURL) {
        RELEASE_LOG_ERROR(WebRTC, "WKCapturePreviewURLSchemeHandler unable to find capture preview resource");
        [urlSchemeTask didFailWithError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSURLErrorFileDoesNotExist userInfo:nil]];
        return;
    }

    NSError *readError = nil;
    RetainPtr fileData = [NSData dataWithContentsOfURL:fileURL.get() options:0 error:&readError];
    if (!fileData) {
        RELEASE_LOG_ERROR(WebRTC, "WKCapturePreviewURLSchemeHandler unable to read capture preview resource");
        [urlSchemeTask didFailWithError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSURLErrorResourceUnavailable userInfo:nil]];
        return;
    }

    RetainPtr mimeType = WebCore::MIMETypeRegistry::mimeTypeForExtension(String(fileURL.get().pathExtension)).createNSString();
    RetainPtr response = adoptNS([[NSURLResponse alloc] initWithURL:requestURL.get() MIMEType:mimeType.get() expectedContentLength:[fileData length] textEncodingName:@"UTF-8"]);

    [urlSchemeTask didReceiveResponse:response.get()];
    [urlSchemeTask didReceiveData:fileData.get()];
    [urlSchemeTask didFinish];
}

- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id <WKURLSchemeTask>)urlSchemeTask
{
}

@end

#endif // PLATFORM(MAC) && ENABLE(MEDIA_STREAM)
