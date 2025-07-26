// ==UserScript==
// @name         Automatic Content OCR (v21.6.46 - Bugfix & Opacity Control)
// @namespace    http://tampermonkey.net/
// @version      21.6.46
// @description  Adds user-controlled opacity for dimmed boxes, improves centering, and adds proximity mode.
// @author       1Selxo 
// @match        *://127.0.0.1*/*
// @grant        GM_setValue
// @grant        GM_getValue
// @grant        GM_addStyle
// @grant        GM_xmlhttpRequest
// @connect      127.0.0.1
// @connect      localhost
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
                'div.muiltr-masn8', 'div.muiltr-79elbk', 'div.muiltr-u43rde', 'div.muiltr-1r1or1s',
                'div.muiltr-18sieki', 'div.muiltr-cns6dc', '.MuiBox-root.muiltr-1noqzsz'
            ],
            overflowFixSelector: '.MuiBox-root.muiltr-13djdhf'
        }],
        debugMode: true,
        textOrientation: 'smart',
        interactionMode: 'hover',
        proximityRadius: 150,
        dimmedOpacity: 0.3,
        colorTheme: 'deepblue',
        fontMultiplierHorizontal: 1.0,
        fontMultiplierVertical: 1.0
    };
    let debugLog = [];
    const SETTINGS_KEY = 'gemini_ocr_settings_v21_6_final_credential_forward';
    const ocrDataCache = new WeakMap();
    const managedElements = new Map();
    const managedContainers = new Map();
    const attachedAttributeObservers = new WeakMap();
    let activeSiteConfig = null;
    let overlayUpdateRunning = false;
    let measurementSpan = null;
    const UI = {};
    let activeImageForExport = null;
    let hideButtonTimer = null;

    // --- Color Themes ---
    const COLOR_THEMES = {
        deepblue: { main: 'rgba(0,191,255,',  text: '#FFFFFF', highlightText: '#000000' },
        red:      { main: 'rgba(255, 71, 87,',   text: '#FFFFFF', highlightText: '#000000' },
        green:    { main: 'rgba(46, 204, 113,',  text: '#FFFFFF', highlightText: '#000000' },
        orange:   { main: 'rgba(243, 156, 18,',  text: '#FFFFFF', highlightText: '#000000' },
        purple:   { main: 'rgba(155, 89, 182,',  text: '#FFFFFF', highlightText: '#000000' },
        turquoise:{ main: 'rgba(26, 188, 156,', text: '#FFFFFF', highlightText: '#000000' },
        pink:     { main: 'rgba(232, 67, 147,',  text: '#FFFFFF', highlightText: '#000000' },
        grey:     { main: 'rgba(149, 165, 166,', text: '#FFFFFF', highlightText: '#000000' }
    };

    // --- Logging ---
    const logDebug = (message) => {
        if (!settings.debugMode) return;
        const timestamp = new Date().toLocaleTimeString();
        const logEntry = `[${timestamp}] ${message}`;
        console.log(`[OCR v21.6.46] ${logEntry}`);
        debugLog.push(logEntry);
        document.dispatchEvent(new CustomEvent('ocr-log-update'));
    };

    // --- Core Observation Logic ---
    const imageObserver = new MutationObserver((mutations) => {
        for (const mutation of mutations) for (const node of mutation.addedNodes) if (node.nodeType === 1) {
            if (node.tagName === 'IMG') observeImageForSrcChange(node);
            else node.querySelectorAll('img').forEach(observeImageForSrcChange);
        }
    });
    function manageContainer(container) {
        if (managedContainers.has(container)) return;
        logDebug(`New container found. Managing: ${container.className}`);
        container.querySelectorAll('img').forEach(observeImageForSrcChange);
        imageObserver.observe(container, { childList: true, subtree: true });
        managedContainers.set(container, true);
    }
    const containerObserver = new MutationObserver((mutations) => {
        if (!activeSiteConfig) return;
        const selectorQuery = activeSiteConfig.imageContainerSelectors.join(', ');
        for (const mutation of mutations) for (const node of mutation.addedNodes) if (node.nodeType === 1) {
            if (node.matches(selectorQuery)) manageContainer(node);
            else node.querySelectorAll(selectorQuery).forEach(manageContainer);
        }
    });
    function activateScanner() {
        logDebug("Activating scanner...");
        activeSiteConfig = settings.sites.find(site => window.location.href.includes(site.urlPattern));
        if (!activeSiteConfig?.imageContainerSelectors?.length) return logDebug(`No matching site config for URL: ${window.location.href}.`);
        const selectorQuery = activeSiteConfig.imageContainerSelectors.join(', ');
        document.querySelectorAll(selectorQuery).forEach(manageContainer);
        containerObserver.observe(document.body, { childList: true, subtree: true });
        logDebug("Main container observer is active.");
    }

    // --- Image Processing ---
    function observeImageForSrcChange(img) {
        const processTheImage = (src) => {
            if (src?.includes('/api/v1/manga/')) {
                img.crossOrigin = "anonymous";
                if (img.complete && img.naturalHeight > 0) { processImage(img); }
                else { img.addEventListener('load', () => processImage(img), { once: true }); }
                return true;
            }
            return false;
        };
        if (processTheImage(img.src)) return;
        if (attachedAttributeObservers.has(img)) return;
        const attributeObserver = new MutationObserver((mutations) => {
            for (const mutation of mutations) if (mutation.attributeName === 'src' && processTheImage(img.src)) {
                attributeObserver.disconnect(); attachedAttributeObservers.delete(img); break;
            }
        });
        attributeObserver.observe(img, { attributes: true });
        attachedAttributeObservers.set(img, attributeObserver);
    }

    function processImage(img) {
        if (ocrDataCache.get(img) === 'pending') return;
        if (managedElements.has(img)) { managedElements.get(img).overlay.remove(); managedElements.delete(img); }
        const sourceUrl = img.src;
        logDebug(`Requesting OCR for ...${sourceUrl.slice(-30)}`);
        ocrDataCache.set(img, 'pending');
        let ocrRequestUrl = `${settings.ocrServerUrl}/ocr?url=${encodeURIComponent(sourceUrl)}`;
        if (settings.imageServerUser) {
            logDebug("Forwarding image server credentials to OCR server.");
            ocrRequestUrl += `&user=${encodeURIComponent(settings.imageServerUser)}&pass=${encodeURIComponent(settings.imageServerPassword)}`;
        }
        GM_xmlhttpRequest({
            method: 'GET', url: ocrRequestUrl, timeout: 30000,
            onload: (res) => {
                try {
                    const data = JSON.parse(res.responseText); if (data.error) throw new Error(data.error);
                    ocrDataCache.set(img, data); logDebug(`OCR success for ...${sourceUrl.slice(-30)}`); displayOcrResults(img);
                } catch (e) { logDebug(`OCR Error: ${e.message}`); ocrDataCache.delete(img); }
            },
            onerror: (res) => { logDebug(`Connection error. Status: ${res.status}`); ocrDataCache.delete(img); },
            ontimeout: () => { logDebug(`Request timed out.`); ocrDataCache.delete(img); }
        });
    }

    // --- OVERLAY & UPDATE ENGINE ---
    function displayOcrResults(targetImg) {
        const data = ocrDataCache.get(targetImg);
        if (!data || data === 'pending' || managedElements.has(targetImg)) return;
        data.sort((a, b) => {
            const a_y = a.tightBoundingBox.y, b_y = b.tightBoundingBox.y, a_x = a.tightBoundingBox.x, b_x = b.tightBoundingBox.x, ROW_TOLERANCE = 0.05;
            if (Math.abs(a_y - b_y) < ROW_TOLERANCE) return b_x - a_x; else return a_y - b_y;
        });
        const overlay = document.createElement('div');
        overlay.className = `gemini-ocr-decoupled-overlay is-hidden interaction-mode-${settings.interactionMode}`;
        const fragment = document.createDocumentFragment(), imgRect = targetImg.getBoundingClientRect();
        data.forEach((item) => {
            const ocrBox = document.createElement('div'); ocrBox.className = 'gemini-ocr-text-box';
            ocrBox.textContent = item.text; ocrBox.dataset.ocrWidth = item.tightBoundingBox.width; ocrBox.dataset.ocrHeight = item.tightBoundingBox.height;
            const pixelWidth = item.tightBoundingBox.width * imgRect.width, pixelHeight = item.tightBoundingBox.height * imgRect.height;
            let isVertical = (settings.textOrientation === 'forceVertical') || (settings.textOrientation === 'smart' && (pixelHeight > pixelWidth || item.orientation === 90)) || (settings.textOrientation === 'serverAngle' && item.orientation === 90);
            if (isVertical) ocrBox.classList.add('gemini-ocr-text-vertical');
            Object.assign(ocrBox.style, { left: `${item.tightBoundingBox.x*100}%`, top: `${item.tightBoundingBox.y*100}%`, width: `${item.tightBoundingBox.width*100}%`, height: `${item.tightBoundingBox.height*100}%` });
            fragment.appendChild(ocrBox);
        });
        overlay.appendChild(fragment); document.body.appendChild(overlay);
        const state = { overlay, hideTimeout: null, lastWidth: 0, lastHeight: 0 };
        managedElements.set(targetImg, state);
        logDebug(`Created overlay for ...${targetImg.src.slice(-30)}`);
        const show = () => { clearTimeout(hideButtonTimer); clearTimeout(state.hideTimeout); overlay.classList.remove('is-hidden'); overlay.classList.add('is-focused'); UI.globalAnkiButton?.classList.remove('is-hidden'); activeImageForExport = targetImg; };
        const hide = () => { state.hideTimeout = setTimeout(() => { overlay.classList.add('is-hidden'); overlay.classList.remove('is-focused'); }, 300); hideButtonTimer = setTimeout(() => { UI.globalAnkiButton?.classList.add('is-hidden'); if (activeImageForExport === targetImg) activeImageForExport = null; }, 2350); };
        [targetImg, overlay].forEach(el => { el.addEventListener('mouseenter', show); el.addEventListener('mouseleave', hide); });
        if (settings.interactionMode === 'click') {
            overlay.addEventListener('click', (e) => {
                const clickedBox = e.target.closest('.gemini-ocr-text-box');
                overlay.querySelectorAll('.manual-highlight').forEach(b => b.classList.remove('manual-highlight'));
                if (clickedBox) { clickedBox.classList.add('manual-highlight'); overlay.classList.add('has-manual-highlight'); }
                else { overlay.classList.remove('has-manual-highlight'); }
                e.stopPropagation();
            });
        } else if (settings.interactionMode === 'proximity') {
            const textBoxes = Array.from(overlay.querySelectorAll('.gemini-ocr-text-box')); let frameRequest = null;
            overlay.addEventListener('mousemove', (e) => {
                if (frameRequest) return;
                frameRequest = requestAnimationFrame(() => {
                    const overlayRect = overlay.getBoundingClientRect(), mouseX = e.clientX - overlayRect.left, mouseY = e.clientY - overlayRect.top;
                    textBoxes.forEach(box => {
                        const boxCenterX = box.offsetLeft + box.offsetWidth / 2, boxCenterY = box.offsetTop + box.offsetHeight / 2;
                        if (Math.hypot(boxCenterX - mouseX, boxCenterY - mouseY) < settings.proximityRadius) box.classList.add('is-near');
                        else box.classList.remove('is-near');
                    });
                    frameRequest = null;
                });
            });
            overlay.addEventListener('mouseleave', () => { if (frameRequest) cancelAnimationFrame(frameRequest); textBoxes.forEach(box => box.classList.remove('is-near')); });
        }
        if (!overlayUpdateRunning) requestAnimationFrame(updateAllOverlays);
    }

    // --- Font Calculation ---
    function calculateAndApplyFontSizes(overlay, imgRect) {
        if (!measurementSpan) return; const textBoxes = overlay.querySelectorAll('.gemini-ocr-text-box'); if (textBoxes.length === 0) return;
        const baseStyle = getComputedStyle(textBoxes[0]); Object.assign(measurementSpan.style, { fontFamily: baseStyle.fontFamily, fontWeight: baseStyle.fontWeight, letterSpacing: baseStyle.letterSpacing, lineHeight: '1', });
        textBoxes.forEach(box => {
            const text = box.textContent || ''; if (!text) return;
            const availableWidth = parseFloat(box.dataset.ocrWidth) * imgRect.width - 8, availableHeight = parseFloat(box.dataset.ocrHeight) * imgRect.height - 8;
            if (availableWidth <= 0 || availableHeight <= 0) return; let bestSize = 8, multiplier; measurementSpan.textContent = text;
            if (box.classList.contains('gemini-ocr-text-vertical')) {
                measurementSpan.style.writingMode = 'vertical-rl'; measurementSpan.style.textOrientation = 'upright';
                let low = 8, high = 150;
                while (low <= high) { const mid = Math.floor((low + high) / 2); if (mid <= 0) break; measurementSpan.style.fontSize = `${mid}px`; if ((measurementSpan.offsetWidth <= availableHeight) && (measurementSpan.offsetHeight <= availableWidth)) { bestSize = mid; low = mid + 1; } else { high = mid - 1; } }
                measurementSpan.style.writingMode = ''; measurementSpan.style.textOrientation = ''; multiplier = settings.fontMultiplierVertical;
            } else {
                let low = 8, high = 150; box.style.whiteSpace = 'nowrap';
                while (low <= high) { const mid = Math.floor((low + high) / 2); if (mid <= 0) break; measurementSpan.style.fontSize = `${mid}px`; if ((measurementSpan.offsetWidth <= availableWidth) && (measurementSpan.offsetHeight <= availableHeight)) { bestSize = mid; low = mid + 1; } else { high = mid - 1; } }
                box.style.whiteSpace = 'normal'; multiplier = settings.fontMultiplierHorizontal;
            }
            box.style.fontSize = `${bestSize * multiplier}px`;
        });
    }

    // --- Main Update Loop ---
    function updateAllOverlays() {
        overlayUpdateRunning = true;
        try {
            if (activeSiteConfig?.overflowFixSelector) { const el = document.querySelector(activeSiteConfig.overflowFixSelector); if (el && el.style.overflow !== 'visible') el.style.overflow = 'visible'; }
            const elementsToDelete = [];
            for (const [img, state] of managedElements.entries()) {
                if (!document.body.contains(img) || !document.body.contains(state.overlay)) { elementsToDelete.push(img); continue; }
                const rect = img.getBoundingClientRect(); if (rect.width === 0 || rect.height === 0) { if (!state.overlay.classList.contains('is-hidden')) state.overlay.classList.add('is-hidden'); continue; }
                Object.assign(state.overlay.style, { top: `${rect.top + window.scrollY}px`, left: `${rect.left + window.scrollX}px`, width: `${rect.width}px`, height: `${rect.height}px` });
                if (state.lastWidth !== rect.width || state.lastHeight !== rect.height) { logDebug(`Dimensions changed for ...${img.src.slice(-30)}. Recalculating fonts.`); calculateAndApplyFontSizes(state.overlay, rect); state.lastWidth = rect.width; state.lastHeight = rect.height; }
            }
            elementsToDelete.forEach(img => { managedElements.get(img)?.overlay.remove(); managedElements.delete(img); logDebug(`Garbage collected overlay.`); });
        } catch (error) { logDebug(`Critical error in updateAllOverlays: ${error.message}`); }
        finally { overlayUpdateRunning = false; if (managedElements.size > 0) requestAnimationFrame(updateAllOverlays); }
    }

    // --- ANKI, UI, AND INITIALIZATION ---
    async function ankiConnectRequest(action, params = {}) {
        logDebug(`Anki-Connect: Firing action '${action}'`);
        return new Promise((resolve, reject) => GM_xmlhttpRequest({ method: 'POST', url: settings.ankiConnectUrl, data: JSON.stringify({ action, version: 6, params }), headers: { 'Content-Type': 'application/json; charset=UTF-8' }, timeout: 15000, onload: (res) => { try { const data = JSON.parse(res.responseText); if (data.error) reject(new Error(data.error)); else resolve(data.result); } catch (e) { reject(new Error('Failed to parse Anki-Connect response.')); } }, onerror: () => reject(new Error('Connection to Anki-Connect failed.')), ontimeout: () => reject(new Error('Anki-Connect request timed out.')) }));
    }
    async function exportImageToAnki(targetImg) {
        logDebug(`Anki Export: Starting screenshot...`); if (!settings.ankiImageField) { alert('Anki Image Field is not set in settings.'); return false; } if (!targetImg || !targetImg.complete || !targetImg.naturalHeight) { alert('Anki Export Failed: The selected image is not valid or fully loaded.'); return false; }
        try {
            const canvas = document.createElement('canvas'); canvas.width = targetImg.naturalWidth; canvas.height = targetImg.naturalHeight; const ctx = canvas.getContext('2d'); ctx.drawImage(targetImg, 0, 0); const base64data = canvas.toDataURL('image/png').split(',')[1]; if (!base64data) throw new Error("Canvas toDataURL failed.");
            const filename = `screenshot_${Date.now()}.png`; await ankiConnectRequest('storeMediaFile', { filename, data: base64data }); logDebug(`Anki Export: Image stored as '${filename}'`);
            const notes = await ankiConnectRequest('findNotes', { query: 'added:1' }); if (!notes || notes.length === 0) throw new Error('No recently added cards found. Create a card first.'); const lastNoteId = notes.sort((a, b) => b - a)[0]; logDebug(`Anki Export: Found last card with ID ${lastNoteId}`);
            await ankiConnectRequest('updateNoteFields', { note: { id: lastNoteId, fields: { [settings.ankiImageField]: `<img src="${filename}">` } } }); logDebug(`Anki Export: Successfully updated note ${lastNoteId}.`); return true;
        } catch (error) { logDebug(`Anki Export Error: ${error.message}`); if (error.message.includes("SecurityError") || error.message.includes("tainted")) { alert(`Anki Export Failed: Canvas security error due to CORS policy.`); } else { alert(`Anki Export Failed: ${error.message}`); } return false; }
    }
    function manageScrollFix() { const urlPattern = '/manga/', shouldBeActive = window.location.href.includes(urlPattern), isActive = document.documentElement.classList.contains('ocr-scroll-fix-active'); if (shouldBeActive && !isActive) document.documentElement.classList.add('ocr-scroll-fix-active'); else if (!shouldBeActive && isActive) document.documentElement.classList.remove('ocr-scroll-fix-active'); }

    function applyStyles() {
        const theme = COLOR_THEMES[settings.colorTheme] || COLOR_THEMES.deepblue;
        const cssVars = `:root {
            --ocr-bg-color: rgba(10,25,40,0.85); --ocr-border-color: ${theme.main}0.6);
            --ocr-border-color-dim: ${theme.main}0.3); --ocr-border-color-hover: ${theme.main}0.8);
            --ocr-text-color: ${theme.text}; --ocr-highlight-bg-color: ${theme.main}0.9);
            --ocr-highlight-border-color: rgba(255,255,255,0.9); --ocr-highlight-text-color: ${theme.highlightText};
            --ocr-highlight-shadow: 0 0 10px ${theme.main}0.5); --ocr-highlight-inset-shadow: inset 0 0 0 2px white;
            --modal-header-color: ${theme.main}1);
            --ocr-dimmed-opacity: ${settings.dimmedOpacity};
        }`;
        let styleTag = document.getElementById('gemini-ocr-dynamic-styles');
        if (!styleTag) { styleTag = document.createElement('style'); styleTag.id = 'gemini-ocr-dynamic-styles'; document.head.appendChild(styleTag); }
        styleTag.textContent = cssVars;
        logDebug(`Applied theme ${settings.colorTheme} and styles (Dim Opacity: ${settings.dimmedOpacity})`);
    }

    function createUI() {
        GM_addStyle(`
            html.ocr-scroll-fix-active { overflow: hidden !important; } html.ocr-scroll-fix-active body { overflow-y: auto !important; overflow-x: hidden !important; }
            .gemini-ocr-decoupled-overlay { position: absolute; z-index: 9998; pointer-events: none !important; transition: opacity 0.15s, visibility 0.15s; }
            .gemini-ocr-decoupled-overlay.is-hidden { opacity: 0; visibility: hidden; }
            .gemini-ocr-text-box { display: flex; justify-content: center; align-items: center; text-align: center; position: absolute; box-sizing: border-box; border-radius: 4px; user-select: text; cursor: pointer; background: var(--ocr-bg-color); border: 2px solid var(--ocr-border-color); color: var(--ocr-text-color); text-shadow: 1px 1px 2px rgba(0,0,0,0.8); backdrop-filter: blur(2px); transition: all 0.2s ease-in-out; pointer-events: auto !important; overflow: hidden; padding: 4px; }
            .gemini-ocr-text-vertical { writing-mode: vertical-rl !important; text-orientation: upright !important; }
            .gemini-ocr-text-box:not(.manual-highlight):not(.is-near) { transition: opacity 0.2s, background 0.2s, border-color 0.2s; }
            /* Highlighted Box State (applies to all modes) */
            .interaction-mode-hover.is-focused .gemini-ocr-text-box:hover, .interaction-mode-click.is-focused .manual-highlight, .interaction-mode-proximity.is-focused .is-near { overflow: visible; transform: scale(1.05); background: var(--ocr-highlight-bg-color); border-color: var(--ocr-highlight-border-color); color: var(--ocr-highlight-text-color); text-shadow: none; box-shadow: var(--ocr-highlight-shadow), var(--ocr-highlight-inset-shadow); z-index: 9999; opacity: 1; }
            /* Dimmed Box State (applies to all modes) */
            .interaction-mode-hover.is-focused:has(.gemini-ocr-text-box:hover) .gemini-ocr-text-box:not(:hover),
            .interaction-mode-click.is-focused.has-manual-highlight .gemini-ocr-text-box:not(.manual-highlight),
            .interaction-mode-proximity.is-focused .gemini-ocr-text-box:not(.is-near) { opacity: var(--ocr-dimmed-opacity); background: rgba(10,25,40,0.5); border-color: var(--ocr-border-color-dim); }
            /* Modal, Buttons etc. */
            #gemini-ocr-settings-button { position: fixed; bottom: 15px; right: 15px; z-index: 2147483647; background: #1A1D21; color: #EAEAEA; border: 1px solid #555; border-radius: 50%; width: 50px; height: 50px; font-size: 26px; cursor: pointer; display: flex; align-items: center; justify-content: center; box-shadow: 0 4px 12px rgba(0,0,0,0.5); user-select: none; }
            #gemini-ocr-global-anki-export-btn { position: fixed; bottom: 75px; right: 15px; z-index: 2147483646; background-color: #2ecc71; color: white; border: 1px solid white; border-radius: 50%; width: 50px; height: 50px; font-size: 30px; line-height: 50px; text-align: center; cursor: pointer; transition: all 0.2s ease-in-out; user-select: none; box-shadow: 0 4px 12px rgba(0,0,0,0.5); }
            #gemini-ocr-global-anki-export-btn:hover { background-color: #27ae60; transform: scale(1.1); } #gemini-ocr-global-anki-export-btn:disabled { background-color: #95a5a6; cursor: wait; transform: none; }
            #gemini-ocr-global-anki-export-btn.is-hidden { opacity: 0; visibility: hidden; pointer-events: none; transform: scale(0.5); }
            .gemini-ocr-modal { position: fixed; top: 50%; left: 50%; transform: translate(-50%, -50%); background-color: #1A1D21; border: 1px solid var(--modal-header-color); border-radius: 15px; z-index: 2147483647; color: #EAEAEA; font-family: sans-serif; box-shadow: 0 8px 32px 0 rgba(0,0,0,0.5); width: 600px; max-width: 90vw; max-height: 90vh; display: flex; flex-direction: column; }
            .gemini-ocr-modal.is-hidden { display: none; } .gemini-ocr-modal-header { padding: 20px 25px; border-bottom: 1px solid #444; } .gemini-ocr-modal-header h2 { margin: 0; color: var(--modal-header-color); }
            .gemini-ocr-modal-content { padding: 10px 25px; overflow-y: auto; flex-grow: 1; } .gemini-ocr-modal-footer { padding: 15px 25px; border-top: 1px solid #444; display: flex; justify-content: flex-end; gap: 10px; align-items: center; }
            .gemini-ocr-modal h3 { font-size: 1.1em; margin: 15px 0 10px 0; border-bottom: 1px solid #333; padding-bottom: 5px; color: var(--modal-header-color); }
            .gemini-ocr-settings-grid { display: grid; grid-template-columns: max-content 1fr; gap: 10px 15px; align-items: center; } .full-width { grid-column: 1 / -1; }
            .gemini-ocr-modal input, .gemini-ocr-modal textarea, .gemini-ocr-modal select { width: 100%; padding: 8px; box-sizing: border-box; font-family: monospace; background-color: #2a2a2e; border: 1px solid #555; border-radius: 5px; color: #EAEAEA; }
            .gemini-ocr-modal button { padding: 10px 18px; background-color: var(--modal-header-color); border: none; border-radius: 5px; color: #1A1D21; cursor: pointer; font-weight: bold; }
            #gemini-ocr-server-status { padding: 10px; border-radius: 5px; text-align: center; cursor: pointer; transition: background-color 0.3s; }
            #gemini-ocr-server-status.status-ok { background-color: #27ae60; } #gemini-ocr-server-status.status-error { background-color: #c0392b; } #gemini-ocr-server-status.status-checking { background-color: #3498db; }
        `);
        document.body.insertAdjacentHTML('beforeend', `
            <button id="gemini-ocr-global-anki-export-btn" class="is-hidden" title="Export Screenshot to Anki">✚</button>
            <button id="gemini-ocr-settings-button">⚙️</button>
            <div id="gemini-ocr-settings-modal" class="gemini-ocr-modal is-hidden">
                <div class="gemini-ocr-modal-header"><h2>Automatic Content OCR Settings</h2></div>
                <div class="gemini-ocr-modal-content">
                    <h3>OCR & Image Source</h3><div class="gemini-ocr-settings-grid full-width">
                        <label for="gemini-ocr-server-url">OCR Server URL:</label><input type="text" id="gemini-ocr-server-url">
                        <label for="gemini-image-server-user">Image Source Username:</label><input type="text" id="gemini-image-server-user" autocomplete="username" placeholder="Optional">
                        <label for="gemini-image-server-password">Image Source Password:</label><input type="password" id="gemini-image-server-password" autocomplete="current-password" placeholder="Optional">
                    </div>
                    <div id="gemini-ocr-server-status" class="full-width" style="margin-top: 10px;">Click to check server status</div>
                    <h3>Anki Integration</h3><div class="gemini-ocr-settings-grid">
                        <label for="gemini-ocr-anki-url">Anki-Connect URL:</label><input type="text" id="gemini-ocr-anki-url">
                        <label for="gemini-ocr-anki-field">Image Field Name:</label><input type="text" id="gemini-ocr-anki-field" placeholder="e.g., Image">
                    </div>
                    <h3>Interaction & Display</h3><div class="gemini-ocr-settings-grid">
                        <label for="ocr-color-theme">Color Theme:</label><select id="ocr-color-theme">${Object.keys(COLOR_THEMES).map(t=>`<option value="${t}">${t.charAt(0).toUpperCase()+t.slice(1)}</option>`).join('')}</select>
                        <label for="ocr-interaction-mode">Highlight Mode:</label><select id="ocr-interaction-mode"><option value="hover">On Hover</option><option value="click">On Click</option><option value="proximity">On Proximity</option></select>
                        <label for="ocr-dimmed-opacity">Dimmed Box Opacity (%):</label><input type="number" id="ocr-dimmed-opacity" min="0" max="100" step="5">
                        <label for="ocr-proximity-radius">Proximity Radius (px):</label><input type="number" id="ocr-proximity-radius" min="10" max="1000" step="10">
                        <label for="ocr-text-orientation">Text Orientation:</label><select id="ocr-text-orientation"><option value="smart">Smart</option><option value="serverAngle">Server Angle</option><option value="forceHorizontal">Horizontal</option><option value="forceVertical">Vertical</option></select>
                        <label for="ocr-font-multiplier-horizontal">H. Font Multiplier:</label><input type="number" id="ocr-font-multiplier-horizontal" min="0.1" max="5" step="0.1">
                        <label for="ocr-font-multiplier-vertical">V. Font Multiplier:</label><input type="number" id="ocr-font-multiplier-vertical" min="0.1" max="5" step="0.1">
                    </div>
                    <h3>Advanced</h3><div class="gemini-ocr-settings-grid full-width"><label><input type="checkbox" id="gemini-ocr-debug-mode"> Debug Mode</label></div>
                    <div class="gemini-ocr-settings-grid full-width"><label for="gemini-ocr-sites-config">Site Configurations (URL; OverflowFix; Containers...)</label><textarea id="gemini-ocr-sites-config" rows="6" placeholder="127.0.0.1; .overflow-fix; .container1; .container2\n"></textarea></div>
                </div>
                <div class="gemini-ocr-modal-footer"><button id="gemini-ocr-debug-btn" style="background-color: #777; margin-right: auto;">Debug</button><button id="gemini-ocr-close-btn" style="background-color: #555;">Close</button><button id="gemini-ocr-save-btn">Save & Reload</button></div>
            </div>
            <div id="gemini-ocr-debug-modal" class="gemini-ocr-modal is-hidden"><div class="gemini-ocr-modal-header"><h2>Debug Log</h2></div><div class="gemini-ocr-modal-content"><textarea id="gemini-ocr-debug-log" readonly style="width:100%; height: 100%; resize:none;"></textarea></div><div class="gemini-ocr-modal-footer"><button id="gemini-ocr-close-debug-btn" style="background-color: #555;">Close</button></div></div>
        `);
    }

    function bindUIEvents() {
        // BUGFIX: Reverted from broken shorthand to full, readable document.getElementById
        Object.assign(UI, {
            settingsButton: document.getElementById('gemini-ocr-settings-button'), settingsModal: document.getElementById('gemini-ocr-settings-modal'),
            globalAnkiButton: document.getElementById('gemini-ocr-global-anki-export-btn'), debugModal: document.getElementById('gemini-ocr-debug-modal'),
            serverUrlInput: document.getElementById('gemini-ocr-server-url'), imageServerUserInput: document.getElementById('gemini-image-server-user'),
            imageServerPasswordInput: document.getElementById('gemini-image-server-password'), ankiUrlInput: document.getElementById('gemini-ocr-anki-url'),
            ankiFieldInput: document.getElementById('gemini-ocr-anki-field'), debugModeCheckbox: document.getElementById('gemini-ocr-debug-mode'),
            interactionModeSelect: document.getElementById('ocr-interaction-mode'), proximityRadiusInput: document.getElementById('ocr-proximity-radius'),
            dimmedOpacityInput: document.getElementById('ocr-dimmed-opacity'), textOrientationSelect: document.getElementById('ocr-text-orientation'),
            colorThemeSelect: document.getElementById('ocr-color-theme'), fontMultiplierHorizontalInput: document.getElementById('ocr-font-multiplier-horizontal'),
            fontMultiplierVerticalInput: document.getElementById('ocr-font-multiplier-vertical'), sitesConfigTextarea: document.getElementById('gemini-ocr-sites-config'),
            statusDiv: document.getElementById('gemini-ocr-server-status'), debugLogTextarea: document.getElementById('gemini-ocr-debug-log'),
            saveBtn: document.getElementById('gemini-ocr-save-btn'), closeBtn: document.getElementById('gemini-ocr-close-btn'),
            debugBtn: document.getElementById('gemini-ocr-debug-btn'), closeDebugBtn: document.getElementById('gemini-ocr-close-debug-btn'),
        });

        UI.settingsButton.addEventListener('click', () => UI.settingsModal.classList.toggle('is-hidden'));
        UI.globalAnkiButton.addEventListener('click', async () => { if (!activeImageForExport) { alert("Please hover over an image to select it for export."); return; } const btn = UI.globalAnkiButton; btn.textContent = '…'; btn.disabled = true; const success = await exportImageToAnki(activeImageForExport); if (success) { btn.textContent = '✓'; btn.style.backgroundColor = '#27ae60'; } else { btn.textContent = '✖'; btn.style.backgroundColor = '#c0392b'; } setTimeout(() => { btn.textContent = '✚'; btn.style.backgroundColor = ''; btn.disabled = false; }, 2000); });
        UI.globalAnkiButton.addEventListener('mouseenter', () => clearTimeout(hideButtonTimer));
        UI.globalAnkiButton.addEventListener('mouseleave', () => { hideButtonTimer = setTimeout(() => { UI.globalAnkiButton.classList.add('is-hidden'); if(activeImageForExport) activeImageForExport = null; }, 2350); });
        UI.statusDiv.addEventListener('click', checkServerStatus);
        UI.closeBtn.addEventListener('click', () => UI.settingsModal.classList.add('is-hidden'));
        UI.debugBtn.addEventListener('click', () => { UI.debugLogTextarea.value = debugLog.join('\n'); UI.debugModal.classList.remove('is-hidden'); UI.debugLogTextarea.scrollTop = UI.debugLogTextarea.scrollHeight; });
        UI.closeDebugBtn.addEventListener('click', () => UI.debugModal.classList.add('is-hidden'));
        UI.colorThemeSelect.addEventListener('change', () => { document.documentElement.style.setProperty('--modal-header-color', COLOR_THEMES[UI.colorThemeSelect.value].main + '1)'); });
        UI.interactionModeSelect.addEventListener('change', () => { const isProximity = UI.interactionModeSelect.value === 'proximity'; const radiusEl = UI.proximityRadiusInput.closest('label').parentElement; if (radiusEl) radiusEl.style.display = isProximity ? '' : 'none'; });
        UI.saveBtn.addEventListener('click', async () => {
            const newSettings = {
                ocrServerUrl: UI.serverUrlInput.value.trim(), imageServerUser: UI.imageServerUserInput.value.trim(), imageServerPassword: UI.imageServerPasswordInput.value,
                ankiConnectUrl: UI.ankiUrlInput.value.trim(), ankiImageField: UI.ankiFieldInput.value.trim(), debugMode: UI.debugModeCheckbox.checked,
                interactionMode: UI.interactionModeSelect.value, textOrientation: UI.textOrientationSelect.value, colorTheme: UI.colorThemeSelect.value,
                proximityRadius: parseInt(UI.proximityRadiusInput.value, 10) || 150,
                dimmedOpacity: (parseInt(UI.dimmedOpacityInput.value, 10) || 30) / 100,
                fontMultiplierHorizontal: parseFloat(UI.fontMultiplierHorizontalInput.value) || 1.0, fontMultiplierVertical: parseFloat(UI.fontMultiplierVerticalInput.value) || 1.0,
                sites: UI.sitesConfigTextarea.value.split('\n').filter(line => line.trim()).map(line => { const parts = line.split(';').map(s => s.trim()); return { urlPattern: parts[0] || '', overflowFixSelector: parts[1] || '', imageContainerSelectors: parts.slice(2).filter(s => s) }; })
            };
            try { await GM_setValue(SETTINGS_KEY, JSON.stringify(newSettings)); alert('Settings Saved. The page will now reload.'); window.location.reload(); }
            catch (e) { logDebug(`Failed to save settings: ${e.message}`); alert(`Error: Could not save settings.`); }
        });
        document.addEventListener('ocr-log-update', () => { if(UI.debugModal && !UI.debugModal.classList.contains('is-hidden')) { UI.debugLogTextarea.value = debugLog.join('\n'); UI.debugLogTextarea.scrollTop = UI.debugLogTextarea.scrollHeight; }});
    }

    function checkServerStatus() { const serverUrl = UI.serverUrlInput.value.trim(); if (!serverUrl) return; UI.statusDiv.className = 'status-checking'; UI.statusDiv.textContent = 'Checking...'; GM_xmlhttpRequest({ method: 'GET', url: serverUrl, timeout: 5000, onload: (res) => { try { const data = JSON.parse(res.responseText); UI.statusDiv.className = data.status === 'running' ? 'status-ok' : 'status-error'; UI.statusDiv.textContent = data.status === 'running' ? `Connected (Cache: ${data.items_in_cache})` : 'Unresponsive'; } catch (e) { UI.statusDiv.className = 'status-error'; UI.statusDiv.textContent = 'Invalid Response'; } }, onerror: () => { UI.statusDiv.className = 'status-error'; UI.statusDiv.textContent = 'Connection Failed'; }, ontimeout: () => { UI.statusDiv.className = 'status-error'; UI.statusDiv.textContent = 'Timed Out'; } }); }
    function createMeasurementSpan() { if (measurementSpan) return; measurementSpan = document.createElement('span'); measurementSpan.style.cssText = `position:absolute!important;visibility:hidden!important;height:auto!important;width:auto!important;white-space:nowrap!important;z-index:-1!important;`; document.body.appendChild(measurementSpan); logDebug("Created shared measurement span."); }

    // --- SCRIPT INITIALIZATION ---
    async function init() {
        const loadedSettings = await GM_getValue(SETTINGS_KEY);
        if (loadedSettings) { try { const parsed = JSON.parse(loadedSettings); settings = { ...settings, ...parsed }; } catch(e) { logDebug("Could not parse saved settings. Using defaults."); } }
        createUI(); bindUIEvents(); applyStyles(); createMeasurementSpan();
        UI.serverUrlInput.value = settings.ocrServerUrl; UI.imageServerUserInput.value = settings.imageServerUser || ''; UI.imageServerPasswordInput.value = settings.imageServerPassword || '';
        UI.ankiUrlInput.value = settings.ankiConnectUrl; UI.ankiFieldInput.value = settings.ankiImageField; UI.debugModeCheckbox.checked = settings.debugMode;
        UI.interactionModeSelect.value = settings.interactionMode; UI.textOrientationSelect.value = settings.textOrientation; UI.colorThemeSelect.value = settings.colorTheme;
        UI.proximityRadiusInput.value = settings.proximityRadius; UI.dimmedOpacityInput.value = settings.dimmedOpacity * 100;
        UI.fontMultiplierHorizontalInput.value = settings.fontMultiplierHorizontal; UI.fontMultiplierVerticalInput.value = settings.fontMultiplierVertical;
        UI.sitesConfigTextarea.value = settings.sites.map(s => [s.urlPattern, s.overflowFixSelector, ...(s.imageContainerSelectors || [])].join('; ')).join('\n');
        UI.interactionModeSelect.dispatchEvent(new Event('change'));
        setInterval(manageScrollFix, 500);
        activateScanner();
    }
    init().catch(e => console.error(`[OCR] Fatal Initialization Error: ${e.message}`));
})();
