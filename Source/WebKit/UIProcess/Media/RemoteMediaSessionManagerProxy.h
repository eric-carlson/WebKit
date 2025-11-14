/*
 * Copyright (C) 2025 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#if ENABLE(VIDEO) || ENABLE(WEB_AUDIO)

#include "MessageReceiver.h"
#include "MessageSender.h"
#include "WebProcessProxy.h"
#include <WebCore/PageIdentifier.h>
#include <wtf/RefCounted.h>
#include <wtf/TZoneMalloc.h>


#if PLATFORM(IOS_FAMILY)
#include <WebCore/MediaSessionManageriOS.h>
#define REMOTE_MEDIA_SESSION_MANAGER_BASE_CLASS MediaSessionManageriOS
#elif PLATFORM(COCOA)
#include <WebCore/MediaSessionManagerCocoa.h>
#define REMOTE_MEDIA_SESSION_MANAGER_BASE_CLASS MediaSessionManagerCocoa
#else
#include <WebCore/PlatformMediaSessionManager.h>
#define REMOTE_MEDIA_SESSION_MANAGER_BASE_CLASS PlatformMediaSessionManager
#endif

namespace WebCore {
class PlatformMediaSessionInterface;
}

namespace WebKit {

class RemoteMediaSessionProxy;
class WebProcessProxy;
struct RemoteMediaSessionState;

class RemoteMediaSessionManagerProxy
    : public WebCore::REMOTE_MEDIA_SESSION_MANAGER_BASE_CLASS
    , public IPC::MessageReceiver
    , public IPC::MessageSender {
    WTF_MAKE_TZONE_ALLOCATED(RemoteMediaSessionManagerProxy);
public:
    USING_CAN_MAKE_WEAKPTR(REMOTE_MEDIA_SESSION_MANAGER_BASE_CLASS);

    static RefPtr<RemoteMediaSessionManagerProxy> create(WebCore::PageIdentifier, WebProcessProxy&);

    virtual ~RemoteMediaSessionManagerProxy();

    void ref() const final { ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr::ref(); }
    void deref() const final { ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr::deref(); }

    const Ref<WebProcessProxy> process() const { return m_process; }

private:
    RemoteMediaSessionManagerProxy(WebCore::PageIdentifier, WebProcessProxy&);

    void addMediaSession(RemoteMediaSessionState&&);
    void removeMediaSession(RemoteMediaSessionState&&);
    void setCurrentMediaSession(RemoteMediaSessionState&&);
    void updateMediaSessionState();

    RefPtr<WebCore::PlatformMediaSessionInterface> findSession(RemoteMediaSessionState&);

    void didReceiveMessage(IPC::Connection&, IPC::Decoder&);

    // IPC::MessageSender.
    IPC::Connection* messageSenderConnection() const final;
    uint64_t messageSenderDestinationID() const final;

    std::optional<SharedPreferencesForWebProcess> sharedPreferencesForWebProcess() const;

#if !RELEASE_LOG_DISABLED
    ASCIILiteral logClassName() const final { return "RemoteMediaSessionManagerProxy"_s; }
#endif

    const Ref<WebProcessProxy> m_process;
    WebCore::PageIdentifier m_topPageID;
    HashMap<WebCore::MediaSessionIdentifier, Ref<RemoteMediaSessionProxy>> m_sessionProxies;
};

} // namespace WebKit

#endif // ENABLE(VIDEO) || ENABLE(WEB_AUDIO)
