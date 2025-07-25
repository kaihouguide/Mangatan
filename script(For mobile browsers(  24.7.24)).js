// ==UserScript==
// @name         Automatic Content OCR (Mobile Port v24.7.24-final-fix-2)
// @namespace    http://tampermonkey.net/
// @version      24.7.24-final-fix-2
// @description  Restores the old, reliable scroll-fix logic that is URL-aware, fixing the "no exit" bug and allowing normal scrolling on non-reader pages. Fixes a syntax error in image selectors.
// @author       1Selxo 
// @match        http://127.0.0.1/*
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
        ankiConnectUrl: 'http://127.0.0.1:8765',
        ankiImageField: 'Image',
        sites: [{
            urlPattern: '127.0.0.1',
                // --- FIX STARTS HERE ---
                // Added a comma after the 'div.muiltr-cns6dc' selector
                // to correctly include the RTL selector that follows.
                imageContainerSelectors: [
                'div.muiltr-masn8',      // Old Continuous Vertical
                'div.muiltr-79elbk',      // Webtoon
                'div.muiltr-u43rde',      // Single Page
                'div.muiltr-1r1or1s',      // Double Page
                'div.muiltr-18sieki',     // New Continuous Vertical
                'div.muiltr-cns6dc',      // Added per request
                '.MuiBox-root.muiltr-1noqzsz' // RTL Continuous Vertical
            ],
            // --- FIX ENDS HERE ---
            overflowFixSelector: '.MuiBox-root.muiltr-13djdhf'
        }],
        debugMode: true,
        textOrientation: 'smart',
        colorTheme: 'deepblue'
    };
    let debugLog = [];
    const SETTINGS_KEY = 'gemini_ocr_settings_v24_mobile_final';
    const ocrCache = new WeakMap();
    const managedElements = new Map();
    const managedContainers = new Map();
    const attachedAttributeObservers = new WeakMap();
    let activeSiteConfig = null;
    let overlayUpdateRunning = false;
    let measurementSpan = null;
    const UI = {};
    let activeImageForExport = null;
    const LONG_PRESS_DURATION = 500;

    // --- Color Themes ---
    const COLOR_THEMES = {
        deepblue: { main: 'rgba(0,191,255,',  text: '#FFFFFF', highlightText: '#000000' },
        red:      { main: 'rgba(255, 71, 87,',   text: '#FFFFFF', highlightText: '#000000' },
        green:    { main: 'rgba(46, 204, 113,',  text: '#FFFFFF', highlightText: '#000000' },
        orange:   { main: 'rgba(243, 156, 18,',  text: '#FFFFFF', highlightText: '#000000' },
        purple:   { main: 'rgba(155, 89, 182,',  text: '#FFFFFF', highlightText: '#000000' },
        turquoise:{ main: 'rgba(26, 188, 156,',  text: '#FFFFFF', highlightText: '#000000' },
        pink:     { main: 'rgba(232, 67, 147,',  text: '#FFFFFF', highlightText: '#000000' },
        grey:     { main: 'rgba(149, 165, 166,', text: '#FFFFFF', highlightText: '#000000' }
    };

    // --- Logging & Persistence ---
    const logDebug = (message) => {
        if (!settings.debugMode) return;
        const timestamp = new Date().toLocaleTimeString();
        const logEntry = `[${timestamp}] ${message}`;
        console.log(`[OCR v24.7.24-final-fix Mobile] ${logEntry}`);
        debugLog.push(logEntry);
        document.dispatchEvent(new CustomEvent('ocr-log-update'));
    };
    const PersistentCache = {
        CACHE_KEY: 'gemini_ocr_cache_v24_7',
        data: null,
        async load() { try { const d = await GM_getValue(this.CACHE_KEY); this.data = d ? new Map(Object.entries(JSON.parse(d))) : new Map(); logDebug(`Loaded ${this.data.size} items from persistent cache.`); } catch (e) { this.data = new Map(); logDebug(`Error loading cache: ${e.message}`); } },
        async save() { if (this.data) { try { await GM_setValue(this.CACHE_KEY, JSON.stringify(Object.fromEntries(this.data))); } catch (e) {} } },
        get(key) { return this.data?.get(key); },
        has(key) { return this.data?.has(key) ?? false; },
        async set(key, value) { if(this.data) { this.data.set(key, value); await this.save(); } },
    };

    // --- CORE LOGIC ---
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
        logDebug("Activating scanner v24.7.24-final-fix (Mobile Port)...");
        activeSiteConfig = settings.sites.find(site => window.location.href.includes(site.urlPattern));
        if (!activeSiteConfig?.imageContainerSelectors?.length) return logDebug(`No matching site config for URL: ${window.location.href}.`);
        const selectorQuery = activeSiteConfig.imageContainerSelectors.join(', ');
        document.querySelectorAll(selectorQuery).forEach(manageContainer);
        containerObserver.observe(document.body, { childList: true, subtree: true });
        logDebug("Main container observer is active.");
    }

    // --- Image Processing ---
    function observeImageForSrcChange(img) {
        const processTheImage = (src) => { if (src?.includes('/api/v1/manga/')) { primeImageForOcr(img); return true; } return false; };
        if (processTheImage(img.src)) return;
        if (attachedAttributeObservers.has(img)) return;
        const attributeObserver = new MutationObserver((mutations) => {
            for (const mutation of mutations) if (mutation.attributeName === 'src') if (processTheImage(img.src)) { attributeObserver.disconnect(); attachedAttributeObservers.delete(img); break; }
        });
        attributeObserver.observe(img, { attributes: true });
        attachedAttributeObservers.set(img, attributeObserver);
    }
    function primeImageForOcr(img) {
        if (managedElements.has(img)) return;
        const process = () => {
            if (managedElements.has(img)) return;
            img.crossOrigin = "anonymous";
            const realSrc = img.src;
            if (PersistentCache.has(realSrc)) { logDebug(`Cache HIT for: ...${realSrc.slice(-30)}`); ocrCache.set(img, PersistentCache.get(realSrc)); displayOcrResults(img); }
            else { if (ocrCache.get(img) === 'pending') return; processImage(img, realSrc); }
        };
        if (img.complete && img.naturalHeight > 0) process();
        else img.addEventListener('load', process, { once: true });
    }
    function processImage(img, sourceUrl) {
        if (ocrCache.has(img)) return;
        logDebug(`Requesting OCR for ...${sourceUrl.slice(-30)}`);
        ocrCache.set(img, 'pending');
        GM_xmlhttpRequest({
            method: 'GET', url: `${settings.ocrServerUrl}/ocr?url=${encodeURIComponent(sourceUrl)}`, timeout: 30000,
            onload: (res) => {
                try { const data = JSON.parse(res.responseText); if (data.error) throw new Error(data.error); PersistentCache.set(sourceUrl, data); ocrCache.set(img, data); logDebug(`OCR success for ...${sourceUrl.slice(-30)}`); displayOcrResults(img); }
                catch (e) { logDebug(`OCR Error: ${e.message}`); ocrCache.delete(img); }
            },
            onerror: () => { logDebug(`Connection error.`); ocrCache.delete(img); },
            ontimeout: () => { logDebug(`Request timed out.`); ocrCache.delete(img); }
        });
    }

    // --- ANKI INTEGRATION ---
    async function ankiConnectRequest(action, params = {}) {
        logDebug(`Anki-Connect: Firing action '${action}'`);
        return new Promise((resolve, reject) => {
            GM_xmlhttpRequest({
                method: 'POST', url: settings.ankiConnectUrl,
                data: JSON.stringify({ action, version: 6, params }),
                headers: { 'Content-Type': 'application/json; charset=UTF-8' },
                timeout: 15000,
                onload: (res) => {
                    try { const data = JSON.parse(res.responseText); if (data.error) { reject(new Error(data.error)); } else { resolve(data.result); } }
                    catch (e) { reject(new Error('Failed to parse Anki-Connect response.')); }
                },
                onerror: () => reject(new Error('Connection to Anki-Connect failed. Is Anki running with Anki-Connect installed?')),
                ontimeout: () => reject(new Error('Anki-Connect request timed out.')),
            });
        });
    }
    async function exportImageToAnki(targetImg) {
        logDebug(`Anki Export: Starting screenshot for image...`);
        if (!settings.ankiImageField) { logDebug('Anki Export Failed: Image Field name is not configured.'); alert('Anki Image Field is not set in settings.'); return false; }
        if (!targetImg || !targetImg.complete || !targetImg.naturalHeight) { logDebug('Anki Export Failed: Target image is not valid.'); alert('Anki Export Failed: The selected image is not valid or fully loaded.'); return false; }
        try {
            const canvas = document.createElement('canvas');
            canvas.width = targetImg.naturalWidth;
            canvas.height = targetImg.naturalHeight;
            const ctx = canvas.getContext('2d');
            ctx.drawImage(targetImg, 0, 0);
            const base64data = canvas.toDataURL('image/png').split(',')[1];
            if (!base64data) throw new Error("Canvas toDataURL failed to produce data.");
            const filename = `screenshot_${Date.now()}.png`;
            await ankiConnectRequest('storeMediaFile', { filename, data: base64data });
            logDebug(`Anki Export: Image stored as '${filename}'`);
            const notes = await ankiConnectRequest('findNotes', { query: 'added:1' });
            if (!notes || notes.length === 0) { throw new Error('No recently added cards found (query: "added:1"). Create a card first.'); }
            const lastNoteId = notes.sort((a, b) => b - a)[0];
            logDebug(`Anki Export: Found last card with ID ${lastNoteId}`);
            await ankiConnectRequest('updateNoteFields', { note: { id: lastNoteId, fields: { [settings.ankiImageField]: `<img src="${filename}">` } } });
            logDebug(`Anki Export: Successfully updated note ${lastNoteId}.`);
            return true;
        } catch (error) {
            logDebug(`Anki Export Error: ${error.message}`);
            if (error.message.includes("SecurityError") || error.message.includes("tainted")) { alert(`Anki Export Failed: Canvas security error. The script cannot access the image data. This can be due to CORS policy. Try reloading the page.`); }
            else { alert(`Anki Export Failed: ${error.message}`); }
            return false;
        }
    }

    // --- OVERLAY & UPDATE ENGINE ---
    function displayOcrResults(targetImg) {
        const data = ocrCache.get(targetImg);
        if (!data || data === 'pending' || managedElements.has(targetImg)) return;
        data.sort((a, b) => {
            const a_y = a.tightBoundingBox.y, b_y = b.tightBoundingBox.y, a_x = a.tightBoundingBox.x, b_x = b.tightBoundingBox.x, ROW_TOLERANCE = 0.05;
            if (Math.abs(a_y - b_y) < ROW_TOLERANCE) return b_x - a_x; else return a_y - b_y;
        });
        const overlay = document.createElement('div');
        overlay.className = 'gemini-ocr-decoupled-overlay';
        data.forEach((item) => {
            const ocrBox = document.createElement('div');
            ocrBox.className = 'gemini-ocr-text-box';
            ocrBox.textContent = item.text;
            let isVertical = (settings.textOrientation === 'forceVertical') || (settings.textOrientation === 'smart' && item.tightBoundingBox.height > item.tightBoundingBox.width) || (settings.textOrientation === 'serverAngle' && item.orientation === 90);
            if (isVertical) ocrBox.classList.add('gemini-ocr-text-vertical');
            Object.assign(ocrBox.style, { left: `${item.tightBoundingBox.x*100}%`, top: `${item.tightBoundingBox.y*100}%`, width: `${item.tightBoundingBox.width*100}%`, height: `${item.tightBoundingBox.height*100}%` });
            overlay.appendChild(ocrBox);
        });
        document.body.appendChild(overlay);
        const state = { overlay: overlay, lastWidth: 0, lastHeight: 0 };
        managedElements.set(targetImg, state);
        logDebug(`Created decoupled overlay for image: ...${targetImg.src.slice(-30)}`);
        let pressTimer = null, longPressTriggered = false;
        const onHold = () => {
            longPressTriggered = true;
            const isNowVisible = overlay.classList.toggle('is-visible-on-mobile');
            logDebug(`OCR overlay toggled ${isNowVisible ? 'ON' : 'OFF'} via long-press.`);
            if (isNowVisible) { activeImageForExport = targetImg; UI.globalAnkiButton?.classList.remove('is-hidden'); }
            else {
                overlay.classList.remove('has-manual-highlight');
                overlay.querySelectorAll('.manual-highlight').forEach(b => b.classList.remove('manual-highlight'));
                if (activeImageForExport === targetImg) { activeImageForExport = null; UI.globalAnkiButton?.classList.add('is-hidden'); }
            }
        };
        const pressDown = (e) => { longPressTriggered = false; pressTimer = setTimeout(onHold, LONG_PRESS_DURATION); };
        const pressUp = () => clearTimeout(pressTimer);
        const handleClick = (e) => { if (longPressTriggered) { e.preventDefault(); e.stopPropagation(); } };
        targetImg.addEventListener("touchstart", pressDown, { passive: true });
        targetImg.addEventListener("touchend", pressUp);
        targetImg.addEventListener("touchcancel", pressUp);
        targetImg.addEventListener("contextmenu", e => e.preventDefault());
        targetImg.addEventListener("click", handleClick, { capture: true });
        overlay.addEventListener('click', (e) => {
            if (!overlay.classList.contains('is-visible-on-mobile')) return;
            const tappedBox = e.target.closest('.gemini-ocr-text-box'); if (!tappedBox) return;
            e.stopPropagation();
            const isAlreadyHighlighted = tappedBox.classList.contains('manual-highlight');
            overlay.querySelectorAll('.manual-highlight').forEach(b => b.classList.remove('manual-highlight'));
            if (isAlreadyHighlighted) overlay.classList.remove('has-manual-highlight');
            else { tappedBox.classList.add('manual-highlight'); overlay.classList.add('has-manual-highlight'); }
        });
        if (!overlayUpdateRunning) requestAnimationFrame(updateAllOverlays);
    }

    function calculateAndApplyFontSizes(overlay) {
        if (!measurementSpan) return;
        overlay.querySelectorAll('.gemini-ocr-text-box').forEach(box => {
            const text = box.textContent || ''; if (!text) return;
            const isVertical = box.classList.contains('gemini-ocr-text-vertical');
            const boxRect = box.getBoundingClientRect();
            const availableWidth = boxRect.width - 8, availableHeight = boxRect.height - 8;
            if (availableWidth <= 0 || availableHeight <= 0) return;
            box.style.whiteSpace = 'nowrap';
            let low = 8, high = 150, bestSize = 8;
            Object.assign(measurementSpan.style, { fontFamily: getComputedStyle(box).fontFamily, fontWeight: getComputedStyle(box).fontWeight, letterSpacing: getComputedStyle(box).letterSpacing });
            measurementSpan.textContent = text;
            while (low <= high) {
                const mid = Math.floor((low + high) / 2); if (mid <= 0) break;
                measurementSpan.style.fontSize = `${mid}px`;
                let textFits = isVertical ? (mid * text.length * 0.9 <= availableHeight) && (mid <= availableWidth) : (measurementSpan.offsetWidth <= availableWidth) && (measurementSpan.offsetHeight <= availableHeight);
                if (textFits) { bestSize = mid; low = mid + 1; } else { high = mid - 1; }
            }
            box.style.fontSize = `${bestSize}px`;
            if (isVertical) box.style.lineHeight = '1';
        });
    }

    function updateAllOverlays() {
        overlayUpdateRunning = true;
        try {
            // This now runs on reader pages due to the conditional style injection
            if (activeSiteConfig?.overflowFixSelector) {
                const el = document.querySelector(activeSiteConfig.overflowFixSelector);
                if (el && el.style.overflow !== 'visible') {
                    el.style.overflow = 'visible';
                }
            }

            const elementsToDelete = [];
            for (const [img, state] of managedElements.entries()) {
                if (!document.body.contains(img) || !document.body.contains(state.overlay)) { elementsToDelete.push(img); continue; }
                const rect = img.getBoundingClientRect();
                if (rect.width === 0 || rect.height === 0) { if (state.overlay.classList.contains('is-visible-on-mobile')) state.overlay.classList.remove('is-visible-on-mobile'); continue; }
                Object.assign(state.overlay.style, { top: `${rect.top + window.scrollY}px`, left: `${rect.left + window.scrollX}px`, width: `${rect.width}px`, height: `${rect.height}px` });
                if (state.lastWidth !== rect.width || state.lastHeight !== rect.height) {
                    logDebug(`Dimensions changed for ...${img.src.slice(-30)}. Recalculating fonts.`);
                    calculateAndApplyFontSizes(state.overlay);
                    state.lastWidth = rect.width; state.lastHeight = rect.height;
                }
            }
            elementsToDelete.forEach(img => { managedElements.get(img)?.overlay.remove(); managedElements.delete(img); logDebug(`Garbage collected overlay.`); });
        } catch (error) { logDebug(`Critical error in updateAllOverlays: ${error.message}`); }
        finally {
            overlayUpdateRunning = false;
            if (managedElements.size > 0) requestAnimationFrame(updateAllOverlays);
        }
    }

    // --- UI & EVENT HANDLING ---
    function applyColorTheme() {
        const theme = COLOR_THEMES[settings.colorTheme] || COLOR_THEMES.deepblue;
        const cssVars = `:root { --ocr-bg-color: rgba(10,25,40,0.85); --ocr-border-color: ${theme.main}0.6); --ocr-border-color-dim: ${theme.main}0.3); --ocr-border-color-hover: ${theme.main}0.8); --ocr-text-color: ${theme.text}; --ocr-highlight-bg-color: ${theme.main}0.9); --ocr-highlight-border-color: rgba(255,255,255,0.9); --ocr-highlight-text-color: ${theme.highlightText}; --ocr-highlight-shadow: 0 0 10px ${theme.main}0.5); --ocr-highlight-inset-shadow: inset 0 0 0 2px white; --modal-header-color: ${theme.main}1); }`;
        let styleTag = document.getElementById('gemini-ocr-color-theme-style');
        if (!styleTag) { styleTag = document.createElement('style'); styleTag.id = 'gemini-ocr-color-theme-style'; document.head.appendChild(styleTag); }
        styleTag.textContent = cssVars;
        logDebug(`Applied color theme: ${settings.colorTheme}`);
    }

    function createUI() {
        // *** THE SCROLL FIX - Inspired by v23.5.9 ***
        // Conditionally inject scroll-locking styles ONLY if the URL matches.
        let conditionalStyles = '';
        const href = window.location.href;
        if (href.includes('/manga/') || href.includes('/chapter/')) {
            logDebug("Reader URL detected. Applying scroll-locking styles.");
            conditionalStyles = `
                html { overflow: hidden !important; }
                body { overflow-y: auto !important; overflow-x: hidden !important; -webkit-user-select: none; user-select: none; }
            `;
        }

        GM_addStyle(`
            ${conditionalStyles}
            .gemini-ocr-decoupled-overlay { position: absolute; z-index: 9999; opacity: 0; visibility: hidden; pointer-events: none; transition: opacity 0.2s ease, visibility 0.2s ease; }
            .gemini-ocr-decoupled-overlay.is-visible-on-mobile { opacity: 1; visibility: visible; }
            .gemini-ocr-text-box { position: absolute; display: flex; align-items: center; justify-content: center; text-align: center; box-sizing: border-box; border-radius: 4px; user-select: text; background: var(--ocr-bg-color); border: 2px solid var(--ocr-border-color); color: var(--ocr-text-color); text-shadow: 1px 1px 2px rgba(0,0,0,0.8); backdrop-filter: blur(2px); transition: all 0.2s ease-in-out; pointer-events: auto; overflow: hidden; padding: 4px; }
            .gemini-ocr-text-vertical { writing-mode: vertical-rl; text-orientation: upright; line-height: 1; }
            .gemini-ocr-decoupled-overlay.has-manual-highlight .gemini-ocr-text-box:not(.manual-highlight) { opacity: 0.3; background: rgba(10,25,40,0.5); border-color: var(--ocr-border-color-dim); }
            .gemini-ocr-decoupled-overlay .manual-highlight { overflow: visible; opacity: 1; transform: scale(1.05); background: var(--ocr-highlight-bg-color); border-color: var(--ocr-highlight-border-color); color: var(--ocr-highlight-text-color); text-shadow: none; box-shadow: var(--ocr-highlight-shadow), var(--ocr-highlight-inset-shadow); z-index: 10000; }
            #gemini-ocr-settings-button { position: fixed; bottom: 15px; right: 15px; z-index: 2147483647; background: #1A1D21; color: #EAEAEA; border: 1px solid #555; border-radius: 50%; width: 50px; height: 50px; font-size: 26px; cursor: pointer; display: flex; align-items: center; justify-content: center; box-shadow: 0 4px 12px rgba(0,0,0,0.5); user-select: none; }
            #gemini-ocr-global-anki-export-btn { position: fixed; bottom: 75px; right: 15px; z-index: 2147483646; background-color: #2ecc71; color: white; border: 1px solid white; border-radius: 50%; width: 50px; height: 50px; font-size: 30px; line-height: 50px; text-align: center; cursor: pointer; transition: all 0.2s ease-in-out; user-select: none; box-shadow: 0 4px 12px rgba(0,0,0,0.5); }
            #gemini-ocr-global-anki-export-btn:hover { background-color: #27ae60; transform: scale(1.1); }
            #gemini-ocr-global-anki-export-btn:disabled { background-color: #95a5a6; cursor: wait; transform: none; }
            #gemini-ocr-global-anki-export-btn.is-hidden { opacity: 0; visibility: hidden; pointer-events: none; transform: scale(0.5); }
            .gemini-ocr-modal { position: fixed; top: 50%; left: 50%; transform: translate(-50%, -50%); background-color: #1A1D21; border: 1px solid var(--modal-header-color); border-radius: 15px; z-index: 2147483647; color: #EAEAEA; font-family: sans-serif; box-shadow: 0 8px 32px 0 rgba(0,0,0,0.5); width: 600px; max-width: 90vw; max-height: 90vh; display: flex; flex-direction: column; }
            .gemini-ocr-modal.is-hidden { display: none; }
            .gemini-ocr-modal-header { padding: 20px 25px; border-bottom: 1px solid #444; } .gemini-ocr-modal-header h2 { margin: 0; color: var(--modal-header-color); }
            .gemini-ocr-modal-content { padding: 10px 25px; overflow-y: auto; flex-grow: 1; }
            .gemini-ocr-modal-footer { padding: 15px 25px; border-top: 1px solid #444; display: flex; justify-content: flex-end; gap: 10px; align-items: center; }
            .gemini-ocr-modal h3 { font-size: 1.1em; margin: 15px 0 10px 0; border-bottom: 1px solid #333; padding-bottom: 5px; color: var(--modal-header-color); }
            .gemini-ocr-settings-grid { display: grid; grid-template-columns: max-content 1fr; gap: 10px 15px; align-items: center; } .full-width { grid-column: 1 / -1; }
            .gemini-ocr-modal input, .gemini-ocr-modal textarea, .gemini-ocr-modal select { width: 100%; padding: 8px; box-sizing: border-box; font-family: monospace; background-color: #2a2a2e; border: 1px solid #555; border-radius: 5px; color: #EAEAEA; font-size: 14px; }
            .gemini-ocr-modal button { padding: 10px 18px; background-color: var(--modal-header-color); border: none; border-radius: 5px; color: #1A1D21; cursor: pointer; font-weight: bold; }
            #gemini-ocr-server-status { padding: 10px; border-radius: 5px; text-align: center; cursor: pointer; transition: background-color 0.3s; }
            #gemini-ocr-server-status.status-ok { background-color: #27ae60; } #gemini-ocr-server-status.status-error { background-color: #c0392b; } #gemini-ocr-server-status.status-checking { background-color: #3498db; }
        `);
        document.body.insertAdjacentHTML('beforeend', `
            <button id="gemini-ocr-global-anki-export-btn" class="is-hidden" title="Export Screenshot to Anki">✚</button>
            <button id="gemini-ocr-settings-button">⚙️</button>
            <div id="gemini-ocr-settings-modal" class="gemini-ocr-modal is-hidden">
                <div class="gemini-ocr-modal-header"><h2>Local OCR Settings (v24.7.24-final-fix)</h2></div>
                <div class="gemini-ocr-modal-content">
                    <h3>Connection</h3><div class="gemini-ocr-settings-grid full-width"><label for="gemini-ocr-server-url">OCR Server URL:</label><input type="text" id="gemini-ocr-server-url"></div>
                    <div id="gemini-ocr-server-status" class="full-width" style="margin-top: 10px;">Click to check server status</div>
                    <h3>Anki Integration</h3><div class="gemini-ocr-settings-grid">
                        <label for="gemini-ocr-anki-url">Anki-Connect URL:</label><input type="text" id="gemini-ocr-anki-url">
                        <label for="gemini-ocr-anki-field">Image Field Name:</label><input type="text" id="gemini-ocr-anki-field" placeholder="e.g., Image, SentenceImage">
                    </div>
                    <h3>Display</h3><div class="gemini-ocr-settings-grid">
                        <label for="ocr-color-theme">Color Theme:</label><select id="ocr-color-theme"><option value="deepblue">Deep Blue</option><option value="red">Red</option><option value="green">Green</option><option value="orange">Orange</option><option value="purple">Purple</option><option value="turquoise">Turquoise</option><option value="pink">Pink</option><option value="grey">Grey</option></select>
                        <label for="ocr-text-orientation">Text Orientation:</label><select id="ocr-text-orientation"><option value="smart">Smart</option><option value="serverAngle">Server Angle</option><option value="forceHorizontal">Horizontal</option><option value="forceVertical">Vertical</option></select>
                    </div>
                    <h3>Advanced</h3><div class="gemini-ocr-settings-grid full-width"><label><input type="checkbox" id="gemini-ocr-debug-mode"> Debug Mode</label></div>
                    <div class="gemini-ocr-settings-grid full-width"><label for="gemini-ocr-sites-config">Site Configurations (URL; OverflowFix; Containers...)</label><textarea id="gemini-ocr-sites-config" rows="6" placeholder="127.0.0.1; .overflow-fix; .container1; .container2\n"></textarea></div>
                </div>
                <div class="gemini-ocr-modal-footer"><button id="gemini-ocr-debug-btn" style="background-color: #777; margin-right: auto;">Debug Logs</button><button id="gemini-ocr-close-btn" style="background-color: #555;">Close</button><button id="gemini-ocr-save-btn">Save & Reload</button></div>
            </div>
            <div id="gemini-ocr-debug-modal" class="gemini-ocr-modal is-hidden"><div class="gemini-ocr-modal-header"><h2>Debug Log</h2></div><div class="gemini-ocr-modal-content"><textarea id="gemini-ocr-debug-log" readonly style="width:100%; height: 100%; resize:none;"></textarea></div><div class="gemini-ocr-modal-footer"><button id="gemini-ocr-close-debug-btn" style="background-color: #555;">Close</button></div></div>
        `);
    }

    function bindUIEvents() {
        Object.assign(UI, {
            settingsButton: document.getElementById('gemini-ocr-settings-button'), settingsModal: document.getElementById('gemini-ocr-settings-modal'),
            globalAnkiButton: document.getElementById('gemini-ocr-global-anki-export-btn'),
            debugModal: document.getElementById('gemini-ocr-debug-modal'), serverUrlInput: document.getElementById('gemini-ocr-server-url'),
            ankiUrlInput: document.getElementById('gemini-ocr-anki-url'), ankiFieldInput: document.getElementById('gemini-ocr-anki-field'),
            debugModeCheckbox: document.getElementById('gemini-ocr-debug-mode'), textOrientationSelect: document.getElementById('ocr-text-orientation'),
            colorThemeSelect: document.getElementById('ocr-color-theme'), sitesConfigTextarea: document.getElementById('gemini-ocr-sites-config'),
            statusDiv: document.getElementById('gemini-ocr-server-status'), debugLogTextarea: document.getElementById('gemini-ocr-debug-log'),
            saveBtn: document.getElementById('gemini-ocr-save-btn'), closeBtn: document.getElementById('gemini-ocr-close-btn'),
            debugBtn: document.getElementById('gemini-ocr-debug-btn'), closeDebugBtn: document.getElementById('gemini-ocr-close-debug-btn'),
        });
        UI.settingsButton.addEventListener('click', () => UI.settingsModal.classList.toggle('is-hidden'));
        UI.globalAnkiButton.addEventListener('click', async () => {
            if (!activeImageForExport) { alert("Error: No active image selected for export."); return; }
            const btn = UI.globalAnkiButton;
            btn.textContent = '…'; btn.disabled = true;
            const success = await exportImageToAnki(activeImageForExport);
            if (success) { btn.textContent = '✓'; btn.style.backgroundColor = '#27ae60'; } else { btn.textContent = '✖'; btn.style.backgroundColor = '#c0392b'; }
            setTimeout(() => { btn.textContent = '✚'; btn.style.backgroundColor = ''; btn.disabled = false; }, 2000);
        });
        UI.statusDiv.addEventListener('click', checkServerStatus);
        UI.closeBtn.addEventListener('click', () => UI.settingsModal.classList.add('is-hidden'));
        UI.debugBtn.addEventListener('click', () => { UI.debugLogTextarea.value = debugLog.join('\n'); UI.debugModal.classList.remove('is-hidden'); UI.debugLogTextarea.scrollTop = UI.debugLogTextarea.scrollHeight; });
        UI.closeDebugBtn.addEventListener('click', () => UI.debugModal.classList.add('is-hidden'));
        UI.colorThemeSelect.addEventListener('change', () => { document.documentElement.style.setProperty('--modal-header-color', (COLOR_THEMES[UI.colorThemeSelect.value] || COLOR_THEMES.deepblue).main + '1)'); });
        UI.saveBtn.addEventListener('click', async () => {
            const newSettings = {
                ocrServerUrl: UI.serverUrlInput.value.trim(), ankiConnectUrl: UI.ankiUrlInput.value.trim(), ankiImageField: UI.ankiFieldInput.value.trim(),
                debugMode: UI.debugModeCheckbox.checked, textOrientation: UI.textOrientationSelect.value, colorTheme: UI.colorThemeSelect.value,
                sites: UI.sitesConfigTextarea.value.split('\n').filter(line => line.trim()).map(line => { const parts = line.split(';').map(s => s.trim()); return { urlPattern: parts[0] || '', overflowFixSelector: parts[1] || '', imageContainerSelectors: parts.slice(2).filter(s => s) }; })
            };
            try { await GM_setValue(SETTINGS_KEY, JSON.stringify(newSettings)); alert('Settings Saved. The page will now reload.'); window.location.reload(); }
            catch (e) { logDebug(`Failed to save settings: ${e.message}`); alert(`Error: Could not save settings.`); }
        });
        document.addEventListener('ocr-log-update', () => { if(UI.debugModal && !UI.debugModal.classList.contains('is-hidden')) { UI.debugLogTextarea.value = debugLog.join('\n'); UI.debugLogTextarea.scrollTop = UI.debugLogTextarea.scrollHeight; }});
    }

    function checkServerStatus() {
        const serverUrl = UI.serverUrlInput.value.trim(); if (!serverUrl) return;
        UI.statusDiv.className = 'status-checking'; UI.statusDiv.textContent = 'Checking...';
        GM_xmlhttpRequest({
            method: 'GET', url: serverUrl, timeout: 5000,
            onload: (res) => { try { const data = JSON.parse(res.responseText); UI.statusDiv.className = data.status === 'running' ? 'status-ok' : 'status-error'; UI.statusDiv.textContent = data.status === 'running' ? `Connected (${data.items_in_cache} cached)` : 'Unresponsive Server'; } catch (e) { UI.statusDiv.className = 'status-error'; UI.statusDiv.textContent = 'Invalid Response'; } },
            onerror: () => { UI.statusDiv.className = 'status-error'; UI.statusDiv.textContent = 'Connection Failed'; },
            ontimeout: () => { UI.statusDiv.className = 'status-error'; UI.statusDiv.textContent = 'Connection Timed Out'; }
        });
    }

    function createMeasurementSpan() {
        if (measurementSpan) return;
        measurementSpan = document.createElement('span');
        measurementSpan.style.cssText = `position: absolute !important; visibility: hidden !important; height: auto !important; width: auto !important; white-space: nowrap !important; z-index: -1 !important;`;
        document.body.appendChild(measurementSpan);
        logDebug("Created shared measurement span for performance.");
    }

    // --- SCRIPT INITIALIZATION ---
    async function init() {
        const loadedSettings = await GM_getValue(SETTINGS_KEY);
        if (loadedSettings) {
            try { const parsedSettings = JSON.parse(loadedSettings); settings = { ...settings, ...parsedSettings }; delete settings.fontSizePercent; }
            catch(e) { logDebug("Could not parse saved settings. Using defaults."); }
        }
        createUI();
        createMeasurementSpan();
        await PersistentCache.load();
        bindUIEvents();
        applyColorTheme();
        UI.serverUrlInput.value = settings.ocrServerUrl;
        UI.ankiUrlInput.value = settings.ankiConnectUrl;
        UI.ankiFieldInput.value = settings.ankiImageField;
        UI.debugModeCheckbox.checked = settings.debugMode;
        UI.textOrientationSelect.value = settings.textOrientation;
        UI.colorThemeSelect.value = settings.colorTheme;
        UI.sitesConfigTextarea.value = settings.sites.map(s => [s.urlPattern, s.overflowFixSelector, ...(s.imageContainerSelectors || [])].join('; ')).join('\n');
        activateScanner();
    }
    init().catch(e => console.error(`[OCR v24.7.24-final-fix Mobile] Fatal Initialization Error: ${e.message}`));
})();
