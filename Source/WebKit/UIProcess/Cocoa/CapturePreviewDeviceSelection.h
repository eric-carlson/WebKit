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
#include <optional>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

namespace WebKit {

enum class CapturePreviewDeviceType : bool { Camera, Microphone };

class CapturePreviewDeviceSelection {
public:
    CapturePreviewDeviceSelection() = default;
    CapturePreviewDeviceSelection(Vector<WebCore::CaptureDevice>&& videoDevices, Vector<WebCore::CaptureDevice>&& audioDevices)
        : m_videoDevices(WTF::move(videoDevices))
        , m_audioDevices(WTF::move(audioDevices))
    {
        // A kind the request asked for but has no devices for never reaches the prompt:
        // validateRequestConstraintsAfterEnumeration fails the request first. So a non-empty list means
        // the request wants that kind, and an empty one means it does not.
        m_requestNeedsVideo = !m_videoDevices.isEmpty();
        m_requestNeedsAudio = !m_audioDevices.isEmpty();
    }

    bool requestNeeds(CapturePreviewDeviceType type) const { return type == CapturePreviewDeviceType::Camera ? m_requestNeedsVideo : m_requestNeedsAudio; }
    const Vector<WebCore::CaptureDevice>& devices(CapturePreviewDeviceType type) const { return type == CapturePreviewDeviceType::Camera ? m_videoDevices : m_audioDevices; }
    size_t selectedIndex(CapturePreviewDeviceType type) const { return type == CapturePreviewDeviceType::Camera ? m_selectedVideoIndex : m_selectedAudioIndex; }

    std::optional<WebCore::CaptureDevice> selectedDevice(CapturePreviewDeviceType type) const
    {
        auto& devices = this->devices(type);
        size_t index = selectedIndex(type);
        if (index >= devices.size())
            return std::nullopt;
        return devices[index];
    }

    String selectedDeviceID(CapturePreviewDeviceType type) const
    {
        auto device = selectedDevice(type);
        return device ? device->persistentId() : String { };
    }

    void select(CapturePreviewDeviceType type, size_t index)
    {
        ASSERT(index < devices(type).size());
        if (type == CapturePreviewDeviceType::Camera)
            m_selectedVideoIndex = index;
        else
            m_selectedAudioIndex = index;
    }

    bool canStillSatisfyRequest() const
    {
        return !(m_requestNeedsVideo && m_videoDevices.isEmpty()) && !(m_requestNeedsAudio && m_audioDevices.isEmpty());
    }

    // Returns whether the preview has to restart. That is only when a selected device changed: restarting
    // on every unrelated attach or detach would make the image or meter flash.
    bool update(Vector<WebCore::CaptureDevice>&& videoDevices, Vector<WebCore::CaptureDevice>&& audioDevices)
    {
        String previousVideoDeviceID = selectedDeviceID(CapturePreviewDeviceType::Camera);
        String previousAudioDeviceID = selectedDeviceID(CapturePreviewDeviceType::Microphone);

        m_videoDevices = WTF::move(videoDevices);
        m_audioDevices = WTF::move(audioDevices);

        // Kept by identity rather than index, or unplugging an earlier device would silently move the
        // selection to a different one.
        m_selectedVideoIndex = indexOfDevice(m_videoDevices, previousVideoDeviceID);
        m_selectedAudioIndex = indexOfDevice(m_audioDevices, previousAudioDeviceID);

        // True as well when every device is gone: the GPU process has to forget the old ones, or the
        // same device coming back looks unchanged and its preview never restarts.
        return selectedDeviceID(CapturePreviewDeviceType::Camera) != previousVideoDeviceID
            || selectedDeviceID(CapturePreviewDeviceType::Microphone) != previousAudioDeviceID;
    }

private:
    static size_t indexOfDevice(const Vector<WebCore::CaptureDevice>& devices, const String& deviceID)
    {
        if (deviceID.isEmpty())
            return 0;
        size_t index = devices.findIf([&deviceID](auto& device) {
            return device.persistentId() == deviceID;
        });
        return index == notFound ? 0 : index;
    }

    Vector<WebCore::CaptureDevice> m_videoDevices;
    Vector<WebCore::CaptureDevice> m_audioDevices;
    size_t m_selectedVideoIndex { 0 };
    size_t m_selectedAudioIndex { 0 };
    bool m_requestNeedsVideo { false };
    bool m_requestNeedsAudio { false };
};

} // namespace WebKit

#endif // ENABLE(MEDIA_STREAM)
