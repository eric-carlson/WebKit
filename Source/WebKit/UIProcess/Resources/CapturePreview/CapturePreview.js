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

"use strict";

const videoGroup = document.getElementById("video-group");
const videoFrame = document.getElementById("video-frame");
const audioGroup = document.getElementById("audio-group");
const previewElement = document.getElementById("preview");
const previewBadge = document.getElementById("preview-badge");
const meterFill = document.getElementById("meter-fill");
const cameraSelect = document.getElementById("camera-select");
const microphoneSelect = document.getElementById("microphone-select");

let videoStream = null;
let audioStream = null;
let audioContext = null;
let analyser = null;
let analyserData = null;
let meterFrame = 0;

// Labels the host wants offered, in the order it wants them. Index into these is the only
// device identity shared with the host: its deviceIds and ours are salted differently and
// are not comparable.
let requestedCameraLabels = [];
let requestedMicrophoneLabels = [];

function postToHost(name, payload)
{
    window.webkit?.messageHandlers?.capturePreview?.postMessage({ name, ...payload });
}

function reportFailure(kind, error)
{
    // Leaving the spinner up after a failure would suggest something is still coming.
    setLoading(false);
    postToHost("previewFailed", { kind, message: String(error) });
}

function setLoading(loading)
{
    videoFrame.classList.toggle("loading", loading);
}

// requestVideoFrameCallback fires when a frame has actually been presented, which is the
// real "there is something to look at" moment; getUserMedia resolves well before that, and
// even "playing" can precede the first painted frame. "playing" is kept as a fallback so a
// missing rVFC implementation cannot leave the spinner up forever.
function awaitFirstFrame()
{
    if (!previewElement.requestVideoFrameCallback)
        return;

    previewElement.requestVideoFrameCallback(() => setLoading(false));
}

previewElement.addEventListener("playing", () => {
    setLoading(false);
});

async function showStream(stream)
{
    previewElement.srcObject = stream;

    awaitFirstFrame();

    // The autoplay attribute alone is not enough: the element can be held back by autoplay
    // restrictions, which leaves a live stream rendering nothing at all.
    try {
        await previewElement.play();
    } catch (error) {
        reportFailure("play", error);
    }
}

function stopStream(stream)
{
    if (stream) {
        for (const track of stream.getTracks())
            track.stop();
    }
    return null;
}

function stopMetering()
{
    if (meterFrame) {
        cancelAnimationFrame(meterFrame);
        meterFrame = 0;
    }

    analyser = null;
    analyserData = null;
    meterFill.style.width = "0";

    if (audioContext) {
        audioContext.close();
        audioContext = null;
    }
}

function updateMeter()
{
    if (!analyser)
        return;

    analyser.getByteTimeDomainData(analyserData);

    let sumOfSquares = 0;
    for (const sample of analyserData) {
        const centered = (sample - 128) / 128;
        sumOfSquares += centered * centered;
    }

    const rms = Math.sqrt(sumOfSquares / analyserData.length);
    const level = Math.min(1, Math.pow(rms * 3, 0.7));

    meterFill.style.width = `${level * 100}%`;
    meterFrame = requestAnimationFrame(updateMeter);
}

function startMetering(stream)
{
    stopMetering();

    audioContext = new AudioContext();
    analyser = audioContext.createAnalyser();
    analyser.fftSize = 1024;
    analyserData = new Uint8Array(analyser.fftSize);
    audioContext.createMediaStreamSource(stream).connect(analyser);
    meterFrame = requestAnimationFrame(updateMeter);
}

function optionsFor(select, requestedLabels, pageDevices)
{
    select.textContent = "";

    // Each host slot claims the first not-yet-claimed device with a matching label, so two
    // devices sharing a label still map to distinct slots in order.
    const claimed = new Set();

    requestedLabels.forEach((label, hostIndex) => {
        const match = pageDevices.find(device => device.label === label && !claimed.has(device.deviceId));
        if (!match)
            return;

        claimed.add(match.deviceId);

        const option = document.createElement("option");
        option.value = String(hostIndex);
        option.dataset.deviceId = match.deviceId;
        option.textContent = label;
        option.title = label;
        select.appendChild(option);
    });

    select.selectedIndex = select.options.length ? 0 : -1;
    select.hidden = select.options.length < 2;
    select.disabled = select.options.length < 2;
}

function selectedOption(select)
{
    return select.selectedIndex >= 0 ? select.options[select.selectedIndex] : null;
}

function selectedHostIndex(select)
{
    const option = selectedOption(select);
    return option ? parseInt(option.value, 10) : -1;
}

function reportSelection()
{
    postToHost("selectionChanged", {
        videoIndex: selectedHostIndex(cameraSelect),
        audioIndex: selectedHostIndex(microphoneSelect),
    });
}

async function useCamera(deviceId)
{
    setLoading(true);
    videoStream = stopStream(videoStream);
    previewElement.srcObject = null;

    try {
        videoStream = await navigator.mediaDevices.getUserMedia({ video: { deviceId: { exact: deviceId } } });
        await showStream(videoStream);
    } catch (error) {
        reportFailure("camera", error);
    }
}

async function useMicrophone(deviceId)
{
    stopMetering();
    audioStream = stopStream(audioStream);

    try {
        audioStream = await navigator.mediaDevices.getUserMedia({ audio: { deviceId: { exact: deviceId } } });
        startMetering(audioStream);
    } catch (error) {
        reportFailure("microphone", error);
    }
}

cameraSelect.addEventListener("change", () => {
    const option = selectedOption(cameraSelect);
    if (option)
        useCamera(option.dataset.deviceId);
    reportSelection();
});

microphoneSelect.addEventListener("change", () => {
    const option = selectedOption(microphoneSelect);
    if (option)
        useMicrophone(option.dataset.deviceId);
    reportSelection();
});

async function buildMenus()
{
    let pageDevices;
    try {
        pageDevices = await navigator.mediaDevices.enumerateDevices();
    } catch (error) {
        reportFailure("enumerate", error);
        return;
    }

    const cameras = pageDevices.filter(device => device.kind === "videoinput");
    const microphones = pageDevices.filter(device => device.kind === "audioinput");

    optionsFor(cameraSelect, requestedCameraLabels, cameras);
    optionsFor(microphoneSelect, requestedMicrophoneLabels, microphones);

    videoGroup.hidden = !cameraSelect.options.length;
    audioGroup.hidden = !microphoneSelect.options.length;

    reportSelection();
}

window.setDevices = async function(payload)
{
    if (payload.previewLabel !== undefined)
        previewBadge.textContent = payload.previewLabel;

    requestedCameraLabels = payload.cameras ?? [];
    requestedMicrophoneLabels = payload.microphones ?? [];

    // An unconstrained request comes first: enumerateDevices() withholds labels and device
    // ids until capture has been permitted, and this establishes that. It also puts a preview
    // on screen without waiting for the menus to be worked out.
    if (!videoStream && requestedCameraLabels.length) {
        setLoading(true);
        try {
            videoStream = await navigator.mediaDevices.getUserMedia({ video: true });
            videoGroup.hidden = false;
            await showStream(videoStream);
        } catch (error) {
            reportFailure("camera", error);
        }
    }

    if (!audioStream && requestedMicrophoneLabels.length) {
        try {
            audioStream = await navigator.mediaDevices.getUserMedia({ audio: true });
            startMetering(audioStream);
            audioGroup.hidden = false;
        } catch (error) {
            reportFailure("microphone", error);
        }
    }

    await buildMenus();

    // Move onto whichever device the host put first, if the unconstrained request did not
    // already land there.
    const cameraOption = selectedOption(cameraSelect);
    if (cameraOption && videoStream) {
        const currentId = videoStream.getVideoTracks()[0]?.getSettings()?.deviceId;
        if (currentId !== cameraOption.dataset.deviceId)
            await useCamera(cameraOption.dataset.deviceId);
    }

    const microphoneOption = selectedOption(microphoneSelect);
    if (microphoneOption && audioStream) {
        const currentId = audioStream.getAudioTracks()[0]?.getSettings()?.deviceId;
        if (currentId !== microphoneOption.dataset.deviceId)
            await useMicrophone(microphoneOption.dataset.deviceId);
    }
};

window.stopPreview = function()
{
    stopMetering();
    videoStream = stopStream(videoStream);
    audioStream = stopStream(audioStream);
    previewElement.srcObject = null;
};

postToHost("ready", {});
