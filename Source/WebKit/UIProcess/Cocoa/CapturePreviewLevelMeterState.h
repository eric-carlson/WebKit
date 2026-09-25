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

#include <algorithm>
#include <cmath>
#include <wtf/MonotonicTime.h>
#include <wtf/Seconds.h>

namespace WebKit {

// The capture prompt's microphone meter, shared by macOS and iOS. Like the input level in System
// Settings it is a row of segments with the loudest recent level held briefly, so a quiet microphone
// still shows it heard something after the sound has stopped.
struct CapturePreviewLevelMeterState {
    static constexpr unsigned segmentCount = 15;
    static constexpr Seconds peakHoldDuration = 1.5_s;

    unsigned litSegments { 0 };
    // The peak is segment peakSegments - 1, or not shown when this is 0.
    unsigned peakSegments { 0 };
    MonotonicTime peakExpiry;

    // Returns whether anything visible changed, so a view redraws only when it has to.
    bool update(float level, MonotonicTime now)
    {
        unsigned previousLit = litSegments;
        unsigned previousPeak = peakSegments;

        litSegments = static_cast<unsigned>(std::lround(std::clamp(level, 0.f, 1.f) * segmentCount));
        if (litSegments >= peakSegments || now >= peakExpiry) {
            peakSegments = litSegments;
            peakExpiry = now + peakHoldDuration;
        }

        return litSegments != previousLit || peakSegments != previousPeak;
    }

    // Returns whether anything visible changed.
    bool reset()
    {
        bool changed = litSegments || peakSegments;
        litSegments = 0;
        peakSegments = 0;
        return changed;
    }
};

} // namespace WebKit
