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

#import "_WKMediaCapturePermissionPromptConfiguration.h"

#if ENABLE(MEDIA_STREAM)

#import "MediaPermissionPromptCustomization.h"
#import <wtf/Vector.h>
#import <wtf/text/WTFString.h>

namespace WebKit {

// Actions past the cap are dropped rather than the call failing, so a prompt is still shown.
MediaPermissionPromptCustomization customizationFromConfiguration(_WKMediaCapturePermissionPromptConfiguration *);

// The index the prompt reported, mapped back to the object the application supplied. nil for the
// built-in allow and deny buttons.
_WKMediaCapturePermissionAction *actionAtIndex(NSArray<_WKMediaCapturePermissionAction *> *, std::optional<size_t>);

}

@interface _WKMediaCapturePermissionPromptResult (Internal)
- (instancetype)_initWithOutcome:(_WKMediaCapturePermissionPromptOutcome)outcome chosenAction:(_WKMediaCapturePermissionAction *)chosenAction cameraDeviceID:(NSString *)cameraDeviceID microphoneDeviceID:(NSString *)microphoneDeviceID;
@end

#endif // ENABLE(MEDIA_STREAM)
