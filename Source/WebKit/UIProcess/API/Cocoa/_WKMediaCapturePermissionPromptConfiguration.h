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

#import <Foundation/Foundation.h>
#import <WebKit/WKFoundation.h>

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

/*! @abstract Whether activating an additional action grants or denies the request.
 @discussion An action declared as Allow behaves like the built-in allow button: the page is reported
 the device the user selected in the prompt. An action declared as Deny behaves like the built-in deny
 button.
 */
typedef NS_ENUM(NSInteger, _WKMediaCapturePermissionActionDecision) {
    _WKMediaCapturePermissionActionDecisionDeny,
    _WKMediaCapturePermissionActionDecisionAllow,
} WK_API_AVAILABLE(macos(WK_MAC_TBA), ios(WK_IOS_TBA));

/*! @abstract How the prompt was dismissed. */
typedef NS_ENUM(NSInteger, _WKMediaCapturePermissionPromptOutcome) {
    _WKMediaCapturePermissionPromptOutcomeAllowed,
    _WKMediaCapturePermissionPromptOutcomeDenied,
} WK_API_AVAILABLE(macos(WK_MAC_TBA), ios(WK_IOS_TBA));

/*! @abstract The number of additional actions WebKit will render. Any beyond this are ignored. */
WK_EXTERN const NSUInteger _WKMediaCapturePermissionPromptMaximumAdditionalActions WK_API_AVAILABLE(macos(WK_MAC_TBA), ios(WK_IOS_TBA));

/*! @abstract An additional button in WebKit's capture permission prompt.
 @discussion The action carries no handler of its own. WebKit renders its title, dismisses the prompt
 when it is activated, and reports it as the result's chosenAction.
 */
WK_CLASS_AVAILABLE(macos(WK_MAC_TBA), ios(WK_IOS_TBA))
@interface _WKMediaCapturePermissionAction : NSObject

+ (instancetype)actionWithTitle:(NSString *)title decision:(_WKMediaCapturePermissionActionDecision)decision;

@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly) _WKMediaCapturePermissionActionDecision decision;

@end

/*! @abstract Adjustments to WebKit's capture permission prompt.
 @discussion WebKit continues to own the prompt: the device menus, the live preview, the layout, and
 recomputing the device list when a device is attached or removed while the prompt is visible. Leave a
 string unset to keep the text WebKit would have used, which the application then does not have to
 localize.
 */
WK_CLASS_AVAILABLE(macos(WK_MAC_TBA), ios(WK_IOS_TBA))
@interface _WKMediaCapturePermissionPromptConfiguration : NSObject

@property (nonatomic, copy, nullable) NSString *messageText;
@property (nonatomic, copy, nullable) NSString *allowButtonTitle;
@property (nonatomic, copy, nullable) NSString *denyButtonTitle;

/*! @abstract Buttons to add after the allow and deny buttons. Empty by default. */
@property (nonatomic, copy) NSArray<_WKMediaCapturePermissionAction *> *additionalActions;

@end

/*! @abstract What the user did with WebKit's capture permission prompt.
 @discussion chosenAction is nil when the user activated the built-in allow or deny button, and is
 otherwise the object from additionalActions that was activated. Actions are reported by identity, so
 compare the object rather than its title, which would break under localization.

 cameraDeviceID and microphoneDeviceID name the devices the user selected, for an application that
 wants to show that choice in its own UI. They are the platform's persistent device identifiers, not
 the hashed values a page sees in MediaDeviceInfo.deviceId, so they cannot be correlated with
 anything the page reports. Both are nil unless the outcome allows capture of that kind.
 */
WK_CLASS_AVAILABLE(macos(WK_MAC_TBA), ios(WK_IOS_TBA))
@interface _WKMediaCapturePermissionPromptResult : NSObject

@property (nonatomic, readonly) _WKMediaCapturePermissionPromptOutcome outcome;
@property (nonatomic, readonly, nullable) _WKMediaCapturePermissionAction *chosenAction;
@property (nonatomic, readonly, copy, nullable) NSString *cameraDeviceID;
@property (nonatomic, readonly, copy, nullable) NSString *microphoneDeviceID;

@end

NS_HEADER_AUDIT_END(nullability, sendability)
