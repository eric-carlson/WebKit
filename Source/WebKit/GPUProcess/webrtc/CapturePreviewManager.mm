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

#include "GPUProcess.h"
#include "GPUProcessProxyMessages.h"
#include "LayerHostingContext.h"
#include "Logging.h"
#include <WebCore/MediaDeviceHashSalts.h>
#include <WebCore/RealtimeMediaSourceCenter.h>
#include <WebCore/VideoFrame.h>
#include <WebCore/WebAudioBufferList.h>
#include <cmath>
#include <wtf/Box.h>
#include <wtf/TZoneMallocInlines.h>

#if PLATFORM(IOS_FAMILY) && USE(AUDIO_SESSION)
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
            device.label().utf8(),
            device.persistentId().utf8(),
            static_cast<int>(sourceOrError.error.denialReason),
            sourceOrError.error.errorMessage.utf8());
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
#if PLATFORM(IOS_FAMILY) && USE(AUDIO_SESSION)
        else
            restoreAudioSession();
#endif
    }

    // The layer is built at the preview's size, so a prompt resized by rotation needs a new one.
    if (videoDeviceID == m_videoDeviceID && previewSize == m_previewSize) {
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
    // A capture unit started before the session settles reads the old category, suspends itself and
    // reports nothing, so the preview is silent.
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
    // Two audio session completions for the same device can both arrive, as when the selection goes
    // B, C, B. A source left attached would keep calling audioSamplesAvailable from its own thread.
    if (RefPtr previousSource = WTF::move(m_audioSource)) {
        previousSource->removeAudioSampleObserver(*this);
        previousSource->endImmediatly();
    }

    m_audioSource = createSource(device, pageIdentifier);
    if (!m_audioSource) {
        RELEASE_LOG_ERROR(WebRTC, "CapturePreviewManager no audio source for '%s'", device.label().utf8());
        return;
    }

    protect(m_audioSource)->addAudioSampleObserver(*this);
    protect(m_audioSource)->start();
}

#if PLATFORM(IOS_FAMILY) && USE(AUDIO_SESSION)

void CapturePreviewManager::prepareAudioSession(CompletionHandler<void()>&& completionHandler)
{
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

    protect(m_videoSource)->monitorOrientation(m_orientationNotifier);

    m_displayLayer = WebCore::SampleBufferDisplayLayer::create(*this);
    if (!m_displayLayer) {
        RELEASE_LOG_ERROR(WebRTC, "CapturePreviewManager unable to create a display layer");
        stopVideo();
        callback({ });
        return;
    }

    // The size comes from the prompt: the source's intrinsicSize() is still empty here.
    constexpr bool hideRootLayer = false;
    constexpr bool shouldMaintainAspectRatio = true;
    auto didInitialize = Box<std::optional<bool>>::create();
    protect(m_displayLayer)->initialize(hideRootLayer, previewSize, shouldMaintainAspectRatio, [didInitialize](bool didSucceed) {
        *didInitialize = didSucceed;
    });
    // LocalSampleBufferDisplayLayer answers synchronously; an asynchronous layer is treated as a failure.
    ASSERT(didInitialize->has_value());
    if (!didInitialize->value_or(false)) {
        RELEASE_LOG_ERROR(WebRTC, "CapturePreviewManager display layer failed to initialize");
        stopVideo();
        callback({ });
        return;
    }

    // Default options would leave m_hostable null with ExtensionKit, and hostingContext() derives the send
    // right from it. Matches RemoteSampleBufferDisplayLayer::initialize.
    LayerHostingContextOptions contextOptions;
#if PLATFORM(IOS_FAMILY) && USE(EXTENSIONKIT)
    contextOptions.useHostable = true;
#endif
    m_layerHostingContext = LayerHostingContext::create(contextOptions);
    m_layerHostingContext->setRootLayer(protect(m_displayLayer)->rootLayer());
    m_hostingContext = m_layerHostingContext->hostingContext();

    m_videoDeviceID = protect(m_videoSource)->persistentID();
    m_previewSize = previewSize;
    // Without this a camera that relies on the rotation coordinator previews unrotated, unless a
    // capture from the same camera happens to be monitoring it already.
    m_videoPageIdentifier = pageIdentifier;
    if (RefPtr connection = GPUProcess::singleton().parentProcessConnection())
        connection->send(Messages::GPUProcessProxy::StartMonitoringCaptureDeviceRotation(pageIdentifier, m_videoDeviceID, true), 0);
    // Added only once m_displayLayer is set, so a frame never arrives with nowhere to draw it.
    protect(m_videoSource)->addVideoFrameObserver(*this);
    protect(m_videoSource)->start();

    callback(m_hostingContext);
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
    // The observer goes first: removing it waits out any frame being delivered on a capture thread,
    // so m_displayLayer is never cleared while videoFrameAvailable reads it.
    if (RefPtr videoSource = WTF::move(m_videoSource)) {
        videoSource->removeVideoFrameObserver(*this);
        videoSource->endImmediatly();
    }

    if (auto pageIdentifier = std::exchange(m_videoPageIdentifier, std::nullopt); pageIdentifier && !m_videoDeviceID.isEmpty()) {
        if (RefPtr connection = GPUProcess::singleton().parentProcessConnection())
            connection->send(Messages::GPUProcessProxy::StopMonitoringCaptureDeviceRotation(*pageIdentifier, m_videoDeviceID, true), 0);
    }
    m_videoDeviceID = { };
    m_previewSize = { };
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
    // A level already queued for the main thread would otherwise reach the page's next prompt.
    m_audioLevelHandler = nullptr;
    stopVideo();
    stopAudio();

#if PLATFORM(IOS_FAMILY) && USE(AUDIO_SESSION)
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

constexpr float audioLevelFloorInDBFS = -60;
constexpr unsigned audioLevelUpdatesPerSecond = 15;

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

    callOnMainRunLoop([protectedThis = Ref { *this }, level] {
        if (protectedThis->m_audioLevelHandler)
            protectedThis->m_audioLevelHandler(level);
    });
}

} // namespace WebKit

#endif // ENABLE(MEDIA_STREAM)
