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

#include <optional>
#include <wtf/RefCounted.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

namespace WebKit {

// More than this and the stacked buttons push the prompt past a comfortable height, on macOS and iOS
// alike.
constexpr size_t maximumPromptAdditionalActions = 2;

struct MediaPermissionPromptAdditionalAction {
    enum class Decision : bool { Deny, Allow };

    String title;
    Decision decision { Decision::Deny };
};

// A null string means the prompt keeps the text WebKit would have used. Informative text has no WebKit
// default, so a null one means none is shown.
struct MediaPermissionPromptCustomization {
    String messageText;
    String informativeText;
    String allowButtonTitle;
    String denyButtonTitle;
    Vector<MediaPermissionPromptAdditionalAction> additionalActions;

    bool hasAdditionalActionThatAllows() const
    {
        return additionalActions.containsIf([](auto& action) {
            return action.decision == MediaPermissionPromptAdditionalAction::Decision::Allow;
        });
    }
};

// The device IDs are null unless the prompt offered device menus and the outcome allows capture.
struct MediaPermissionPromptResult {
    bool granted { false };
    // False when the prompt closed, or never showed, without the user pressing a button.
    bool wasAnswered { false };
    std::optional<size_t> chosenAdditionalActionIndex;
    String selectedAudioDeviceUID;
    String selectedVideoDeviceUID;
};

// No button means the prompt closed without an answer. A null device ID keeps the prompt's selection.
struct MediaPermissionPromptResponseForTesting {
    std::optional<size_t> buttonIndex;
    String cameraPersistentID;
    String microphonePersistentID;
};

// Lets an API test answer the prompt, which it cannot press: it gets what the user would see instead,
// kept current while the prompt is up.
class MediaPermissionPromptForTesting : public RefCounted<MediaPermissionPromptForTesting> {
public:
    struct Device {
        String persistentID;
        String label;
    };

    virtual ~MediaPermissionPromptForTesting() = default;

    const String& title() const LIFETIME_BOUND { return m_title; }
    const String& informativeText() const LIFETIME_BOUND { return m_informativeText; }
    // Allow, then the additional actions, then Deny, as they are laid out.
    const Vector<String>& buttonTitles() const LIFETIME_BOUND { return m_buttonTitles; }
    bool showsPreview() const { return m_showsPreview; }

    virtual Vector<Device> cameras() const = 0;
    virtual Vector<Device> microphones() const = 0;
    virtual String selectedCameraID() const = 0;
    virtual String selectedMicrophoneID() const = 0;
    virtual unsigned audioLevelUpdateCount() const = 0;
    virtual unsigned previewLayerCount() const = 0;
    virtual bool hasPreviewLayer() const = 0;

    virtual void selectCamera(size_t index) = 0;
    virtual void selectMicrophone(size_t index) = 0;
    virtual void respond(MediaPermissionPromptResponseForTesting&&) = 0;

protected:
    MediaPermissionPromptForTesting(String&& title, String&& informativeText, Vector<String>&& buttonTitles, bool showsPreview)
        : m_title(WTF::move(title))
        , m_informativeText(WTF::move(informativeText))
        , m_buttonTitles(WTF::move(buttonTitles))
        , m_showsPreview(showsPreview)
    {
    }

private:
    String m_title;
    String m_informativeText;
    Vector<String> m_buttonTitles;
    bool m_showsPreview { false };
};

} // namespace WebKit
