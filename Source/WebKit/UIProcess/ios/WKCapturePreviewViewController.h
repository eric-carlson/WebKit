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

#pragma once

#if PLATFORM(IOS_FAMILY) && ENABLE(MEDIA_STREAM)

#include <WebCore/CaptureDevice.h>
#include <WebCore/HostingContext.h>
#include <wtf/CompletionHandler.h>
#include <wtf/Function.h>
#include <wtf/ProcessID.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

// Presents the getUserMedia permission prompt with a live capture preview. UIAlertController takes
// no custom content, so unlike macOS this replaces the alert rather than adding an accessory view.
@interface WKCapturePreviewViewController : UIViewController <UIViewControllerTransitioningDelegate>

- (instancetype)initWithTitle:(NSString *)alertTitle allowButtonTitle:(NSString *)allowButtonTitle denyButtonTitle:(NSString *)denyButtonTitle videoDevices:(Vector<WebCore::CaptureDevice>&&)videoDevices audioDevices:(Vector<WebCore::CaptureDevice>&&)audioDevices;

// The GPU process builds its layer at this size, so it has to match the container exactly or the
// hosted layer will not fill it.
+ (CGSize)previewSize;

@property (nonatomic, readonly, copy) NSString *selectedVideoDeviceID;
@property (nonatomic, readonly, copy) NSString *selectedAudioDeviceID;

- (void)setSelectionChangedHandler:(Function<void(std::optional<WebCore::CaptureDevice>&& videoDevice, std::optional<WebCore::CaptureDevice>&& audioDevice)>&&)handler;
- (void)setDecisionHandler:(CompletionHandler<void(bool granted)>&&)handler;
- (void)setPreviewHostingContext:(const WebCore::HostingContext&)hostingContext gpuProcessIdentifier:(ProcessID)gpuProcessIdentifier;
- (void)setAudioLevel:(float)level;
- (void)updateWithVideoDevices:(Vector<WebCore::CaptureDevice>&&)videoDevices audioDevices:(Vector<WebCore::CaptureDevice>&&)audioDevices;
// Denies the request and dismisses, as if the deny button had been activated. Used when the request
// is torn down underneath the prompt.
- (void)deny;
- (void)stop;

@end

#endif // PLATFORM(IOS_FAMILY) && ENABLE(MEDIA_STREAM)
