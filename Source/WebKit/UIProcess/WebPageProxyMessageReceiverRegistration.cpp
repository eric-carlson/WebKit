/*
 * Copyright (C) 2023 Apple Inc. All rights reserved.
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
#include "WebPageProxyMessageReceiverRegistration.h"

#include "WebPageProxyMessages.h"
#include "WebProcessProxy.h"

namespace WebKit {

WebPageProxyMessageReceiverRegistration::~WebPageProxyMessageReceiverRegistration()
{
    stopReceivingMessages();
}

void WebPageProxyMessageReceiverRegistration::startReceivingMessages(WebProcessProxy& process, WebCore::PageIdentifier webPageID, IPC::MessageReceiver& messageReceiver)
{
    stopReceivingMessages();
    process.addMessageReceiver(Messages::WebPageProxy::messageReceiverName(), webPageID, messageReceiver);
    m_data = { { webPageID, process } };
}

void WebPageProxyMessageReceiverRegistration::stopReceivingMessages()
{
    if (auto data = std::exchange(m_data, std::nullopt))
        data->protectedProcess()->removeMessageReceiver(Messages::WebPageProxy::messageReceiverName(), data->webPageID);
}

void WebPageProxyMessageReceiverRegistration::transferMessageReceivingFrom(WebPageProxyMessageReceiverRegistration& oldRegistration, IPC::MessageReceiver& newReceiver)
{
    ASSERT(!m_data);
    if (auto data = std::exchange(oldRegistration.m_data, std::nullopt)) {
        data->protectedProcess()->removeMessageReceiver(Messages::WebPageProxy::messageReceiverName(), data->webPageID);
        startReceivingMessages(data->process, data->webPageID, newReceiver);
    } else {
        stopReceivingMessages();
        ASSERT_NOT_REACHED();
    }
}

Ref<WebProcessProxy> WebPageProxyMessageReceiverRegistration::Data::protectedProcess()
{
    return process;
}

} // namespace WebKit
