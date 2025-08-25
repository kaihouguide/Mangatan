// ==UserScript==
// @name         Automatic Content OCR (PC Hybrid Engine)
// @namespace    http://tampermonkey.net/
// @version      24.4.3
// @description  Adds a stable, inline OCR button with hotkey-based editing. Features a high-performance hybrid rendering engine for perfectly smooth scrolling.
// @author       1Selxo (Probe Engine Port by Gemini, Hybrid Rendering & Hotkeys by Gemini)
// @match        *://127.0.0.1*/*
// @grant        GM_setValue
// @grant        GM_getValue
// @grant        GM_addStyle
// @grant        GM_xmlhttpRequest
// @connect      127.0.0.1
// @connect      localhost
// @downloadURL  https://github.com/kaihouguide/Mangatan/raw/main/desktop-script.user.js
// @updateURL    https://github.com/kaihouguide/Mangatan/raw/main/desktop-script.user.js
// ==/UserScript==

(function() {
    'use strict';
    // --- Global State and Settings ---
    let settings = {
        ocrServerUrl: 'http://127.0.0.1:3000',
        imageServerUser: '',
        imageServerPassword: '',
        ankiConnectUrl: 'http://127.0.0.1:8765',
        ankiImageField: 'Image',
        sites: [{
            urlPattern: '127.0.0.1',
            imageContainerSelectors: [
                'div.muiltr-masn8', // Old Continuous Vertical
                'div.muiltr-79elbk', // Webtoon
                'div.muiltr-u43rde', // Single Page
                'div.muiltr-1r1or1s', // Double Page
                'div.muiltr-18sieki', // New Continuous Vertical
                'div.muiltr-cns6dc', // Added per request
                '.MuiBox-root.muiltr-1noqzsz' // RTL Continuous Vertical (FIXED)
            ],
            overflowFixSelector: '.MuiBox-root.muiltr-13djdhf'
        }],
        debugMode: true,
        textOrientation: 'smart',
        interactionMode: 'hover',
        dimmedOpacity: 0.3,
        fontMultiplierHorizontal: 1.0,
        fontMultiplierVertical: 1.0,
        boundingBoxAdjustment: 5,
        focusScaleMultiplier: 1.1,
        soloHoverMode: false,
        mergeModifierKey: 'Control',
        deleteModifierKey: 'Alt'
    };
    let debugLog = [];
    const SETTINGS_KEY = 'gemini_ocr_settings_v24_pc_hotkey_editor';
    const ocrDataCache = new WeakMap();
    const managedElements = new Map();
    const managedContainers = new Map();
    const attachedAttributeObservers = new WeakMap();
    let activeSiteConfig = null;
    let measurementSpan = null;
    const UI = {};
    let activeImageForExport = null;
    let hideButtonTimer = null;

    // --- Editor State ---
    const activeMergeSelections = new Map();

    // --- Hybrid Render Engine State ---
    let resizeObserver;
    let intersectionObserver;
    const visibleImages = new Set();
    let animationFrameId = null;

    const COLOR_THEMES = {
        deepblue: {
            main: 'rgba(0,191,255,',
            text: '#FFFFFF',
            highlightText: '#000000'
        },
        red: {
            main: 'rgba(255, 71, 87,',
            text: '#FFFFFF',
            highlightText: '#000000'
        },
        green: {
            main: 'rgba(46, 204, 113,',
            text: '#FFFFFF',
            highlightText: '#000000'
        },
        orange: {
            main: 'rgba(243, 156, 18,',
            text: '#FFFFFF',
            highlightText: '#000000'
        },
        purple: {
            main: 'rgba(155, 89, 182,',
            text: '#FFFFFF',
            highlightText: '#000000'
        },
        turquoise: {
            main: 'rgba(26, 188, 156,',
            text: '#FFFFFF',
            highlightText: '#000000'
        },
        pink: {
            main: 'rgba(232, 67, 147,',
            text: '#FFFFFF',
            highlightText: '#000000'
        },
        grey: {
            main: 'rgba(149, 165, 166,',
            text: '#FFFFFF',
            highlightText: '#000000'
        }
    };
    const logDebug = (message) => {
        if (!settings.debugMode) return;
        const timestamp = new Date().toLocaleTimeString();
        const logEntry = `[${timestamp}] ${message}`;
        console.log(`[OCR Hybrid] ${logEntry}`);
        debugLog.push(logEntry);
        document.dispatchEvent(new CustomEvent('ocr-log-update'));
    };

    // --- Hybrid Render Engine Core (Unchanged) ---
    function updateVisibleOverlaysPosition() {
        for (const img of visibleImages) {
            const state = managedElements.get(img);
            if (state) {
                const rect = img.getBoundingClientRect();
                Object.assign(state.overlay.style, {
                    top: `${rect.top}px`,
                    left: `${rect.left}px`
                });
            }
        }
        animationFrameId = requestAnimationFrame(updateVisibleOverlaysPosition);
    }

    function updateOverlayDimensionsAndStyles(img, state, rect = null) {
        if (!rect) rect = img.getBoundingClientRect();
        if (rect.width > 0 && rect.height > 0) {
            Object.assign(state.overlay.style, {
                width: `${rect.width}px`,
                height: `${rect.height}px`
            });
            if (state.lastWidth !== rect.width || state.lastHeight !== rect.height) {
                calculateAndApplyOptimalStyles_Optimized(state.overlay, rect);
                state.lastWidth = rect.width;
                state.lastHeight = rect.height;
            }
        }
    }
    const handleResize = (entries) => {
        for (const entry of entries) {
            const img = entry.target;
            const state = managedElements.get(img);
            if (state) updateOverlayDimensionsAndStyles(img, state, entry.contentRect);
        }
    };
    const handleIntersection = (entries) => {
        for (const entry of entries) {
            const img = entry.target;
            if (entry.isIntersecting) {
                if (!visibleImages.has(img)) {
                    visibleImages.add(img);
                    const state = managedElements.get(img);
                    if (state) state.overlay.style.visibility = 'visible';
                    if (animationFrameId === null) {
                        logDebug("First visible image; starting position loop.");
                        animationFrameId = requestAnimationFrame(updateVisibleOverlaysPosition);
                    }
                }
            } else {
                if (visibleImages.has(img)) {
                    visibleImages.delete(img);
                    const state = managedElements.get(img);
                    if (state) state.overlay.style.visibility = 'hidden';
                    if (visibleImages.size === 0 && animationFrameId !== null) {
                        logDebug("Last visible image left; stopping position loop.");
                        cancelAnimationFrame(animationFrameId);
                        animationFrameId = null;
                    }
                }
            }
        }
    };

    function cleanupManagedElement(img) {
        const state = managedElements.get(img);
        if (state) {
            logDebug(`Garbage collecting disconnected overlay for ...${state.srcStub}`);
            resizeObserver.unobserve(img);
            intersectionObserver.unobserve(img);
            visibleImages.delete(img);
            activeMergeSelections.delete(state.overlay);
            state.overlay.remove();
            managedElements.delete(img);
            ocrDataCache.delete(img);
            if (visibleImages.size === 0 && animationFrameId !== null) {
                cancelAnimationFrame(animationFrameId);
                animationFrameId = null;
            }
        }
    }
    const periodicCleanup = () => {
        if (activeSiteConfig?.overflowFixSelector) {
            const el = document.querySelector(activeSiteConfig.overflowFixSelector);
            if (el && el.style.overflow !== 'visible') el.style.overflow = 'visible';
        }
        for (const [img] of managedElements.entries()) {
            if (!img.isConnected) {
                cleanupManagedElement(img);
            }
        }
    };

    // --- Core Observation Logic (Unchanged) ---
    const imageObserver = new MutationObserver((mutations) => {
        for (const mutation of mutations)
            for (const node of mutation.addedNodes)
                if (node.nodeType === 1) {
                    if (node.tagName === 'IMG') observeImageForSrcChange(node);
                    else node.querySelectorAll('img').forEach(observeImageForSrcChange);
                }
    });

    function manageContainer(container) {
        if (!managedContainers.has(container)) {
            logDebug(`New container found. Managing: ${container.className}`);
            container.querySelectorAll('img').forEach(observeImageForSrcChange);
            imageObserver.observe(container, {
                childList: true,
                subtree: true
            });
            managedContainers.set(container, true);
        }
    }
    const containerObserver = new MutationObserver((mutations) => {
        if (!activeSiteConfig) return;
        const selectorQuery = activeSiteConfig.imageContainerSelectors.join(', ');
        for (const mutation of mutations)
            for (const node of mutation.addedNodes)
                if (node.nodeType === 1) {
                    if (node.matches(selectorQuery)) manageContainer(node);
                    else node.querySelectorAll(selectorQuery).forEach(manageContainer);
                }
    });

    function activateScanner() {
        logDebug("Activating Hybrid scanner...");
        activeSiteConfig = settings.sites.find(site => window.location.href.includes(site.urlPattern));
        if (!activeSiteConfig?.imageContainerSelectors?.length) return logDebug(`No matching site config for URL: ${window.location.href}.`);
        const selectorQuery = activeSiteConfig.imageContainerSelectors.join(', ');
        document.querySelectorAll(selectorQuery).forEach(manageContainer);
        containerObserver.observe(document.body, {
            childList: true,
            subtree: true
        });
        logDebug("Main container observer is active.");
    }
    const chapterObserver = new MutationObserver((mutations) => {
        for (const mutation of mutations) {
            for (const node of mutation.addedNodes) {
                if (node.nodeType === 1) {
                    const chapterLinks = node.matches('a[href*="/manga/"][href*="/chapter/"]') ? [node] : node.querySelectorAll('a[href*="/manga/"][href*="/chapter/"]');
                    chapterLinks.forEach(addOcrButtonToChapter);
                }
            }
        }
    });

    function observeChapters() {
        const targetNode = document.getElementById('root');
        if (targetNode) {
            logDebug("Chapter observer activated on #root.");
            targetNode.querySelectorAll('a[href*="/manga/"][href*="/chapter/"]').forEach(addOcrButtonToChapter);
            chapterObserver.observe(targetNode, {
                childList: true,
                subtree: true
            });
        }
    }

    // --- Image Handling Logic (Unchanged) ---
    function observeImageForSrcChange(img) {
        const processTheImage = (src) => {
            if (src?.includes('/api/v1/manga/')) {
                primeImageForOcr(img);
                return true;
            }
            return false;
        };
        if (processTheImage(img.src) || attachedAttributeObservers.has(img)) return;
        const attributeObserver = new MutationObserver((mutations) => {
            for (const mutation of mutations)
                if (mutation.attributeName === 'src' && processTheImage(img.src)) {
                    attributeObserver.disconnect();
                    attachedAttributeObservers.delete(img);
                    break;
                }
        });
        attributeObserver.observe(img, {
            attributes: true
        });
        attachedAttributeObservers.set(img, attributeObserver);
    }

    function primeImageForOcr(img) {
        if (managedElements.has(img)) return;
        const process = () => {
            if (managedElements.has(img) || ocrDataCache.get(img) === 'pending') return;
            img.crossOrigin = "anonymous";
            processImage(img, img.src);
        };
        if (img.complete && img.naturalHeight > 0) process();
        else img.addEventListener('load', process, {
            once: true
        });
    }

    function processImage(img, sourceUrl) {
        if (ocrDataCache.has(img)) {
            displayOcrResults(img);
            return;
        }
        logDebug(`Requesting OCR for ...${sourceUrl.slice(-30)}`);
        ocrDataCache.set(img, 'pending');
        let ocrRequestUrl = `${settings.ocrServerUrl}/ocr?url=${encodeURIComponent(sourceUrl)}`;
        if (settings.imageServerUser) {
            ocrRequestUrl += `&user=${encodeURIComponent(settings.imageServerUser)}&pass=${encodeURIComponent(settings.imageServerPassword)}`;
        }
        GM_xmlhttpRequest({
            method: 'GET',
            url: ocrRequestUrl,
            timeout: 45000,
            onload: (res) => {
                try {
                    const data = JSON.parse(res.responseText);
                    if (data.error) throw new Error(data.error);
                    if (!Array.isArray(data)) throw new Error('Server response was not a valid OCR data array.');
                    ocrDataCache.set(img, data);
                    displayOcrResults(img);
                } catch (e) {
                    logDebug(`OCR Error for ${sourceUrl.slice(-30)}: ${e.message}`);
                    ocrDataCache.delete(img);
                }
            },
            onerror: () => {
                logDebug(`Connection error.`);
                ocrDataCache.delete(img);
            },
            ontimeout: () => {
                logDebug(`Request timed out.`);
                ocrDataCache.delete(img);
            }
        });
    }

    // --- Best-Fit Rendering Engine (Unchanged) ---
    function calculateAndApplyStylesForSingleBox(box, imgRect) {
        if (!measurementSpan || !box || !imgRect || imgRect.width === 0 || imgRect.height === 0) return;
        const text = box.textContent || '';
        const availableWidth = (parseFloat(box.style.width) / 100) * imgRect.width + settings.boundingBoxAdjustment;
        const availableHeight = (parseFloat(box.style.height) / 100) * imgRect.height + settings.boundingBoxAdjustment;
        if (!text || availableWidth <= 0 || availableHeight <= 0) return;
        const BASE_FONT_SIZE = 100;
        measurementSpan.style.writingMode = 'horizontal-tb';
        measurementSpan.textContent = text;
        const h_w = measurementSpan.offsetWidth,
            h_h = measurementSpan.offsetHeight;
        const h_ratio_w = h_w > 0 ? availableWidth / h_w : 0;
        const h_ratio_h = h_h > 0 ? availableHeight / h_h : 0;
        const horizontalFitSize = BASE_FONT_SIZE * Math.min(h_ratio_w, h_ratio_h);
        measurementSpan.style.writingMode = 'vertical-rl';
        const v_w = measurementSpan.offsetWidth,
            v_h = measurementSpan.offsetHeight;
        const v_ratio_w = v_w > 0 ? availableWidth / v_w : 0;
        const v_ratio_h = v_h > 0 ? availableHeight / v_h : 0;
        const verticalFitSize = BASE_FONT_SIZE * Math.min(v_ratio_w, v_ratio_h);
        let finalFontSize = 0,
            isVertical = false;
        if (settings.textOrientation === 'forceVertical') {
            isVertical = true;
            finalFontSize = verticalFitSize;
        } else if (settings.textOrientation === 'forceHorizontal') {
            isVertical = false;
            finalFontSize = horizontalFitSize;
        } else {
            if (verticalFitSize > horizontalFitSize) {
                isVertical = true;
                finalFontSize = verticalFitSize;
            } else {
                isVertical = false;
                finalFontSize = horizontalFitSize;
            }
        }
        const multiplier = isVertical ? settings.fontMultiplierVertical : settings.fontMultiplierHorizontal;
        box.style.fontSize = `${finalFontSize * multiplier}px`;
        box.classList.toggle('gemini-ocr-text-vertical', isVertical);
    }

    function calculateAndApplyOptimalStyles_Optimized(overlay, imgRect) {
        if (!measurementSpan || imgRect.width === 0 || imgRect.height === 0) return;
        const boxes = Array.from(overlay.querySelectorAll('.gemini-ocr-text-box'));
        if (boxes.length === 0) return;
        const baseStyle = getComputedStyle(boxes[0]);
        Object.assign(measurementSpan.style, {
            fontFamily: baseStyle.fontFamily,
            fontWeight: baseStyle.fontWeight,
            letterSpacing: baseStyle.letterSpacing,
            fontSize: '100px'
        });
        for (const box of boxes) {
            calculateAndApplyStylesForSingleBox(box, imgRect);
        }
        measurementSpan.style.writingMode = 'horizontal-tb';
    }

    // --- Display & Interaction Logic ---
    function displayOcrResults(targetImg) {
        if (managedElements.has(targetImg)) return;
        let data = ocrDataCache.get(targetImg);
        if (!data || data === 'pending' || !Array.isArray(data)) return;
        data.sort((a, b) => {
            const a_y = a.tightBoundingBox.y,
                b_y = b.tightBoundingBox.y,
                a_x = a.tightBoundingBox.x,
                b_x = b.tightBoundingBox.x,
                ROW_TOLERANCE = 0.05;
            if (Math.abs(a_y - b_y) < ROW_TOLERANCE) return b_x - a_x;
            else return a_y - b_y;
        });
        const overlay = document.createElement('div');
        overlay.className = `gemini-ocr-decoupled-overlay is-hidden interaction-mode-${settings.interactionMode}`;
        overlay.classList.toggle('solo-hover-mode', settings.soloHoverMode);
        overlay.style.visibility = 'hidden';

        data.forEach((item, index) => {
            const ocrBox = document.createElement('div');
            ocrBox.className = 'gemini-ocr-text-box';
            ocrBox.textContent = item.text;
            ocrBox._ocrData = item;
            ocrBox._ocrDataIndex = index;
            Object.assign(ocrBox.style, {
                left: `${item.tightBoundingBox.x*100}%`,
                top: `${item.tightBoundingBox.y*100}%`,
                width: `${item.tightBoundingBox.width*100}%`,
                height: `${item.tightBoundingBox.height*100}%`
            });
            overlay.appendChild(ocrBox);
        });
        document.body.appendChild(overlay);

        const state = {
            overlay,
            lastWidth: 0,
            lastHeight: 0,
            srcStub: targetImg.src.slice(-30)
        };
        managedElements.set(targetImg, state);

        const show = () => {
            clearTimeout(hideButtonTimer);
            overlay.classList.remove('is-hidden');
            overlay.classList.add('is-focused');
            UI.globalAnkiButton?.classList.remove('is-hidden');
            activeImageForExport = targetImg;
        };

        const hide = () => {
            // ** THE FIX **: Don't hide if a merge is in progress on this overlay.
            if (activeMergeSelections.has(overlay)) {
                return;
            }

            hideButtonTimer = setTimeout(() => {
                overlay.classList.add('is-hidden');
                overlay.classList.remove('is-focused');
                UI.globalAnkiButton?.classList.add('is-hidden');
                if (activeImageForExport === targetImg) activeImageForExport = null;
            }, 300);
        };
        [targetImg, overlay].forEach(el => {
            el.addEventListener('mouseenter', show);
            el.addEventListener('mouseleave', hide);
        });

        overlay.addEventListener('click', (e) => {
            const clickedBox = e.target.closest('.gemini-ocr-text-box');
            if (!clickedBox) {
                overlay.querySelectorAll('.manual-highlight').forEach(b => b.classList.remove('manual-highlight'));
                overlay.classList.remove('has-manual-highlight');
                return;
            };
            e.stopPropagation();

            if (isModifierPressed(e, settings.deleteModifierKey)) {
                handleBoxDelete(clickedBox, targetImg);
            } else if (isModifierPressed(e, settings.mergeModifierKey)) {
                handleMergeSelection(clickedBox, targetImg, overlay);
            } else if (settings.interactionMode === 'click') {
                overlay.querySelectorAll('.manual-highlight').forEach(b => b.classList.remove('manual-highlight'));
                clickedBox.classList.add('manual-highlight');
                overlay.classList.add('has-manual-highlight');
            }
        });

        updateOverlayDimensionsAndStyles(targetImg, state);
        resizeObserver.observe(targetImg);
        intersectionObserver.observe(targetImg);
    }

    // --- Hotkey-Based Editor Logic ---
    function isModifierPressed(event, keyName) {
        if (!keyName) return false;
        const lowerKey = keyName.toLowerCase();
        switch (lowerKey) {
            case 'control':
            case 'ctrl':
                return event.ctrlKey;
            case 'alt':
                return event.altKey;
            case 'shift':
                return event.shiftKey;
            case 'meta':
            case 'win':
            case 'cmd':
                return event.metaKey;
            default:
                return false;
        }
    }

    function handleBoxDelete(boxElement, sourceImage) {
        logDebug(`Deleting box with text: "${boxElement.textContent}"`);
        const data = ocrDataCache.get(sourceImage);
        if (!data) return;
        const dataIndex = boxElement._ocrDataIndex;
        const updatedData = data.filter((item, index) => index !== dataIndex);
        ocrDataCache.set(sourceImage, updatedData);
        boxElement.remove();
    }

    function handleMergeSelection(boxElement, sourceImage, overlay) {
        const currentSelection = activeMergeSelections.get(overlay);
        if (!currentSelection) {
            activeMergeSelections.set(overlay, [boxElement]);
            boxElement.classList.add('selected-for-merge');
            logDebug("Started merge selection.");
        } else {
            const firstBox = currentSelection[0];
            const secondBox = boxElement;
            if (firstBox === secondBox) return;
            finalizeMerge(firstBox, secondBox, sourceImage, overlay);
            activeMergeSelections.delete(overlay);
        }
    }

    function finalizeMerge(box1, box2, sourceImage, overlay) {
        logDebug("Finalizing merge.");
        const combinedText = box1.textContent + box2.textContent;
        let b1 = box1._ocrData.tightBoundingBox;
        let b2 = box2._ocrData.tightBoundingBox;
        const newBoundingBox = {
            x: Math.min(b1.x, b2.x),
            y: Math.min(b1.y, b2.y),
            width: Math.max(b1.x + b1.width, b2.x + b2.width) - Math.min(b1.x, b2.x),
            height: Math.max(b1.y + b1.height, b2.y + b2.height) - Math.min(b1.y, b2.y)
        };
        const newOcrItem = {
            text: combinedText,
            tightBoundingBox: newBoundingBox
        };

        const originalData = ocrDataCache.get(sourceImage);
        const indicesToDelete = new Set([box1._ocrDataIndex, box2._ocrDataIndex]);
        const newData = originalData.filter((item, index) => !indicesToDelete.has(index));
        newData.push(newOcrItem);
        ocrDataCache.set(sourceImage, newData);

        box1.remove();
        box2.remove();

        const newBoxElement = document.createElement('div');
        newBoxElement.className = 'gemini-ocr-text-box';
        newBoxElement.textContent = newOcrItem.text;
        newBoxElement._ocrData = newOcrItem;
        newBoxElement._ocrDataIndex = newData.length - 1;
        Object.assign(newBoxElement.style, {
            left: `${newOcrItem.tightBoundingBox.x*100}%`,
            top: `${newOcrItem.tightBoundingBox.y*100}%`,
            width: `${newOcrItem.tightBoundingBox.width*100}%`,
            height: `${newOcrItem.tightBoundingBox.height*100}%`
        });
        overlay.appendChild(newBoxElement);

        calculateAndApplyStylesForSingleBox(newBoxElement, sourceImage.getBoundingClientRect());
    }


    // --- Anki & Batch Processing (Unchanged) ---
    async function ankiConnectRequest(action, params = {}) {
        return new Promise((resolve, reject) => {
            GM_xmlhttpRequest({
                method: 'POST',
                url: settings.ankiConnectUrl,
                data: JSON.stringify({
                    action,
                    version: 6,
                    params
                }),
                headers: {
                    'Content-Type': 'application/json; charset=UTF-8'
                },
                timeout: 15000,
                onload: (res) => {
                    try {
                        const data = JSON.parse(res.responseText);
                        if (data.error) {
                            reject(new Error(data.error));
                        } else {
                            resolve(data.result);
                        }
                    } catch (e) {
                        reject(new Error('Failed to parse Anki-Connect response.'));
                    }
                },
                onerror: () => reject(new Error('Connection to Anki-Connect failed.')),
                ontimeout: () => reject(new Error('Anki-Connect request timed out.')),
            });
        });
    }
    async function exportImageToAnki(targetImg) {
        if (!settings.ankiImageField) {
            alert('Anki Image Field is not set in settings.');
            return false;
        }
        if (!targetImg || !targetImg.complete || !targetImg.naturalHeight) {
            alert('Anki Export Failed: Image not valid or loaded.');
            return false;
        }
        try {
            const canvas = document.createElement('canvas');
            canvas.width = targetImg.naturalWidth;
            canvas.height = targetImg.naturalHeight;
            const ctx = canvas.getContext('2d');
            ctx.drawImage(targetImg, 0, 0);
            const base64data = canvas.toDataURL('image/png').split(',')[1];
            if (!base64data) throw new Error("Canvas toDataURL failed.");
            const filename = `screenshot_${Date.now()}.png`;
            await ankiConnectRequest('storeMediaFile', {
                filename,
                data: base64data
            });
            const notes = await ankiConnectRequest('findNotes', {
                query: 'added:1'
            });
            if (!notes || notes.length === 0) {
                throw new Error('No recently added cards found. Create a card first.');
            }
            const lastNoteId = notes.sort((a, b) => b - a)[0];
            await ankiConnectRequest('updateNoteFields', {
                note: {
                    id: lastNoteId,
                    fields: {
                        [settings.ankiImageField]: `<img src="${filename}">`
                    }
                }
            });
            return true;
        } catch (error) {
            logDebug(`Anki Export Error: ${error.message}`);
            alert(`Anki Export Failed: ${error.message}`);
            return false;
        }
    }
    async function runProbingProcess(baseUrl, btn) {
        logDebug(`Requesting SERVER-SIDE job for: ${baseUrl}`);
        const originalText = btn.textContent;
        btn.disabled = true;
        btn.textContent = 'Starting...';
        const postData = {
            baseUrl: baseUrl,
            user: settings.imageServerUser,
            pass: settings.imageServerPassword
        };
        GM_xmlhttpRequest({
            method: 'POST',
            url: `${settings.ocrServerUrl}/preprocess-chapter`,
            headers: {
                'Content-Type': 'application/json'
            },
            data: JSON.stringify(postData),
            timeout: 10000,
            onload: (res) => {
                try {
                    const data = JSON.parse(res.responseText);
                    if (res.status === 202 && data.status === 'accepted') {
                        logDebug(`Chapter job successfully accepted by server.`);
                        btn.textContent = 'Accepted';
                        btn.style.borderColor = '#3498db';
                        checkServerStatus();
                    } else {
                        throw new Error(data.error || `Server responded with status ${res.status}`);
                    }
                } catch (e) {
                    logDebug(`Error starting chapter job: ${e.message}`);
                    btn.textContent = 'Error!';
                    btn.style.borderColor = '#c032b';
                    alert(`Failed to start chapter job: ${e.message}`);
                }
            },
            onerror: () => {
                logDebug('Connection error while trying to start chapter job.');
                btn.textContent = 'Conn. Error!';
                btn.style.borderColor = '#c0392b';
                alert('Failed to connect to the OCR server to start the job.');
            },
            ontimeout: () => {
                logDebug('Timeout while trying to start chapter job.');
                btn.textContent = 'Timeout!';
                btn.style.borderColor = '#c0392b';
                alert('The request to start the chapter job timed out.');
            },
            onloadend: () => {
                setTimeout(() => {
                    if (btn.isConnected) {
                        btn.textContent = originalText;
                        btn.style.borderColor = '';
                        btn.disabled = false;
                    }
                }, 3500);
            }
        });
    }
    async function batchProcessCurrentChapterFromURL() {
        const btn = UI.batchChapterBtn;
        const urlPath = window.location.pathname;
        const urlMatch = urlPath.match(/\/manga\/\d+\/chapter\/\d+/);
        if (!urlMatch) {
            alert(`Error: URL does not match '.../manga/ID/chapter/ID'.`);
            return;
        }
        const baseUrl = `${window.location.origin}/api/v1${urlMatch[0]}/page/`;
        await runProbingProcess(baseUrl, btn);
    }
    async function handleChapterBatchClick(event) {
        event.preventDefault();
        event.stopPropagation();
        const btn = event.currentTarget;
        const chapterLinkElement = btn.closest('a[href*="/manga/"][href*="/chapter/"]');
        if (!chapterLinkElement?.href) return;
        const urlPath = new URL(chapterLinkElement.href).pathname;
        const baseUrl = `${window.location.origin}/api/v1${urlPath}/page/`;
        await runProbingProcess(baseUrl, btn);
    }

    function addOcrButtonToChapter(chapterLinkElement) {
        const moreButton = chapterLinkElement.querySelector('button[aria-label="more"]');
        if (!moreButton) return;
        const actionContainer = moreButton.parentElement;
        if (!actionContainer || actionContainer.querySelector('.gemini-ocr-chapter-batch-btn')) return;
        const ocrButton = document.createElement('button');
        ocrButton.textContent = 'OCR';
        ocrButton.className = 'gemini-ocr-chapter-batch-btn';
        ocrButton.title = 'Queue this chapter for background pre-processing on the server';
        ocrButton.addEventListener('click', handleChapterBatchClick);
        actionContainer.insertBefore(ocrButton, moreButton);
    }

    // --- UI, Styles and Initialization (Unchanged) ---
    function manageScrollFix() {
        const urlPattern = '/manga/',
            shouldBeActive = window.location.href.includes(urlPattern),
            isActive = document.documentElement.classList.contains('ocr-scroll-fix-active');
        if (shouldBeActive && !isActive) document.documentElement.classList.add('ocr-scroll-fix-active');
        else if (!shouldBeActive && isActive) document.documentElement.classList.remove('ocr-scroll-fix-active');
    }

    function applyStyles() {
        const theme = COLOR_THEMES[settings.colorTheme] || COLOR_THEMES.deepblue;
        const cssVars = `:root { --ocr-bg-color: rgba(10,25,40,0.85); --ocr-border-color: ${theme.main}0.6); --ocr-border-color-dim: ${theme.main}0.3); --ocr-border-color-hover: ${theme.main}0.8); --ocr-text-color: ${theme.text}; --ocr-highlight-bg-color: ${theme.main}0.9); --ocr-highlight-border-color: rgba(255,255,255,0.9); --ocr-highlight-text-color: ${theme.highlightText}; --ocr-highlight-shadow: 0 0 10px ${theme.main}0.5); --ocr-highlight-inset-shadow: inset 0 0 0 2px white; --modal-header-color: ${theme.main}1); --ocr-dimmed-opacity: ${settings.dimmedOpacity}; --ocr-focus-scale: ${settings.focusScaleMultiplier}; }`;
        let styleTag = document.getElementById('gemini-ocr-dynamic-styles');
        if (!styleTag) {
            styleTag = document.createElement('style');
            styleTag.id = 'gemini-ocr-dynamic-styles';
            document.head.appendChild(styleTag);
        }
        styleTag.textContent = cssVars;
    }

    function createUI() {
        GM_addStyle(` html.ocr-scroll-fix-active { overflow: hidden !important; } html.ocr-scroll-fix-active body { overflow-y: auto !important; overflow-x: hidden !important; } .gemini-ocr-decoupled-overlay { position: fixed; z-index: 9998; pointer-events: none !important; transition: opacity 0.15s, visibility 0.15s; } .gemini-ocr-decoupled-overlay.is-hidden { opacity: 0; visibility: hidden; } .gemini-ocr-text-box { position: absolute; display: flex; align-items: center; justify-content: center; text-align: center; box-sizing: border-box; user-select: text; cursor: pointer; transition: all 0.2s ease-in-out; pointer-events: auto !important; overflow: hidden; color: rgba(0,0,0,0); padding: 4px; border-radius: 4px; } .gemini-ocr-text-vertical { writing-mode: vertical-rl; text-orientation: upright; } .is-focused .gemini-ocr-text-box { color: var(--ocr-text-color); background: var(--ocr-bg-color); border: 2px solid var(--ocr-border-color); text-shadow: 0 1px 3px rgba(0,0,0,0.9); backdrop-filter: blur(3px); } body:not(.ocr-edit-mode-active) .interaction-mode-hover.is-focused .gemini-ocr-text-box:hover, body:not(.ocr-edit-mode-active) .interaction-mode-click.is-focused .manual-highlight { transform: scale(var(--ocr-focus-scale)); background: var(--ocr-highlight-bg-color); border-color: var(--ocr-highlight-border-color); color: var(--ocr-highlight-text-color); text-shadow: none; box-shadow: var(--ocr-highlight-shadow), var(--ocr-highlight-inset-shadow); z-index: 9999; overflow: visible; } .interaction-mode-hover.is-focused:has(.gemini-ocr-text-box:hover):not(body.ocr-edit-mode-active *) .gemini-ocr-text-box:not(:hover), .interaction-mode-click.is-focused.has-manual-highlight .gemini-ocr-text-box:not(.manual-highlight) { opacity: var(--ocr-dimmed-opacity); background: rgba(10,25,40,0.5); border-color: var(--ocr-border-color-dim); } .solo-hover-mode.is-focused .gemini-ocr-text-box { visibility: hidden; opacity: 0; } .solo-hover-mode.is-focused .gemini-ocr-text-box:hover { visibility: visible; opacity: 1; } .gemini-ocr-text-box.selected-for-merge { box-shadow: inset 0 0 0 3px #f1c40f, 0 0 10px #f1c40f; opacity: 1 !important; transform: scale(1.02); } .gemini-ocr-chapter-batch-btn { font-family: "Roboto","Helvetica","Arial",sans-serif; font-weight: 500; font-size: 0.75rem; padding: 2px 8px; border-radius: 4px; border: 1px solid rgba(240,153,136,0.5); color: #f09988; background-color: transparent; cursor: pointer; margin-right: 4px; transition: all 150ms; min-width: 80px; text-align: center; } .gemini-ocr-chapter-batch-btn:hover { background-color: rgba(240,153,136,0.08); } .gemini-ocr-chapter-batch-btn:disabled { color: grey; border-color: grey; cursor: wait; } #gemini-ocr-settings-button { position: fixed; bottom: 15px; right: 15px; z-index: 2147483647; background: #1A1D21; color: #EAEAEA; border: 1px solid #555; border-radius: 50%; width: 50px; height: 50px; font-size: 26px; cursor: pointer; display: flex; align-items: center; justify-content: center; box-shadow: 0 4px 12px rgba(0,0,0,0.5); user-select: none; } #gemini-ocr-global-anki-export-btn { position: fixed; bottom: 75px; right: 15px; z-index: 2147483646; background-color: #2ecc71; color: white; border: 1px solid white; border-radius: 50%; width: 50px; height: 50px; font-size: 30px; line-height: 50px; text-align: center; cursor: pointer; transition: all 0.2s; user-select: none; box-shadow: 0 4px 12px rgba(0,0,0,0.5); } #gemini-ocr-global-anki-export-btn:hover { background-color: #27ae60; transform: scale(1.1); } #gemini-ocr-global-anki-export-btn:disabled { background-color: #95a5a6; cursor: wait; transform: none; } #gemini-ocr-global-anki-export-btn.is-hidden { opacity: 0; visibility: hidden; pointer-events: none; transform: scale(0.5); } .gemini-ocr-modal { position: fixed; top: 50%; left: 50%; transform: translate(-50%, -50%); background-color: #1A1D21; border: 1px solid var(--modal-header-color); border-radius: 15px; z-index: 2147483647; color: #EAEAEA; font-family: sans-serif; box-shadow: 0 8px 32px 0 rgba(0,0,0,0.5); width: 600px; max-width: 90vw; max-height: 90vh; display: flex; flex-direction: column; } .gemini-ocr-modal.is-hidden { display: none; } .gemini-ocr-modal-header { padding: 20px 25px; border-bottom: 1px solid #444; } .gemini-ocr-modal-header h2 { margin: 0; color: var(--modal-header-color); } .gemini-ocr-modal-content { padding: 10px 25px; overflow-y: auto; flex-grow: 1; } .gemini-ocr-modal-footer { padding: 15px 25px; border-top: 1px solid #444; display: flex; justify-content: flex-start; gap: 10px; align-items: center; } .gemini-ocr-modal-footer button:last-of-type { margin-left: auto; } .gemini-ocr-modal h3 { font-size: 1.1em; margin: 15px 0 10px 0; border-bottom: 1px solid #333; padding-bottom: 5px; color: var(--modal-header-color); } .gemini-ocr-settings-grid { display: grid; grid-template-columns: max-content 1fr; gap: 10px 15px; align-items: center; } .full-width { grid-column: 1 / -1; } .gemini-ocr-modal input, .gemini-ocr-modal textarea, .gemini-ocr-modal select { width: 100%; padding: 8px; box-sizing: border-box; font-family: monospace; background-color: #2a2a2e; border: 1px solid #555; border-radius: 5px; color: #EAEAEA; } .gemini-ocr-modal button { padding: 10px 18px; border: none; border-radius: 5px; color: #1A1D21; cursor: pointer; font-weight: bold; } #gemini-ocr-server-status { padding: 10px; border-radius: 5px; text-align: center; cursor: pointer; transition: background-color 0.3s; } #gemini-ocr-server-status.status-ok { background-color: #27ae60; } #gemini-ocr-server-status.status-error { background-color: #c0392b; } #gemini-ocr-server-status.status-checking { background-color: #3498db; }`);
        document.body.insertAdjacentHTML('beforeend', ` <button id="gemini-ocr-global-anki-export-btn" class="is-hidden" title="Export Screenshot to Anki">✚</button> <button id="gemini-ocr-settings-button">⚙️</button> <div id="gemini-ocr-settings-modal" class="gemini-ocr-modal is-hidden"> <div class="gemini-ocr-modal-header"><h2>Automatic Content OCR Settings (PC Hybrid)</h2></div> <div class="gemini-ocr-modal-content"> <h3>OCR & Image Source</h3><div class="gemini-ocr-settings-grid full-width"> <label for="gemini-ocr-server-url">OCR Server URL:</label><input type="text" id="gemini-ocr-server-url"> <label for="gemini-image-server-user">Image Source Username:</label><input type="text" id="gemini-image-server-user" autocomplete="username" placeholder="Optional"> <label for="gemini-image-server-password">Image Source Password:</label><input type="password" id="gemini-image-server-password" autocomplete="current-password" placeholder="Optional"> </div> <div id="gemini-ocr-server-status" class="full-width" style="margin-top: 10px;">Click to check server status</div> <h3>Anki Integration</h3><div class="gemini-ocr-settings-grid"> <label for="gemini-ocr-anki-url">Anki-Connect URL:</label><input type="text" id="gemini-ocr-anki-url"> <label for="gemini-ocr-anki-field">Image Field Name:</label><input type="text" id="gemini-ocr-anki-field" placeholder="e.g., Image"> </div> <h3>Interaction & Display</h3><div class="gemini-ocr-settings-grid"> <label for="ocr-color-theme">Color Theme:</label><select id="ocr-color-theme">${Object.keys(COLOR_THEMES).map(t=>`<option value="${t}">${t.charAt(0).toUpperCase()+t.slice(1)}</option>`).join('')}</select> <label for="ocr-interaction-mode">Highlight Mode:</label><select id="ocr-interaction-mode"><option value="hover">On Hover</option><option value="click">On Click</option></select> <label for="ocr-dimmed-opacity">Dimmed Box Opacity (%):</label><input type="number" id="ocr-dimmed-opacity" min="0" max="100" step="5"> <label for="ocr-focus-scale-multiplier">Focus Scale Multiplier:</label><input type="number" id="ocr-focus-scale-multiplier" min="1" max="3" step="0.05"> <label for="ocr-merge-key">Merge Modifier Key:</label><input type="text" id="ocr-merge-key" placeholder="Control, Alt, Shift..."> <label for="ocr-delete-key">Delete Modifier Key:</label><input type="text" id="ocr-delete-key" placeholder="Control, Alt, Shift..."> <label for="ocr-text-orientation">Text Orientation:</label><select id="ocr-text-orientation"><option value="smart">Smart</option><option value="serverAngle">Server Angle</option><option value="forceHorizontal">Horizontal</option><option value="forceVertical">Vertical</option></select> <label for="ocr-font-multiplier-horizontal">H. Font Multiplier:</label><input type="number" id="ocr-font-multiplier-horizontal" min="0.1" max="5" step="0.1"> <label for="ocr-font-multiplier-vertical">V. Font Multiplier:</label><input type="number" id="ocr-font-multiplier-vertical" min="0.1" max="5" step="0.1"> <label for="ocr-bounding-box-adjustment-input">Box Adjustment (px):</label><input type="number" id="ocr-bounding-box-adjustment-input" min="0" max="100" step="1"> </div><div class="gemini-ocr-settings-grid full-width"><label><input type="checkbox" id="gemini-ocr-solo-hover-mode"> Only show hovered box</label></div> <h3>Advanced</h3><div class="gemini-ocr-settings-grid full-width"><label><input type="checkbox" id="gemini-ocr-debug-mode"> Debug Mode</label></div> <div class="gemini-ocr-settings-grid full-width"><label for="gemini-ocr-sites-config">Site Configurations (URL; OverflowFix; Containers...)</label><textarea id="gemini-ocr-sites-config" rows="6" placeholder="127.0.0.1; .overflow-fix; .container1; .container2\n"></textarea></div> </div> <div class="gemini-ocr-modal-footer"> <button id="gemini-ocr-purge-cache-btn" style="background-color: #c0392b;" title="Deletes all entries from the server's OCR cache file.">Purge Server Cache</button> <button id="gemini-ocr-batch-chapter-btn" style="background-color: #3498db;" title="Queues the current chapter on the server for background pre-processing.">Pre-process Chapter</button> <button id="gemini-ocr-debug-btn" style="background-color: #777;">Debug</button> <button id="gemini-ocr-close-btn" style="background-color: #555;">Close</button> <button id="gemini-ocr-save-btn" style="background-color: #3ad602;">Save & Reload</button> </div> </div> <div id="gemini-ocr-debug-modal" class="gemini-ocr-modal is-hidden"><div class="gemini-ocr-modal-header"><h2>Debug Log</h2></div><div class="gemini-ocr-modal-content"><textarea id="gemini-ocr-debug-log" readonly style="width:100%; height: 100%; resize:none;"></textarea></div><div class="gemini-ocr-modal-footer"><button id="gemini-ocr-close-debug-btn" style="background-color: #555;">Close</button></div></div> `);
    }

    function bindUIEvents() {
        Object.assign(UI, {
            settingsButton: document.getElementById('gemini-ocr-settings-button'),
            settingsModal: document.getElementById('gemini-ocr-settings-modal'),
            globalAnkiButton: document.getElementById('gemini-ocr-global-anki-export-btn'),
            debugModal: document.getElementById('gemini-ocr-debug-modal'),
            serverUrlInput: document.getElementById('gemini-ocr-server-url'),
            imageServerUserInput: document.getElementById('gemini-image-server-user'),
            imageServerPasswordInput: document.getElementById('gemini-image-server-password'),
            ankiUrlInput: document.getElementById('gemini-ocr-anki-url'),
            ankiFieldInput: document.getElementById('gemini-ocr-anki-field'),
            debugModeCheckbox: document.getElementById('gemini-ocr-debug-mode'),
            soloHoverCheckbox: document.getElementById('gemini-ocr-solo-hover-mode'),
            interactionModeSelect: document.getElementById('ocr-interaction-mode'),
            dimmedOpacityInput: document.getElementById('ocr-dimmed-opacity'),
            textOrientationSelect: document.getElementById('ocr-text-orientation'),
            colorThemeSelect: document.getElementById('ocr-color-theme'),
            mergeKeyInput: document.getElementById('ocr-merge-key'),
            deleteKeyInput: document.getElementById('ocr-delete-key'),
            fontMultiplierHorizontalInput: document.getElementById('ocr-font-multiplier-horizontal'),
            fontMultiplierVerticalInput: document.getElementById('ocr-font-multiplier-vertical'),
            boundingBoxAdjustmentInput: document.getElementById('ocr-bounding-box-adjustment-input'),
            focusScaleMultiplierInput: document.getElementById('ocr-focus-scale-multiplier'),
            sitesConfigTextarea: document.getElementById('gemini-ocr-sites-config'),
            statusDiv: document.getElementById('gemini-ocr-server-status'),
            debugLogTextarea: document.getElementById('gemini-ocr-debug-log'),
            saveBtn: document.getElementById('gemini-ocr-save-btn'),
            closeBtn: document.getElementById('gemini-ocr-close-btn'),
            debugBtn: document.getElementById('gemini-ocr-debug-btn'),
            closeDebugBtn: document.getElementById('gemini-ocr-close-debug-btn'),
            batchChapterBtn: document.getElementById('gemini-ocr-batch-chapter-btn'),
            purgeCacheBtn: document.getElementById('gemini-ocr-purge-cache-btn'),
        });
        UI.settingsButton.addEventListener('click', () => UI.settingsModal.classList.toggle('is-hidden'));
        UI.globalAnkiButton.addEventListener('click', async () => {
            if (!activeImageForExport) {
                alert("Please hover over an image to select it for export.");
                return;
            }
            const btn = UI.globalAnkiButton;
            btn.textContent = '…';
            btn.disabled = true;
            const success = await exportImageToAnki(activeImageForExport);
            if (success) {
                btn.textContent = '✓';
                btn.style.backgroundColor = '#27ae60';
            } else {
                btn.textContent = '✖';
                btn.style.backgroundColor = '#c0392b';
            }
            setTimeout(() => {
                btn.textContent = '✚';
                btn.style.backgroundColor = '';
                btn.disabled = false;
            }, 2000);
        });
        UI.globalAnkiButton.addEventListener('mouseenter', () => clearTimeout(hideButtonTimer));
        UI.globalAnkiButton.addEventListener('mouseleave', () => {
            hideButtonTimer = setTimeout(() => {
                UI.globalAnkiButton.classList.add('is-hidden');
                activeImageForExport = null;
            }, 2350);
        });
        UI.statusDiv.addEventListener('click', checkServerStatus);
        UI.closeBtn.addEventListener('click', () => UI.settingsModal.classList.add('is-hidden'));
        UI.debugBtn.addEventListener('click', () => {
            UI.debugLogTextarea.value = debugLog.join('\n');
            UI.debugModal.classList.remove('is-hidden');
            UI.debugLogTextarea.scrollTop = UI.debugLogTextarea.scrollHeight;
        });
        UI.closeDebugBtn.addEventListener('click', () => UI.debugModal.classList.add('is-hidden'));
        UI.colorThemeSelect.addEventListener('change', () => {
            document.documentElement.style.setProperty('--modal-header-color', COLOR_THEMES[UI.colorThemeSelect.value].main + '1)');
        });
        UI.batchChapterBtn.addEventListener('click', batchProcessCurrentChapterFromURL);
        UI.purgeCacheBtn.addEventListener('click', purgeServerCache);
        UI.saveBtn.addEventListener('click', async () => {
            const newSettings = {
                ocrServerUrl: UI.serverUrlInput.value.trim(),
                imageServerUser: UI.imageServerUserInput.value.trim(),
                imageServerPassword: UI.imageServerPasswordInput.value,
                ankiConnectUrl: UI.ankiUrlInput.value.trim(),
                ankiImageField: UI.ankiFieldInput.value.trim(),
                debugMode: UI.debugModeCheckbox.checked,
                soloHoverMode: UI.soloHoverCheckbox.checked,
                interactionMode: UI.interactionModeSelect.value,
                textOrientation: UI.textOrientationSelect.value,
                colorTheme: UI.colorThemeSelect.value,
                mergeModifierKey: UI.mergeKeyInput.value.trim(),
                deleteModifierKey: UI.deleteKeyInput.value.trim(),
                dimmedOpacity: (parseInt(UI.dimmedOpacityInput.value, 10) || 30) / 100,
                fontMultiplierHorizontal: parseFloat(UI.fontMultiplierHorizontalInput.value) || 1.0,
                fontMultiplierVertical: parseFloat(UI.fontMultiplierVerticalInput.value) || 1.0,
                boundingBoxAdjustment: parseInt(UI.boundingBoxAdjustmentInput.value, 10) || 0,
                focusScaleMultiplier: parseFloat(UI.focusScaleMultiplierInput.value) || 1.1,
                sites: UI.sitesConfigTextarea.value.split('\n').filter(line => line.trim()).map(line => {
                    const parts = line.split(';').map(s => s.trim());
                    return {
                        urlPattern: parts[0] || '',
                        overflowFixSelector: parts[1] || '',
                        imageContainerSelectors: parts.slice(2).filter(s => s)
                    };
                })
            };
            try {
                await GM_setValue(SETTINGS_KEY, JSON.stringify(newSettings));
                alert('Settings Saved. The page will now reload.');
                window.location.reload();
            } catch (e) {
                logDebug(`Failed to save settings: ${e.message}`);
                alert(`Error: Could not save settings.`);
            }
        });
        document.addEventListener('ocr-log-update', () => {
            if (UI.debugModal && !UI.debugModal.classList.contains('is-hidden')) {
                UI.debugLogTextarea.value = debugLog.join('\n');
                UI.debugLogTextarea.scrollTop = UI.debugLogTextarea.scrollHeight;
            }
        });
    }

    function checkServerStatus() {
        const serverUrl = UI.serverUrlInput.value.trim();
        if (!serverUrl) return;
        UI.statusDiv.className = 'status-checking';
        UI.statusDiv.textContent = 'Checking...';
        GM_xmlhttpRequest({
            method: 'GET',
            url: serverUrl,
            timeout: 5000,
            onload: (res) => {
                try {
                    const data = JSON.parse(res.responseText);
                    if (data.status === 'running') {
                        UI.statusDiv.className = 'status-ok';
                        const jobs = data.active_preprocess_jobs !== undefined ? data.active_preprocess_jobs : 'N/A';
                        UI.statusDiv.textContent = `Connected (Cache: ${data.items_in_cache} | Active Jobs: ${jobs})`;
                    } else {
                        UI.statusDiv.className = 'status-error';
                        UI.statusDiv.textContent = 'Server Unresponsive';
                    }
                } catch (e) {
                    UI.statusDiv.className = 'status-error';
                    UI.statusDiv.textContent = 'Invalid Response';
                }
            },
            onerror: () => {
                UI.statusDiv.className = 'status-error';
                UI.statusDiv.textContent = 'Connection Failed';
            },
            ontimeout: () => {
                UI.statusDiv.className = 'status-error';
                UI.statusDiv.textContent = 'Timed Out';
            }
        });
    }

    function purgeServerCache() {
        if (!confirm("Are you sure you want to permanently delete all items from the server's OCR cache?")) return;
        const btn = UI.purgeCacheBtn;
        const originalText = btn.textContent;
        btn.disabled = true;
        btn.textContent = 'Purging...';
        GM_xmlhttpRequest({
            method: 'POST',
            url: `${settings.ocrServerUrl}/purge-cache`,
            timeout: 10000,
            onload: (res) => {
                try {
                    const data = JSON.parse(res.responseText);
                    alert(data.message || data.error);
                    checkServerStatus();
                } catch (e) {
                    alert('Failed to parse server response.');
                }
            },
            onerror: () => alert('Failed to connect to server to purge cache.'),
            ontimeout: () => alert('Request to purge cache timed out.'),
            onloadend: () => {
                btn.disabled = false;
                btn.textContent = originalText;
            }
        });
    }

    function createMeasurementSpan() {
        if (measurementSpan) return;
        measurementSpan = document.createElement('span');
        measurementSpan.style.cssText = `position:fixed!important;visibility:hidden!important;height:auto!important;width:auto!important;white-space:nowrap!important;z-index:-1!important;top:-9999px;left:-9999px;padding:0!important;border:0!important;margin:0!important;`;
        document.body.appendChild(measurementSpan);
    }

    // --- Global Event Handlers for Modifier Keys ---
    function handleModifierKeyDown(e) {
        const mergeKey = settings.mergeModifierKey.toLowerCase();
        const deleteKey = settings.deleteModifierKey.toLowerCase();
        const key = e.key.toLowerCase();
        if (key === mergeKey || key === deleteKey) {
            document.body.classList.add('ocr-edit-mode-active');
        }
    }

    function handleModifierKeyUp(e) {
        const mergeKey = settings.mergeModifierKey.toLowerCase();
        const deleteKey = settings.deleteModifierKey.toLowerCase();
        const key = e.key.toLowerCase();
        if (key === mergeKey || key === deleteKey) {
            document.body.classList.remove('ocr-edit-mode-active');
        }
    }

    function handleWindowBlur() {
        document.body.classList.remove('ocr-edit-mode-active');
    }

    async function init() {
        const loadedSettings = await GM_getValue(SETTINGS_KEY);
        if (loadedSettings) {
            try {
                settings = {
                    ...settings,
                    ...JSON.parse(loadedSettings)
                };
            } catch (e) {
                logDebug("Could not parse saved settings. Using defaults.");
            }
        }
        createUI();
        bindUIEvents();
        applyStyles();
        createMeasurementSpan();
        logDebug("Initializing HYBRID render engine with Hotkey Editor.");
        resizeObserver = new ResizeObserver(handleResize);
        intersectionObserver = new IntersectionObserver(handleIntersection, {
            rootMargin: '100px 0px'
        });
        setInterval(periodicCleanup, 5000);
        setInterval(manageScrollFix, 500);

        window.addEventListener('keydown', handleModifierKeyDown);
        window.addEventListener('keyup', handleModifierKeyUp);
        window.addEventListener('blur', handleWindowBlur);

        UI.serverUrlInput.value = settings.ocrServerUrl;
        UI.imageServerUserInput.value = settings.imageServerUser || '';
        UI.imageServerPasswordInput.value = settings.imageServerPassword || '';
        UI.ankiUrlInput.value = settings.ankiConnectUrl;
        UI.ankiFieldInput.value = settings.ankiImageField;
        UI.debugModeCheckbox.checked = settings.debugMode;
        UI.soloHoverCheckbox.checked = settings.soloHoverMode;
        UI.interactionModeSelect.value = settings.interactionMode;
        UI.textOrientationSelect.value = settings.textOrientation;
        UI.colorThemeSelect.value = settings.colorTheme;
        UI.mergeKeyInput.value = settings.mergeModifierKey;
        UI.deleteKeyInput.value = settings.deleteModifierKey;
        UI.dimmedOpacityInput.value = settings.dimmedOpacity * 100;
        UI.fontMultiplierHorizontalInput.value = settings.fontMultiplierHorizontal;
        UI.fontMultiplierVerticalInput.value = settings.fontMultiplierVertical;
        UI.boundingBoxAdjustmentInput.value = settings.boundingBoxAdjustment;
        UI.focusScaleMultiplierInput.value = settings.focusScaleMultiplier;
        UI.sitesConfigTextarea.value = settings.sites.map(s => [s.urlPattern, s.overflowFixSelector, ...(s.imageContainerSelectors || [])].join('; ')).join('\n');
        activateScanner();
        observeChapters();
    }
    init().catch(e => console.error(`[OCR Hybrid] Fatal Initialization Error: ${e.message}`));
})();
