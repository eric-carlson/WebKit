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

#include "config.h"
#include "CapturePreviewManager.h"

#if ENABLE(MEDIA_STREAM)

#include "LayerHostingContext.h"
#include "Logging.h"
#include <WebCore/CAAudioStreamDescription.h>
#include <WebCore/MediaDeviceHashSalts.h>
#include <WebCore/RealtimeMediaSourceCenter.h>
#include <WebCore/VideoFrame.h>
#include <WebCore/WebAudioBufferList.h>
#include <cmath>
#include <wtf/TZoneMallocInlines.h>

#if PLATFORM(IOS_FAMILY) && USE(AUDIO_SESSION)
#include "GPUProcess.h"
#include "RemoteAudioSessionProxyManager.h"
#include <WebCore/AVAudioSessionCaptureDeviceManager.h>
#endif

namespace WebKit {
WTF_MAKE_TZONE_ALLOCATED_IMPL(CapturePreviewManager);

CapturePreviewManager::CapturePreviewManager() = default;

CapturePreviewManager::~CapturePreviewManager()
{
    stop();
}

RefPtr<WebCore::RealtimeMediaSource> CapturePreviewManager::createSource(const WebCore::CaptureDevice& device, WebCore::PageIdentifier pageIdentifier)
{
    // Hashed device ids are never exposed from a preview, so the salts can be empty.
    WebCore::MediaDeviceHashSalts hashSalts;

    auto& center = WebCore::RealtimeMediaSourceCenter::singleton();
    auto sourceOrError = device.type() == WebCore::CaptureDevice::DeviceType::Microphone
        ? center.audioCaptureFactory().createAudioCaptureSource(device, WTF::move(hashSalts), nullptr, pageIdentifier)
        : center.videoCaptureFactory().createVideoCaptureSource(device, WTF::move(hashSalts), nullptr, pageIdentifier);

    if (!sourceOrError) {
        RELEASE_LOG_ERROR(WebRTC, "CapturePreviewManager unable to create %s preview source for '%s' (%s), denialReason=%d, %s",
            device.type() == WebCore::CaptureDevice::DeviceType::Microphone ? "microphone" : "camera",
            device.label().utf8().legacyCStringPointer(),
            device.persistentId().utf8().legacyCStringPointer(),
            static_cast<int>(sourceOrError.error.denialReason),
            sourceOrError.error.errorMessage.utf8().legacyCStringPointer());
        return nullptr;
    }

    return RefPtr { sourceOrError.source().ptr() };
}

void CapturePreviewManager::start(std::optional<WebCore::CaptureDevice>&& videoDevice, std::optional<WebCore::CaptureDevice>&& audioDevice, WebCore::PageIdentifier pageIdentifier, WebCore::IntSize previewSize, StartCallback&& callback)
{
    // Each kind is restarted only when its own device changed. Restarting both would stall the
    // camera every time the microphone selection moved.
    String videoDeviceID = videoDevice ? videoDevice->persistentId() : String { };
    String audioDeviceID = audioDevice ? audioDevice->persistentId() : String { };

    if (audioDeviceID != m_audioDeviceID) {
        stopAudio();
        if (audioDevice)
            startAudio(*audioDevice, pageIdentifier);
    }

    if (videoDeviceID == m_videoDeviceID) {
        callback(m_hostingContext);
        return;
    }

    stopVideo();

    if (!videoDevice) {
        callback({ });
        return;
    }

    startVideo(*videoDevice, pageIdentifier, previewSize, WTF::move(callback));
}

void CapturePreviewManager::startAudio(const WebCore::CaptureDevice& device, WebCore::PageIdentifier pageIdentifier)
{
    // Recorded before the source exists rather than after it starts, so that a selection arriving
    // while the audio session is still being configured replaces this one instead of adding to it.
    m_audioDeviceID = device.persistentId();

#if PLATFORM(IOS_FAMILY) && USE(AUDIO_SESSION)
    // The audio session has to settle before the unit starts. A capture unit reads the category back
    // from the audio session as it starts and, if it still reads as the old one, suspends itself and
    // reports no failure at all, so the preview is silent with only a log line to say why.
    prepareAudioSession([protectedThis = Ref { *this }, device, pageIdentifier] {
        if (protectedThis->m_audioDeviceID != device.persistentId())
            return;
        protectedThis->startAudioSource(device, pageIdentifier);
    });
#else
    startAudioSource(device, pageIdentifier);
#endif
}

void CapturePreviewManager::startAudioSource(const WebCore::CaptureDevice& device, WebCore::PageIdentifier pageIdentifier)
{
    m_audioSource = createSource(device, pageIdentifier);
    if (!m_audioSource) {
        RELEASE_LOG_ERROR(WebRTC, "CapturePreviewManager no audio source for '%s'", device.label().utf8().legacyCStringPointer());
        return;
    }

    m_audioSource->addAudioSampleObserver(*this);
    m_audioSource->start();
}

#if PLATFORM(IOS_FAMILY) && USE(AUDIO_SESSION)

void CapturePreviewManager::prepareAudioSession(CompletionHandler<void()>&& completionHandler)
{
    // Saved once for the life of the preview rather than once per source: each microphone selection
    // starts a new source, which sets its own preferred input, so saving again here would record the
    // prompt's own choice and restore that instead of what the application had.
    if (!m_savedPreferredMicrophoneID)
        m_savedPreferredMicrophoneID = WebCore::AVAudioSessionCaptureDeviceManager::singleton().preferredMicrophoneID();

    GPUProcess::singleton().audioSessionManager().beginCapturePreview(WTF::move(completionHandler));
}

void CapturePreviewManager::restoreAudioSession()
{
    auto savedPreferredMicrophoneID = std::exchange(m_savedPreferredMicrophoneID, std::nullopt);
    if (!savedPreferredMicrophoneID)
        return;

    WebCore::AVAudioSessionCaptureDeviceManager::singleton().setPreferredMicrophoneID(*savedPreferredMicrophoneID);
    GPUProcess::singleton().audioSessionManager().endCapturePreview();
}

#endif // PLATFORM(IOS_FAMILY) && USE(AUDIO_SESSION)

void CapturePreviewManager::startVideo(const WebCore::CaptureDevice& device, WebCore::PageIdentifier pageIdentifier, WebCore::IntSize previewSize, StartCallback&& callback)
{
    m_videoSource = createSource(device, pageIdentifier);
    if (!m_videoSource) {
        callback({ });
        return;
    }

    // Without this the preview ignores device orientation entirely and the image is sideways.
    m_videoSource->monitorOrientation(m_orientationNotifier);

    m_displayLayer = WebCore::SampleBufferDisplayLayer::create(*this);
    if (!m_displayLayer) {
        RELEASE_LOG_ERROR(WebRTC, "CapturePreviewManager unable to create a display layer");
        stopVideo();
        callback({ });
        return;
    }

    // The size comes from the UI process, which owns the layout. A source's intrinsicSize() is
    // still empty at this point, which produced a zero-sized layer and nothing to composite.
    constexpr bool hideRootLayer = false;
    constexpr bool shouldMaintainAspectRatio = true;
    m_displayLayer->initialize(hideRootLayer, previewSize, shouldMaintainAspectRatio, [protectedThis = Ref { *this }, callback = WTF::move(callback)](bool didSucceed) mutable {
        if (!didSucceed || !protectedThis->m_displayLayer) {
            RELEASE_LOG_ERROR(WebRTC, "CapturePreviewManager display layer failed to initialize");
            protectedThis->stopVideo();
            return callback({ });
        }

        // Default options would leave m_hostable null on iOS, and hostingContext() derives the send
        // right from it. Matches RemoteSampleBufferDisplayLayer::initialize.
        LayerHostingContextOptions contextOptions;
#if PLATFORM(IOS_FAMILY)
        contextOptions.canShowWhileLocked = false;
#if USE(EXTENSIONKIT)
        contextOptions.useHostable = true;
#endif
#endif
        protectedThis->m_layerHostingContext = LayerHostingContext::create(contextOptions);
        protectedThis->m_layerHostingContext->setRootLayer(protectedThis->m_displayLayer->rootLayer());
        protectedThis->m_hostingContext = protectedThis->m_layerHostingContext->hostingContext();

#if ENABLE(APP_PRIVACY_REPORT) && !PLATFORM(MACCATALYST)
        // -[AVCaptureSession init] raises rather than failing when this process has no capture
        // identity, and an unhandled ObjC exception aborts the process.
        if (!WebCore::RealtimeMediaSourceCenter::singleton().hasIdentity()) {
            RELEASE_LOG_ERROR(WebRTC, "CapturePreviewManager refusing to start video capture without an identity");
            protectedThis->stopVideo();
            return callback({ });
        }
#endif

        // Recorded only once the source is actually running. A device left recorded after a failure
        // would make re-picking it from the menu a no-op, so a transient failure — the camera held by
        // another application, say — could never be retried for the life of the prompt.
        protectedThis->m_videoDeviceID = protectedThis->m_videoSource->persistentID();

        // Frames are only forwarded once there is somewhere to draw them.
        protectedThis->m_videoSource->addVideoFrameObserver(protectedThis.get());
        protectedThis->m_videoSource->start();

        callback(protectedThis->m_hostingContext);
    });
}

void CapturePreviewManager::setOrientation(WebCore::IntDegrees orientation)
{
    m_orientationNotifier.orientationChanged(orientation);
}

void CapturePreviewManager::rotationAngleForCaptureDeviceChanged(const String& persistentId, WebCore::VideoFrameRotation rotation)
{
    m_orientationNotifier.rotationAngleForCaptureDeviceChanged(persistentId, rotation);
}

void CapturePreviewManager::stopVideo()
{
    // The observer has to go first: videoFrameAvailable reads m_displayLayer on a capture thread, and
    // removeVideoFrameObserver takes the same lock that is held across frame delivery, so returning
    // from it is what guarantees no concurrent read.
    if (RefPtr videoSource = WTF::move(m_videoSource)) {
        videoSource->removeVideoFrameObserver(*this);
        videoSource->endImmediatly();
    }

    m_videoDeviceID = { };
    m_layerHostingContext = nullptr;
    m_displayLayer = nullptr;
    m_hostingContext = { };
}

void CapturePreviewManager::stopAudio()
{
    if (RefPtr audioSource = WTF::move(m_audioSource)) {
        audioSource->removeAudioSampleObserver(*this);
        audioSource->endImmediatly();
    }

    m_audioDeviceID = { };
    m_peakSinceLastLevel = 0;
    m_framesSinceLastLevel = 0;
}

void CapturePreviewManager::stop()
{
    stopVideo();
    stopAudio();

#if PLATFORM(IOS_FAMILY) && USE(AUDIO_SESSION)
    // After stopAudio() and before the grant is reported, so the page's own capture sets its
    // preferred input over a restored value rather than the other way round.
    restoreAudioSession();
#endif
}

void CapturePreviewManager::videoFrameAvailable(WebCore::VideoFrame& frame, WebCore::VideoFrameTimeMetadata)
{
    if (RefPtr displayLayer = m_displayLayer)
        displayLayer->enqueueVideoFrame(frame);
}

void CapturePreviewManager::sampleBufferDisplayLayerStatusDidFail()
{
    RELEASE_LOG_ERROR(WebRTC, "CapturePreviewManager display layer status failed");
}

// Quietest level shown as non-zero.
static constexpr float audioLevelFloorInDBFS = -60;
static constexpr unsigned audioLevelUpdatesPerSecond = 15;

static float normalizedLevelFromPeak(float peak)
{
    if (peak <= 0)
        return 0;

    float dbfs = 20 * std::log10(peak);
    if (dbfs <= audioLevelFloorInDBFS)
        return 0;

    return std::clamp((dbfs - audioLevelFloorInDBFS) / -audioLevelFloorInDBFS, 0.f, 1.f);
}

void CapturePreviewManager::audioSamplesAvailable(const WTF::MediaTime&, const WebCore::PlatformAudioData& data, const WebCore::AudioStreamDescription& description, size_t numberOfFrames)
{
    if (!description.isFloat())
        return;

    auto& bufferList = downcast<WebCore::WebAudioBufferList>(data);
    auto* list = bufferList.list();
    if (!list)
        return;

    float peak = 0;
    for (uint32_t bufferIndex = 0; bufferIndex < list->mNumberBuffers; ++bufferIndex) {
        for (auto sample : bufferList.bufferAsSpan<const float>(bufferIndex))
            peak = std::max(peak, std::abs(sample));
    }

    m_peakSinceLastLevel = std::max(m_peakSinceLastLevel, peak);
    m_framesSinceLastLevel += numberOfFrames;

    size_t framesPerUpdate = static_cast<size_t>(description.sampleRate() / audioLevelUpdatesPerSecond);
    if (!framesPerUpdate || m_framesSinceLastLevel < framesPerUpdate)
        return;

    m_framesSinceLastLevel = 0;
    float level = normalizedLevelFromPeak(std::exchange(m_peakSinceLastLevel, 0));

    // Called on a capture thread, so the handler is invoked where the UI process can be reached.
    callOnMainRunLoop([protectedThis = Ref { *this }, level] {
        if (protectedThis->m_audioLevelHandler)
            protectedThis->m_audioLevelHandler(level);
    });
}

} // namespace WebKit

#endif // ENABLE(MEDIA_STREAM)
