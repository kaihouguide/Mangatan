// ==UserScript==
// @name         Automatic Content OCR (Mobile Port v8.1 - Tap-to-Focus)
// @namespace    http://tampermonkey.net/
// @version      8.1
// @description  Adds Tap-to-Focus. Long-press to show overlay, then tap a text box to highlight it. Tap again to clear.
// @author       1Selxo (Ported & Modified by Gemini)
// @match        *://127.0.0.1/*
// @grant        GM_setValue
// @grant        GM_getValue
// @grant        GM_addStyle
// @grant        GM_xmlhttpRequest
// @connect      127.0.0.1
// @connect      localhost
// @connect      fonts.googleapis.com
// @connect      fonts.gstatic.com
// @connect      *
// ==/UserScript==

(function() {
    'use strict';

    // --- Global State and Settings ---
    let settings = {
        ocrServerUrl: 'http://127.0.0.1:3000',
        sites: [{
            urlPattern: '127.0.0.1',
            imageContainerSelectors: [
                'div.muiltr-masn8', // Continuous Vertical
                'div.muiltr-79elbk', // Webtoon
                'div.muiltr-u43rde', // Single Page
                'div.muiltr-1r1or1s', // Double Page
            ],
            overflowFixSelector: '.MuiBox-root.muiltr-13djdhf'
        }],
        debugMode: true,
        textOrientation: 'smart',
        fontSizePercent: 4.5,
    };
    let debugLog = [];
    const ocrCache = new WeakMap();
    const managedElements = new Map();
    const managedContainers = new Map();
    let activeSiteConfig = null;
    const LONG_PRESS_DURATION = 500;

    // --- Logging Utility ---
    const logDebug = (message) => {
        if (!settings.debugMode) return;
        const timestamp = new Date().toLocaleTimeString();
        const logEntry = `[${timestamp}] ${message}`;
        console.log(`Local OCR (Mobile v8.1): ${logEntry}`);
        debugLog.push(logEntry);
        document.dispatchEvent(new CustomEvent('ocr-log-update'));
    };

    // --- Persistence Module ---
    const PersistentCache = {
        CACHE_KEY: 'gemini_ocr_local_cache_v1', data: null,
        async load() { try { const d = await GM_getValue(this.CACHE_KEY); this.data = d ? new Map(Object.entries(JSON.parse(d))) : new Map(); logDebug(`Loaded ${this.data.size} items from cache.`); } catch (e) { logDebug(`Error loading cache: ${e.message}.`); this.data = new Map(); } },
        async save() { if (this.data) { try { await GM_setValue(this.CACHE_KEY, JSON.stringify(Object.fromEntries(this.data))); } catch (e) {} } },
        get(key) { return this.data?.get(key); },
        has(key) { return this.data?.has(key) ?? false; },
        async set(key, value) { this.data?.set(key, value); await this.save(); },
    };

    // --- CORE LOGIC (Hybrid Observer Strategy) ---
    const imageObserver = new MutationObserver((mutations) => {
        for (const mutation of mutations) {
            for (const node of mutation.addedNodes) {
                if (node.tagName === 'IMG') {
                    observeImageForSrcChange(node);
                } else if (node.querySelectorAll) {
                    node.querySelectorAll('img').forEach(observeImageForSrcChange);
                }
            }
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
        for (const mutation of mutations) {
            for (const node of mutation.addedNodes) {
                if (node.nodeType !== 1) continue;
                if (node.matches(selectorQuery)) {
                    manageContainer(node);
                }
                node.querySelectorAll(selectorQuery).forEach(manageContainer);
            }
        }
    });

    function activateScanner() {
        logDebug("Activating scanner v8.1 (Tap-to-Focus)...");
        activeSiteConfig = settings.sites.find(site => window.location.href.includes(site.urlPattern));
        if (!activeSiteConfig || !activeSiteConfig.imageContainerSelectors?.length) {
            return logDebug(`No matching site config for URL: ${window.location.href}`);
        }
        const selectorQuery = activeSiteConfig.imageContainerSelectors.join(', ');
        document.querySelectorAll(selectorQuery).forEach(manageContainer);
        containerObserver.observe(document.body, { childList: true, subtree: true });
        logDebug("Main container observer is active.");
    }

    // --- Image Processing (Wrapper Implementation) ---
    function observeImageForSrcChange(img) {
        if (img.dataset.ocrListenerAttached) return;
        img.dataset.ocrListenerAttached = 'true';
        let wrapper = img.closest('.gemini-ocr-image-wrapper');
        if (!wrapper) {
            wrapper = document.createElement('div');
            wrapper.className = 'gemini-ocr-image-wrapper';
            img.parentNode.insertBefore(wrapper, img);
            wrapper.appendChild(img);
        }
        const processTheImage = (src) => {
            if (src && src.includes('/api/v1/manga/')) {
                primeImageForOcr(img);
                return true;
            } return false;
        };
        if (processTheImage(img.src)) return;
        const attributeObserver = new MutationObserver((mutations) => {
            for (const mutation of mutations) if (mutation.attributeName === 'src') {
                if (processTheImage(img.src)) {
                    attributeObserver.disconnect();
                    break;
                }
            }
        });
        attributeObserver.observe(img, { attributes: true });
    }

    function primeImageForOcr(img) {
        if (img.dataset.ocrPrimed) return;
        img.dataset.ocrPrimed = 'true';
        const realSrc = img.src;
        if (PersistentCache.has(realSrc)) {
            logDebug(`Cache HIT for: ...${realSrc.slice(-20)}`);
            ocrCache.set(img, PersistentCache.get(realSrc));
            if (img.complete) displayOcrResults(img); else img.addEventListener('load', () => displayOcrResults(img), { once: true });
            return;
        }
        if (img.complete) processImage(img, realSrc); else img.addEventListener('load', () => processImage(img, realSrc), { once: true });
    }

    function processImage(img, sourceUrl) {
        if (ocrCache.has(img) && ocrCache.get(img) !== 'pending') return;
        logDebug(`Requesting OCR for ...${sourceUrl.slice(-40)}`);
        ocrCache.set(img, 'pending');
        GM_xmlhttpRequest({
            method: 'GET', url: `${settings.ocrServerUrl}/ocr?url=${encodeURIComponent(sourceUrl)}`, timeout: 30000,
            onload: (response) => {
                try {
                    const parsedData = JSON.parse(response.responseText);
                    PersistentCache.set(sourceUrl, parsedData); ocrCache.set(img, parsedData);
                    logDebug(`OCR success for ...${sourceUrl.slice(-20)}`);
                    displayOcrResults(img);
                } catch (e) { logDebug(`OCR Error: ${e.message}`); ocrCache.delete(img); }
            },
            onerror: (err) => { logDebug(`OCR connection error: ${JSON.stringify(err)}`); ocrCache.delete(img); },
            ontimeout: () => { logDebug(`OCR request timed out for ...${sourceUrl.slice(-20)}`); ocrCache.delete(img); }
        });
    }

    // --- DISPLAY LOGIC (Wrapper with Long-Press Toggle and Tap-to-Focus) ---
    function displayOcrResults(targetImg) {
        const data = ocrCache.get(targetImg);
        const wrapper = targetImg.closest('.gemini-ocr-image-wrapper');
        if (!data || data === 'pending' || !wrapper || managedElements.has(targetImg)) return;

        const overlayContainer = document.createElement('div');
        overlayContainer.className = 'gemini-ocr-phantom-overlay';
        wrapper.appendChild(overlayContainer);

        data.forEach((item) => {
            const ocrBox = document.createElement('div');
            ocrBox.className = 'gemini-ocr-text-box';
            ocrBox.textContent = item.text;
            const isVertical = item.tightBoundingBox.height > item.tightBoundingBox.width;
            if (settings.textOrientation === 'forceVertical' || (settings.textOrientation === 'smart' && isVertical)) {
                ocrBox.classList.add('gemini-ocr-text-vertical');
            }
            Object.assign(ocrBox.style, {
                left: `${item.tightBoundingBox.x * 100}%`, top: `${item.tightBoundingBox.y * 100}%`,
                width: `${item.tightBoundingBox.width * 100}%`, height: `${item.tightBoundingBox.height * 100}%`
            });
            overlayContainer.appendChild(ocrBox);
        });

        managedElements.set(targetImg, { overlay: overlayContainer, wrapper: wrapper });
        logDebug(`Created overlay for image: ...${targetImg.src.slice(-20)}`);

        // --- INTERACTION LOGIC ---
        let pressTimer = null;
        let longPressTriggered = false;

        const onHold = () => {
            const isNowVisible = wrapper.classList.toggle('is-ocr-visible');
            logDebug(`OCR overlay toggled ${isNowVisible ? 'ON' : 'OFF'} via long-press.`);
            longPressTriggered = true;
            if (!isNowVisible) {
                const focusedBox = wrapper.querySelector('.gemini-ocr-text-box.focused');
                if (focusedBox) {
                    focusedBox.classList.remove('focused');
                    overlayContainer.classList.remove('is-focused');
                }
            }
        };
        const pressDown = () => { longPressTriggered = false; pressTimer = setTimeout(onHold, LONG_PRESS_DURATION); };
        const pressUp = () => clearTimeout(pressTimer);
        const handleClick = (e) => { if (longPressTriggered) { e.preventDefault(); e.stopPropagation(); } };

        wrapper.addEventListener("mousedown", pressDown);
        wrapper.addEventListener("touchstart", pressDown, { passive: true });
        wrapper.addEventListener("mouseup", pressUp);
        wrapper.addEventListener("mouseleave", pressUp);
        wrapper.addEventListener("touchend", pressUp);
        wrapper.addEventListener("touchcancel", pressUp);
        wrapper.addEventListener("touchmove", pressUp);
        wrapper.addEventListener("click", handleClick, { capture: true });
        wrapper.addEventListener("contextmenu", e => e.preventDefault());

        // --- NEW: TAP-TO-FOCUS LOGIC ---
        overlayContainer.addEventListener('click', (e) => {
            const tappedBox = e.target.closest('.gemini-ocr-text-box');
            const currentlyFocused = overlayContainer.querySelector('.gemini-ocr-text-box.focused');

            if (tappedBox) {
                e.stopPropagation(); // Prevent click from passing to the image underneath
                if (tappedBox === currentlyFocused) {
                    tappedBox.classList.remove('focused');
                    overlayContainer.classList.remove('is-focused');
                    logDebug('Unfocused text box.');
                } else {
                    if (currentlyFocused) currentlyFocused.classList.remove('focused');
                    tappedBox.classList.add('focused');
                    overlayContainer.classList.add('is-focused');
                    logDebug('Focused new text box.');
                }
            } else if (currentlyFocused) {
                currentlyFocused.classList.remove('focused');
                overlayContainer.classList.remove('is-focused');
                logDebug('Unfocused via background tap.');
            }
        });
    }

    // --- Overlay Sync & Garbage Collection Loop ---
    function updateAllOverlays() {
        if (activeSiteConfig?.overflowFixSelector) {
            const problematicElement = document.querySelector(activeSiteConfig.overflowFixSelector);
            if (problematicElement && problematicElement.style.overflow !== 'visible') {
                problematicElement.style.overflow = 'visible';
            }
        }
        for (const [img, data] of managedElements.entries()) {
            if (!document.body.contains(img)) {
                managedElements.delete(img);
                logDebug(`Garbage collected wrapper for removed image: ...${img.src.slice(-20)}`);
                continue;
            }
            const rect = img.getBoundingClientRect();
            data.overlay.childNodes.forEach((ocrBox) => {
                const userDefinedSize = rect.height * (settings.fontSizePercent / 100);
                ocrBox.style.fontSize = `${Math.max(userDefinedSize, 10)}px`;
            });
        }
        requestAnimationFrame(updateAllOverlays);
    }

    // --- UI SETUP (with Tap-to-Focus CSS) ---
    async function createUI() {
        GM_addStyle(`
            .gemini-ocr-image-wrapper { position: relative; display: block; line-height: 0; -webkit-user-select: none; user-select: none; }
            .gemini-ocr-phantom-overlay { position: absolute; top: 0; left: 0; width: 100%; height: 100%; z-index: 9999; visibility: hidden; opacity: 0; transition: opacity 0.2s ease-in-out; }
            .gemini-ocr-image-wrapper.is-ocr-visible .gemini-ocr-phantom-overlay { visibility: visible; opacity: 1; pointer-events: auto; /* Allow tapping on the overlay */ }
            .gemini-ocr-text-box { font-family: 'Noto Sans JP', sans-serif; position: absolute; background: rgba(10, 25, 40, 0.75); border: 2px solid rgba(0, 191, 255, 0.8); color: white; text-shadow: 1px 1px 2px #000, -1px -1px 2px #000, 1px -1px 2px #000, -1px 1px 2px #000; backdrop-filter: blur(2px); line-height: 1.25; display: flex; align-items: center; justify-content: center; text-align: center; border-radius: 4px; box-sizing: border-box; user-select: text; pointer-events: auto; transition: opacity 0.2s, transform 0.2s, border-color 0.2s; }
            .gemini-ocr-text-vertical { writing-mode: vertical-rl !important; text-orientation: upright !important; letter-spacing: 0.1em; }

            /* --- TAP-TO-FOCUS HIGHLIGHTING LOGIC --- */
            .gemini-ocr-phantom-overlay.is-focused .gemini-ocr-text-box { opacity: 0.4; }
            .gemini-ocr-phantom-overlay.is-focused .gemini-ocr-text-box.focused { opacity: 1; transform: scale(1.02); border-color: #FFC107; }

            /* --- Standard UI Elements --- */
            #gemini-ocr-settings-button { position: fixed; bottom: 15px; right: 15px; z-index: 2147483646; background: #1F1F23; color: #EAEAEA; border: 1px solid #555; border-radius: 50%; width: 45px; height: 45px; font-size: 24px; cursor: pointer; display: flex; align-items: center; justify-content: center; box-shadow: 0 4px 12px rgba(0,0,0,0.4); user-select: none; }
            .gemini-ocr-modal { position: fixed; top: 50%; left: 50%; transform: translate(-50%, -50%); background-color: #1F1F23; border: 1px solid #00BFFF; border-radius: 15px; padding: 25px; z-index: 2147483647; color: #EAEAEA; font-family: 'Noto Sans JP', sans-serif; box-shadow: 0 8px 32px 0 rgba(0, 0, 0, 0.5); width: 600px; max-width: 90vw; }
            #gemini-ocr-debug-modal { width: 80vw; height: 80vh; flex-direction: column; }
            .gemini-ocr-modal.is-hidden { display: none !important; }
            .gemini-ocr-modal.is-visible { display: flex !important; flex-direction: column; }
            .gemini-ocr-modal h2, .gemini-ocr-modal h3 { margin-top: 0; color: #00BFFF; }
            .gemini-ocr-modal h3 { font-size: 1.1em; margin-bottom: -5px; margin-top: 20px; border-bottom: 1px solid #444; padding-bottom: 5px; }
            .gemini-ocr-settings-grid { display: grid; grid-template-columns: max-content 1fr; gap: 12px; align-items: center; }
            .gemini-ocr-settings-grid .full-width { grid-column: 1 / -1; }
            .gemini-ocr-modal-buttons { grid-column: 1 / -1; display: flex; flex-wrap: wrap; justify-content: flex-end; gap: 10px; margin-top: 15px; }
            .gemini-ocr-modal input, .gemini-ocr-modal textarea, .gemini-ocr-modal select, #gemini-ocr-debug-log { width: 100%; padding: 8px; box-sizing: border-box; font-family: monospace; background-color: #2a2a2e; border: 1px solid #555; border-radius: 5px; color: #EAEAEA; font-size: 14px; }
            .gemini-ocr-modal input[type="number"] { width: 80px; }
            #gemini-ocr-debug-log { flex-grow: 1; resize: none; }
            .gemini-ocr-modal textarea { height: 120px; }
            .gemini-ocr-modal button { padding: 10px 18px; background-color: #00BFFF; border: none; border-radius: 5px; color: #1A1A1D; cursor: pointer; font-weight: bold; }
            #gemini-ocr-server-status { grid-column: 1 / -1; padding: 10px; border: 1px solid #555; border-radius: 5px; text-align: center; font-weight: bold; }
            @media (max-width: 700px) {
                .gemini-ocr-modal { padding: 15px; width: 95vw; max-height: 90vh; overflow-y: auto; }
                .gemini-ocr-settings-grid { display: block; }
                .gemini-ocr-settings-grid > label { display: block; margin-top: 15px; font-weight: bold; }
                .gemini-ocr-modal-buttons { justify-content: space-between; }
            }
        `);

        const settingsButton = document.createElement('button'); settingsButton.id = 'gemini-ocr-settings-button'; settingsButton.innerHTML = '⚙️'; document.body.appendChild(settingsButton);
        const modal = document.createElement('div'); modal.id = 'gemini-ocr-settings-modal'; modal.classList.add('gemini-ocr-modal', 'is-hidden');
        modal.innerHTML = `
            <h2 class="full-width">Local OCR Settings (v8.1 Mobile)</h2>
            <div class="gemini-ocr-settings-grid">
                <h3 class="full-width">Connection</h3>
                <label class="full-width" for="gemini-ocr-server-url">OCR Server URL: <em style="font-weight:normal;color:#ccc;">(e.g., http://192.168.1.10:3000)</em></label>
                <input type="text" id="gemini-ocr-server-url" class="full-width">
                <div id="gemini-ocr-server-status" title="Click to check status">Click to check server status</div>
                <h3 class="full-width">Text Display</h3>
                <label for="ocr-text-orientation">Text Orientation:</label> <select id="ocr-text-orientation"> <option value="smart">Smart Detection</option> <option value="forceHorizontal">Force Horizontal</option> <option value="forceVertical">Force Vertical</option> </select>
                <label for="ocr-font-size">Font Size (% of image height):</label> <input type="number" id="ocr-font-size" min="1" max="50" step="0.5">
                <h3 class="full-width">Advanced</h3>
                <div class="full-width"> <label><input type="checkbox" id="gemini-ocr-debug-mode"> Debug Mode</label> </div>
                <div class="full-width">
                    <label for="gemini-ocr-sites-config">Site Configurations (URL; OverflowFix; Container1; ...)</label>
                    <textarea id="gemini-ocr-sites-config" rows="4" placeholder="Example: 127.0.0.1; .body-wrapper; .vertical-reader; .webtoon-reader"></textarea>
                </div>
                <div class="gemini-ocr-modal-buttons full-width"> <button id="gemini-ocr-debug-btn" style="background-color: #777; margin-right: auto;">Logs</button> <button id="gemini-ocr-close-btn" style="background-color: #555;">Close</button> <button id="gemini-ocr-save-btn">Save & Reload</button> </div>
            </div>`;
        document.body.appendChild(modal);
        // ... (rest of the UI creation is identical, only change is the settings key)
        const loadedSettings = await GM_getValue('gemini_ocr_observer_settings_v8.1_mobile'); // Updated key
        if (loadedSettings) { settings = { ...settings, ...JSON.parse(loadedSettings) }; }

        // ... (Code to populate inputs from settings is identical)
        document.getElementById('gemini-ocr-server-url').value = settings.ocrServerUrl;
        document.getElementById('gemini-ocr-debug-mode').checked = settings.debugMode;
        document.getElementById('ocr-text-orientation').value = settings.textOrientation;
        document.getElementById('ocr-font-size').value = settings.fontSizePercent;
        document.getElementById('gemini-ocr-sites-config').value = settings.sites.map(s =>
            [s.urlPattern, s.overflowFixSelector, ...(s.imageContainerSelectors || [])].join('; ')
        ).join('\n');


        // --- Event Listeners for UI ---
        const debugModal = document.createElement('div'); debugModal.id = 'gemini-ocr-debug-modal'; debugModal.classList.add('gemini-ocr-modal', 'is-hidden');
        debugModal.innerHTML = `<h2>Debug Log</h2><textarea id="gemini-ocr-debug-log" readonly></textarea><button id="gemini-ocr-close-debug-btn" style="background-color: #555;">Close</button>`;
        document.body.appendChild(debugModal);

        settingsButton.addEventListener('click', () => modal.classList.toggle('is-hidden'));
        document.getElementById('gemini-ocr-close-btn').addEventListener('click', () => modal.classList.add('is-hidden'));
        document.getElementById('gemini-ocr-server-status').addEventListener('click', checkServerStatus);
        const debugTextarea = document.getElementById('gemini-ocr-debug-log');
        document.getElementById('gemini-ocr-debug-btn').addEventListener('click', () => { debugModal.classList.remove('is-hidden'); debugTextarea.value = debugLog.join('\n'); debugTextarea.scrollTop = debugTextarea.scrollHeight; });
        document.getElementById('gemini-ocr-close-debug-btn').addEventListener('click', () => { debugModal.classList.add('is-hidden'); });
        document.addEventListener('ocr-log-update', () => { if (!debugModal.classList.contains('is-hidden')) { debugTextarea.value = debugLog.join('\n'); debugTextarea.scrollTop = debugTextarea.scrollHeight; } });

        document.getElementById('gemini-ocr-save-btn').addEventListener('click', async () => {
            const newSettings = {
                ocrServerUrl: document.getElementById('gemini-ocr-server-url').value.trim(),
                debugMode: document.getElementById('gemini-ocr-debug-mode').checked,
                textOrientation: document.getElementById('ocr-text-orientation').value,
                fontSizePercent: parseFloat(document.getElementById('ocr-font-size').value) || 4.5,
                sites: document.getElementById('gemini-ocr-sites-config').value.split('\n').filter(line => line.trim()).map(line => {
                    const parts = line.split(';').map(s => s.trim());
                    return { urlPattern: parts[0] || '', overflowFixSelector: parts[1] || '', imageContainerSelectors: parts.slice(2).filter(s => s) };
                })
            };
            await GM_setValue('gemini_ocr_observer_settings_v8.1_mobile', JSON.stringify(newSettings)); // Updated key
            alert('Settings Saved. The page will now reload.'); window.location.reload();
        });
    }

    function checkServerStatus() {
        /* This function is identical to the previous version */
        const statusDiv = document.getElementById('gemini-ocr-server-status');
        const serverUrl = document.getElementById('gemini-ocr-server-url').value.trim();
        if (!statusDiv || !serverUrl) return;
        statusDiv.textContent = 'Checking...';
        GM_xmlhttpRequest({
            method: 'GET', url: serverUrl, timeout: 5000,
            onload: (res) => { try { const data = JSON.parse(res.responseText); if (data.status === 'running') statusDiv.textContent = `Connected (${data.items_in_cache} cached)`; else throw new Error(); } catch (e) { statusDiv.textContent = 'Unresponsive Server'; } },
            onerror: () => { statusDiv.textContent = 'Connection Failed'; },
            ontimeout: () => { statusDiv.textContent = 'Connection Timed Out'; }
        });
    }

    // --- SCRIPT INITIALIZATION ---
    async function init() {
        await PersistentCache.load();
        await createUI();
        activateScanner();
        requestAnimationFrame(updateAllOverlays);
    }

    init().catch(console.error);
})();
