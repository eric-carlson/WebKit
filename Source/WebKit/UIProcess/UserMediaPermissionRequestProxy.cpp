/*
 * Copyright (C) 2014 Igalia S.L.
 * Copyright (C) 2016-2022 Apple Inc. All rights reserved.
 *
 *  This library is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU Lesser General Public
 *  License as published by the Free Software Foundation; either
 *  version 2 of the License, or (at your option) any later version.
 *
 *  This library is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *  Lesser General Public License for more details.
 *
 *  You should have received a copy of the GNU Lesser General Public
 *  License along with this library; if not, write to the Free Software
 *  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
 */

#include "config.h"
#include "UserMediaPermissionRequestProxy.h"

#include "APIUIClient.h"
#include "MediaPermissionUtilities.h"
#include "UserMediaPermissionRequestManagerProxy.h"
#include "UserMediaProcessManager.h"
#include "WebPageProxy.h"
#include "WebPreferences.h"
#include <WebCore/CaptureDeviceManager.h>
#include <WebCore/RealtimeMediaSourceCenter.h>
#include <WebCore/SecurityOrigin.h>
#include <WebCore/SecurityOriginData.h>
#include <algorithm>
#include <wtf/text/StringHash.h>

namespace WebKit {
using namespace WebCore;

#if !PLATFORM(COCOA)
Ref<UserMediaPermissionRequestProxy> UserMediaPermissionRequestProxy::create(UserMediaPermissionRequestManagerProxy& manager, std::optional<WebCore::UserMediaRequestIdentifier> userMediaID, WebCore::FrameIdentifier mainFrameID, FrameInfoData&& frameInfo, Ref<WebCore::SecurityOrigin>&& userMediaDocumentOrigin, Ref<WebCore::SecurityOrigin>&& topLevelDocumentOrigin, Vector<WebCore::CaptureDevice>&& audioDevices, Vector<WebCore::CaptureDevice>&& videoDevices, WebCore::MediaStreamRequest&& request, CompletionHandler<void(bool)>&& decisionCompletionHandler)
{
    return adoptRef(*new UserMediaPermissionRequestProxy(manager, userMediaID, mainFrameID, WTF::move(frameInfo), WTF::move(userMediaDocumentOrigin), WTF::move(topLevelDocumentOrigin), WTF::move(audioDevices), WTF::move(videoDevices), WTF::move(request), WTF::move(decisionCompletionHandler)));
}
#endif

UserMediaPermissionRequestProxy::UserMediaPermissionRequestProxy(UserMediaPermissionRequestManagerProxy& manager, std::optional<UserMediaRequestIdentifier> userMediaID, FrameIdentifier mainFrameID, FrameInfoData&& frameInfo, Ref<WebCore::SecurityOrigin>&& userMediaDocumentOrigin, Ref<WebCore::SecurityOrigin>&& topLevelDocumentOrigin, Vector<WebCore::CaptureDevice>&& audioDevices, Vector<WebCore::CaptureDevice>&& videoDevices, WebCore::MediaStreamRequest&& request, CompletionHandler<void(bool)>&& decisionCompletionHandler)
    : m_manager(manager)
    , m_userMediaID(userMediaID)
    , m_mainFrameID(mainFrameID)
    , m_frameInfo(WTF::move(frameInfo))
    , m_userMediaDocumentSecurityOrigin(WTF::move(userMediaDocumentOrigin))
    , m_topLevelDocumentSecurityOrigin(WTF::move(topLevelDocumentOrigin))
    , m_eligibleVideoDevices(WTF::move(videoDevices))
    , m_eligibleAudioDevices(WTF::move(audioDevices))
    , m_request(WTF::move(request))
    , m_decisionCompletionHandler(WTF::move(decisionCompletionHandler))
{
}

UserMediaPermissionRequestProxy::~UserMediaPermissionRequestProxy()
{
    if (m_decisionCompletionHandler)
        m_decisionCompletionHandler(false);
}

UserMediaPermissionRequestManagerProxy* UserMediaPermissionRequestProxy::manager() const
{
    return m_manager.get();
}

bool UserMediaPermissionRequestProxy::willUseEchoCancellation() const
{
#if ENABLE(MEDIA_STREAM)
    return requiresAudioCapture() && m_request.audioConstraints.willUseEchoCancellation();
#else
    return false;
#endif
}

#if ENABLE(MEDIA_STREAM)
template<typename Predicate>
static void moveDeviceToFront(std::span<CaptureDevice> devices, NOESCAPE const Predicate& matches)
{
    auto iterator = std::ranges::find_if(devices, matches);
    if (iterator != devices.end())
        std::rotate(devices.begin(), iterator, iterator + 1);
}

static auto hasPersistentID(const String& deviceID)
{
    return [&deviceID](const CaptureDevice& device) {
        return !deviceID.isEmpty() && device.persistentId() == deviceID;
    };
}
#endif

void UserMediaPermissionRequestProxy::applyDeviceSelection(const String& audioDeviceUID, const String& videoDeviceUID)
{
#if ENABLE(MEDIA_STREAM)
    // Remembered because the grant path revalidates constraints, which rebuilds the eligible lists
    // in fitness order and would otherwise discard this choice.
    m_selectedDeviceUIDs = { audioDeviceUID, videoDeviceUID };
    m_deviceSelectionWasExplicit = true;

    // Either device may have been unplugged since it was chosen; the grant's revalidation then falls back
    // to the best remaining match.
    moveDeviceToFront(m_eligibleAudioDevices.mutableSpan(), hasPersistentID(audioDeviceUID));
    moveDeviceToFront(m_eligibleVideoDevices.mutableSpan(), hasPersistentID(videoDeviceUID));
#else
    UNUSED_PARAM(audioDeviceUID);
    UNUSED_PARAM(videoDeviceUID);
#endif
}

void UserMediaPermissionRequestProxy::allow(const String& audioDeviceUID, const String& videoDeviceUID)
{
    applyDeviceSelection(audioDeviceUID, videoDeviceUID);
    allow();
}

#if ENABLE(MEDIA_STREAM)
void UserMediaPermissionRequestProxy::preferDevices(const DeviceUIDs& deviceUIDs, BestMatchingDeviceCounts bestMatchingCounts)
{
    m_selectedDeviceUIDs = deviceUIDs;
    m_deviceSelectionWasExplicit = false;

    // A previous choice only wins among the best matches, which the eligible lists hold first.
    moveDeviceToFront(m_eligibleAudioDevices.mutableSpan().first(std::min<size_t>(bestMatchingCounts.audio, m_eligibleAudioDevices.size())), hasPersistentID(deviceUIDs.audioDeviceUID));
    moveDeviceToFront(m_eligibleVideoDevices.mutableSpan().first(std::min<size_t>(bestMatchingCounts.video, m_eligibleVideoDevices.size())), hasPersistentID(deviceUIDs.videoDeviceUID));
}

void UserMediaPermissionRequestProxy::reapplyDeviceSelection(BestMatchingDeviceCounts bestMatchingCounts)
{
    // A device chosen in the prompt wins outright; one carried over from an earlier grant must still be
    // among the best matches.
    if (!m_deviceSelectionWasExplicit) {
        preferDevices(m_selectedDeviceUIDs, bestMatchingCounts);
        return;
    }

    moveDeviceToFront(m_eligibleAudioDevices.mutableSpan(), hasPersistentID(m_selectedDeviceUIDs.audioDeviceUID));
    moveDeviceToFront(m_eligibleVideoDevices.mutableSpan(), hasPersistentID(m_selectedDeviceUIDs.videoDeviceUID));
}
#endif

void UserMediaPermissionRequestProxy::allow()
{
    RefPtr manager = m_manager.get();
    ASSERT(manager);
    if (!manager)
        return;

    manager->delegateDecisionEnded(*this);

#if PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)
    // Capture waits until the preview has released the devices, which the prompt's completion reports.
    if (auto dismissPrompt = std::exchange(m_previewPromptDismisser, nullptr)) {
        m_grantWhenPromptCloses = true;
        dismissPrompt();
        return;
    }
#endif

    manager->grantRequest(*this);
    invalidate();
}

void UserMediaPermissionRequestProxy::deny(UserMediaAccessDenialReason reason)
{
    RefPtr manager = m_manager.get();
    if (!manager)
        return;

    manager->delegateDecisionEnded(*this);
    manager->denyRequest(*this, reason);
    invalidate();
}

void UserMediaPermissionRequestProxy::invalidate()
{
    if (RefPtr manager = std::exchange(m_manager, nullptr))
        manager->delegateDecisionEnded(*this);

#if PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)
    // Navigation, stopCapture() and clearCachedState() all reach here. The prompt must not outlive the
    // request.
    m_previewDeviceListUpdater = nullptr;
    m_previewRestarter = nullptr;
    if (auto dismissPrompt = std::exchange(m_previewPromptDismisser, nullptr))
        dismissPrompt();
#endif

    if (m_decisionCompletionHandler)
        m_decisionCompletionHandler(false);
}

bool UserMediaPermissionRequestProxy::isPending() const
{
    return !!m_manager;
}

Vector<String> UserMediaPermissionRequestProxy::videoDeviceUIDs() const
{
    return WTF::map(m_eligibleVideoDevices, [] (auto& device) {
        return device.persistentId();
    });
}

Vector<String> UserMediaPermissionRequestProxy::audioDeviceUIDs() const
{
    return WTF::map(m_eligibleAudioDevices, [] (auto& device) {
        return device.persistentId();
    });
}

String convertEnumerationToString(UserMediaPermissionRequestProxy::UserMediaAccessDenialReason enumerationValue)
{
    static const std::array<NeverDestroyed<String>, 7> values = {
        MAKE_STATIC_STRING_IMPL("NoConstraints"),
        MAKE_STATIC_STRING_IMPL("UserMediaDisabled"),
        MAKE_STATIC_STRING_IMPL("NoCaptureDevices"),
        MAKE_STATIC_STRING_IMPL("InvalidConstraint"),
        MAKE_STATIC_STRING_IMPL("HardwareError"),
        MAKE_STATIC_STRING_IMPL("PermissionDenied"),
        MAKE_STATIC_STRING_IMPL("OtherFailure"),
    };
    static_assert(static_cast<size_t>(UserMediaPermissionRequestProxy::UserMediaAccessDenialReason::NoConstraints) == 0, "UserMediaPermissionRequestProxy::UserMediaAccessDenialReason::NoConstraints is not 0 as expected");
    static_assert(static_cast<size_t>(UserMediaPermissionRequestProxy::UserMediaAccessDenialReason::UserMediaDisabled) == 1, "UserMediaPermissionRequestProxy::UserMediaAccessDenialReason::UserMediaDisabled is not 1 as expected");
    static_assert(static_cast<size_t>(UserMediaPermissionRequestProxy::UserMediaAccessDenialReason::NoCaptureDevices) == 2, "UserMediaPermissionRequestProxy::UserMediaAccessDenialReason::NoCaptureDevices is not 2 as expected");
    static_assert(static_cast<size_t>(UserMediaPermissionRequestProxy::UserMediaAccessDenialReason::InvalidConstraint) == 3, "UserMediaPermissionRequestProxy::UserMediaAccessDenialReason::InvalidConstraint is not 3 as expected");
    static_assert(static_cast<size_t>(UserMediaPermissionRequestProxy::UserMediaAccessDenialReason::HardwareError) == 4, "UserMediaPermissionRequestProxy::UserMediaAccessDenialReason::HardwareError is not 4 as expected");
    static_assert(static_cast<size_t>(UserMediaPermissionRequestProxy::UserMediaAccessDenialReason::PermissionDenied) == 5, "UserMediaPermissionRequestProxy::UserMediaAccessDenialReason::PermissionDenied is not 5 as expected");
    static_assert(static_cast<size_t>(UserMediaPermissionRequestProxy::UserMediaAccessDenialReason::OtherFailure) == 6, "UserMediaPermissionRequestProxy::UserMediaAccessDenialReason::OtherFailure is not 6 as expected");
    return values[static_cast<size_t>(enumerationValue)];
}

void UserMediaPermissionRequestProxy::promptForGetDisplayMedia(UserMediaDisplayCapturePromptType promptType)
{
#if ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
    RefPtr manager = m_manager.get();
    ASSERT(manager && canRequestDisplayCapturePermission() && promptType == UserMediaDisplayCapturePromptType::UserChoose);
    if (!manager || !manager->page() || !canRequestDisplayCapturePermission() || promptType != UserMediaDisplayCapturePromptType::UserChoose) {
        deny(UserMediaAccessDenialReason::PermissionDenied);
        return;
    }

    alertForPermission(*protect(manager->page()), MediaPermissionReason::ScreenCapture, topLevelDocumentSecurityOrigin().data(), [this, protectedThis = Ref { *this }](bool granted) {
        if (!granted)
            deny(UserMediaAccessDenialReason::PermissionDenied);
        else
            allow();
    });
#endif
}

void UserMediaPermissionRequestProxy::promptForGetUserMedia()
{
#if ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
    // Not PermissionDenied, which would be cached as the user's answer.
    if (m_isShowingPrompt) {
        deny(UserMediaAccessDenialReason::OtherFailure);
        return;
    }

    showCapturePrompt({ }, [this, protectedThis = Ref { *this }](MediaPermissionPromptResult&& result) {
        // Only a refusal the user made is cached; a prompt that closed or never showed is not one.
        if (!result.granted)
            deny(result.wasAnswered ? UserMediaAccessDenialReason::PermissionDenied : UserMediaAccessDenialReason::OtherFailure);
        else
            allow(result.selectedAudioDeviceUID, result.selectedVideoDeviceUID);
    });
#endif
}

#if PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)

void UserMediaPermissionRequestProxy::showCapturePromptWithoutDeciding(MediaPermissionPromptCustomization&& customization, PromptResultHandler&& completionHandler)
{
    showCapturePrompt(WTF::move(customization), [this, protectedThis = Ref { *this }, completionHandler = WTF::move(completionHandler)](MediaPermissionPromptResult&& result) mutable {
        // Recorded but not granted: the application decides, and a grant that follows has to capture
        // from the device the user picked here rather than element 0 of the eligible lists.
        if (result.granted)
            applyDeviceSelection(result.selectedAudioDeviceUID, result.selectedVideoDeviceUID);

        completionHandler(WTF::move(result));
    });
}

void UserMediaPermissionRequestProxy::showCapturePrompt(MediaPermissionPromptCustomization&& customization, PromptResultHandler&& completionHandler)
{
    RefPtr manager = m_manager;
    if (!manager || !manager->page())
        return completionHandler({ });

    MediaPermissionReason reason = MediaPermissionReason::Camera;
    if (m_kind == Kind::SpeechRecognition)
        reason = MediaPermissionReason::SpeechRecognition;
    else if (requiresAudioCapture())
        reason = requiresVideoCapture() ? MediaPermissionReason::CameraAndMicrophone : MediaPermissionReason::Microphone;

    Ref page = *manager->page();

    // A second prompt would take over the first one's handles, which the first then clears on finishing.
    if (m_isShowingPrompt) {
        RELEASE_LOG_ERROR(WebRTC, "UserMediaPermissionRequestProxy::showCapturePrompt: a prompt is already showing for this request");
        return completionHandler({ });
    }
    m_isShowingPrompt = true;

    bool showsPreview = protect(page->preferences())->captureDevicePreviewInPromptEnabled();
    bool isAnsweredByTest = !!page->mediaPermissionPromptHandlerForTesting();
    // Otherwise device changes only reach the UI process once a page listens for devicechange, and the
    // device menus would keep offering an unplugged device.
    if (showsPreview)
        UserMediaProcessManager::singleton().beginMonitoringCaptureDevices();
    if (showsPreview || isAnsweredByTest) {
        CapturePreviewPromptRequest request {
            .reason = reason,
            .origin = topLevelDocumentSecurityOrigin().data(),
            .eligibleVideoDevices = m_eligibleVideoDevices,
            .eligibleAudioDevices = m_eligibleAudioDevices,
            .customization = WTF::move(customization),
        };
        CompletionHandler<void(MediaPermissionPromptResult&&)> promptCompletionHandler = [this, protectedThis = Ref { *this }, completionHandler = WTF::move(completionHandler)](MediaPermissionPromptResult&& result) mutable {
            m_isShowingPrompt = false;
            m_previewDeviceListUpdater = nullptr;
            m_previewPromptDismisser = nullptr;
            m_previewRestarter = nullptr;
            completionHandler(WTF::move(result));

            if (std::exchange(m_grantWhenPromptCloses, false)) {
                if (RefPtr manager = m_manager)
                    manager->grantRequest(*this);
                invalidate();
            }
        };
        auto handles = isAnsweredByTest ? alertForPermissionForTesting(page, WTF::move(request), showsPreview, WTF::move(promptCompletionHandler)) : alertForPermissionWithCapturePreview(page, WTF::move(request), WTF::move(promptCompletionHandler));
        if (!m_isShowingPrompt)
            return;
        m_previewDeviceListUpdater = WTF::move(handles.deviceListUpdater);
        m_previewPromptDismisser = WTF::move(handles.promptDismisser);
        m_previewRestarter = WTF::move(handles.previewRestarter);
        return;
    }

    // No preview means no device menus, so a grant from here uses whatever the eligible lists already
    // order first.
    alertForPermission(page, { .reason = reason, .origin = topLevelDocumentSecurityOrigin().data(), .customization = WTF::move(customization) }, [this, protectedThis = Ref { *this }, completionHandler = WTF::move(completionHandler)](MediaPermissionPromptResult&& result) mutable {
        m_isShowingPrompt = false;
        completionHandler(WTF::move(result));
    });
}

void UserMediaPermissionRequestProxy::gpuProcessExited()
{
    if (m_previewRestarter)
        m_previewRestarter();
}

void UserMediaPermissionRequestProxy::devicesChanged()
{
    if (!m_previewDeviceListUpdater)
        return;

    // The changed device set goes back through constraint validation rather than being used
    // directly: a device attached while the prompt is up still has to satisfy the request's
    // `exact` constraints before it will be offered.
    RealtimeMediaSourceCenter::singleton().validateRequestConstraints([protectedThis = Ref { *this }](auto&& validDevices) mutable {
        if (!protectedThis->m_previewDeviceListUpdater)
            return;

        if (!validDevices) {
            // The application may still grant, so the request keeps the devices it was made with.
            protectedThis->m_previewDeviceListUpdater({ }, { });
            return;
        }

        protectedThis->m_eligibleVideoDevices = WTF::move(validDevices->videoDevices);
        protectedThis->m_eligibleAudioDevices = WTF::move(validDevices->audioDevices);
        protectedThis->m_previewDeviceListUpdater(Vector<WebCore::CaptureDevice> { protectedThis->m_eligibleVideoDevices }, Vector<WebCore::CaptureDevice> { protectedThis->m_eligibleAudioDevices });
    }, m_request, MediaDeviceHashSalts { m_deviceIdentifierHashSalts });
}
#endif

void UserMediaPermissionRequestProxy::doDefaultAction()
{
#if ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
    if (requiresDisplayCapture())
        promptForGetDisplayMedia(UserMediaDisplayCapturePromptType::UserChoose);
    else
        promptForGetUserMedia();
#else
    deny();
#endif
}

bool UserMediaPermissionRequestProxy::canRequestDisplayCapturePermission()
{
#if ENABLE(MEDIA_STREAM) && (PLATFORM(IOS) || PLATFORM(VISION))
    return true;
#else
    return false;
#endif
}

} // namespace WebKit
