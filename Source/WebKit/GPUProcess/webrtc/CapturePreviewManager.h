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

#if ENABLE(MEDIA_STREAM)

#include <WebCore/CaptureDevice.h>
#include <WebCore/HostingContext.h>
#include <WebCore/IntSize.h>
#include <WebCore/OrientationNotifier.h>
#include <WebCore/PageIdentifier.h>
#include <WebCore/RealtimeMediaSource.h>
#include <WebCore/SampleBufferDisplayLayer.h>
#include <wtf/CheckedPtr.h>
#include <wtf/CompletionHandler.h>
#include <wtf/Function.h>
#include <wtf/Ref.h>
#include <wtf/RefCounted.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/text/WTFString.h>

namespace WebKit {

class LayerHostingContext;

// Drives a capture preview for the getUserMedia permission prompt, on behalf of the UI
// process. Unlike UserMediaCaptureManagerProxy this keeps the source local to the GPU
// process: the video is rendered into a layer hosted by the UI process and the audio
// level is computed here, so there is no client process to marshal a source out to.
class CapturePreviewManager
    : public RefCounted<CapturePreviewManager>
    , public WebCore::RealtimeMediaSource::VideoFrameObserver
    , public WebCore::RealtimeMediaSource::AudioSampleObserver
    , public WebCore::SampleBufferDisplayLayerClient
    , public CanMakeCheckedPtr<CapturePreviewManager> {
    WTF_MAKE_TZONE_ALLOCATED(CapturePreviewManager);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(CapturePreviewManager);
    OVERRIDE_ABSTRACT_CAN_MAKE_CHECKEDPTR(CanMakeCheckedPtr);
public:
    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }

    static Ref<CapturePreviewManager> create() { return adoptRef(*new CapturePreviewManager); }
    ~CapturePreviewManager();

    USING_CAN_MAKE_WEAKPTR(WebCore::SampleBufferDisplayLayerClient);

    using StartCallback = CompletionHandler<void(WebCore::HostingContext)>;
    void start(std::optional<WebCore::CaptureDevice>&& videoDevice, std::optional<WebCore::CaptureDevice>&& audioDevice, WebCore::PageIdentifier, WebCore::IntSize previewSize, StartCallback&&);
    void stop();

    void setAudioLevelHandler(Function<void(float)>&& handler) { m_audioLevelHandler = WTF::move(handler); }

    // A preview has no web process connection, so it needs its own orientation notifier.
    void setOrientation(WebCore::IntDegrees);
    void rotationAngleForCaptureDeviceChanged(const String&, WebCore::VideoFrameRotation);

private:
    CapturePreviewManager();

    RefPtr<WebCore::RealtimeMediaSource> createSource(const WebCore::CaptureDevice&, WebCore::PageIdentifier);
    void startVideo(const WebCore::CaptureDevice&, WebCore::PageIdentifier, WebCore::IntSize, StartCallback&&);
    void startAudio(const WebCore::CaptureDevice&, WebCore::PageIdentifier);
    void startAudioSource(const WebCore::CaptureDevice&, WebCore::PageIdentifier);
    void stopVideo();
    void stopAudio();
#if PLATFORM(IOS_FAMILY) && USE(AUDIO_SESSION)
    void prepareAudioSession(CompletionHandler<void()>&&);
    void restoreAudioSession();
#endif

    // WebCore::RealtimeMediaSource::VideoFrameObserver
    void videoFrameAvailable(WebCore::VideoFrame&, WebCore::VideoFrameTimeMetadata) final;

    // WebCore::RealtimeMediaSource::AudioSampleObserver
    void audioSamplesAvailable(const WTF::MediaTime&, const WebCore::PlatformAudioData&, const WebCore::AudioStreamDescription&, size_t) final;

    // WebCore::SampleBufferDisplayLayerClient
    void sampleBufferDisplayLayerStatusDidFail() final;
    void updateVideoFrameCounters(uint64_t, uint64_t) final { }
#if PLATFORM(IOS_FAMILY)
    bool canShowWhileLocked() const final { return false; }
#endif

    RefPtr<WebCore::RealtimeMediaSource> m_videoSource;
    RefPtr<WebCore::RealtimeMediaSource> m_audioSource;
    RefPtr<WebCore::SampleBufferDisplayLayer> m_displayLayer;
    std::unique_ptr<LayerHostingContext> m_layerHostingContext;
    WebCore::HostingContext m_hostingContext;

    // Remembered so that changing one device does not tear down the other.
    String m_videoDeviceID;
    String m_audioDeviceID;

    WebCore::OrientationNotifier m_orientationNotifier { 0 };
    Function<void(float)> m_audioLevelHandler;
    float m_peakSinceLastLevel { 0 };
    size_t m_framesSinceLastLevel { 0 };
#if PLATFORM(IOS_FAMILY) && USE(AUDIO_SESSION)
    std::optional<String> m_savedPreferredMicrophoneID;
#endif
};

} // namespace WebKit

#endif // ENABLE(MEDIA_STREAM)
