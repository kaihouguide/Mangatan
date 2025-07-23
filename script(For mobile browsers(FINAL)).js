// ==UserScript==
// @name         Automatic Content OCR (Mobile Port v23.5.9)
// @namespace    http://tampermonkey.net/
// @version      23.5.9
// @description  Fully synced with PC v21.5.9. Long-press toggles overlay visibility. Tap a text box to highlight it. Includes smart setting merges and dynamic vertical text sizing.
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
        sites: [{
            urlPattern: '127.0.0.1',
            imageContainerSelectors: [
                'div.muiltr-masn8', // Old Continuous Vertical
                'div.muiltr-79elbk', // Webtoon
                'div.muiltr-u43rde', // Single Page
                'div.muiltr-1r1or1s', // Double Page
                'div.muiltr-18sieki', // New Continuous Vertical
                'div.muiltr-cns6dc'  // Added Selector
            ],
            overflowFixSelector: '.MuiBox-root.muiltr-13djdhf'
        }],
        debugMode: true,
        textOrientation: 'smart',
        fontSizePercent: 4.5,
    };
    let debugLog = [];
    const SETTINGS_KEY = 'gemini_ocr_settings_v23_mobile';
    const ocrCache = new WeakMap();
    const managedElements = new Map();
    const managedContainers = new Map();
    const attachedAttributeObservers = new WeakMap();
    let activeSiteConfig = null;
    let overlayUpdateRunning = false;
    const UI = {};
    const LONG_PRESS_DURATION = 500; // 500ms for long-press action

    // --- Logging & Persistence ---
    const logDebug = (message) => {
        if (!settings.debugMode) return;
        const timestamp = new Date().toLocaleTimeString();
        const logEntry = `[${timestamp}] ${message}`;
        console.log(`[OCR v23.5.9 Mobile] ${logEntry}`);
        debugLog.push(logEntry);
        document.dispatchEvent(new CustomEvent('ocr-log-update'));
    };
    const PersistentCache = {
        CACHE_KEY: 'gemini_ocr_cache_v23_5',
        data: null,
        async load() { try { const d = await GM_getValue(this.CACHE_KEY); this.data = d ? new Map(Object.entries(JSON.parse(d))) : new Map(); logDebug(`Loaded ${this.data.size} items from persistent cache.`); } catch (e) { this.data = new Map(); logDebug(`Error loading cache: ${e.message}`); } },
        async save() { if (this.data) { try { await GM_setValue(this.CACHE_KEY, JSON.stringify(Object.fromEntries(this.data))); } catch (e) {} } },
        get(key) { return this.data?.get(key); },
        has(key) { return this.data?.has(key) ?? false; },
        async set(key, value) { if(this.data) { this.data.set(key, value); await this.save(); } },
    };

    // --- CORE LOGIC (v21 Engine) ---
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
        logDebug("Activating scanner v23.5.9 (Mobile Port)...");
        activeSiteConfig = settings.sites.find(site => window.location.href.includes(site.urlPattern));
        if (!activeSiteConfig?.imageContainerSelectors?.length) return logDebug(`No matching site config for URL: ${window.location.href}.`);
        const selectorQuery = activeSiteConfig.imageContainerSelectors.join(', ');
        document.querySelectorAll(selectorQuery).forEach(manageContainer);
        containerObserver.observe(document.body, { childList: true, subtree: true });
        logDebug("Main container observer is active.");
    }

    // --- Image Processing (State-Aware) ---
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

    // --- DECOUPLED OVERLAY ENGINE with MOBILE INTERACTION (v23) ---
    function displayOcrResults(targetImg) {
        const data = ocrCache.get(targetImg);
        if (!data || data === 'pending' || managedElements.has(targetImg)) return;

        const overlay = document.createElement('div');
        overlay.className = 'gemini-ocr-decoupled-overlay'; // Start hidden

        data.forEach((item) => {
            const ocrBox = document.createElement('div');
            ocrBox.className = 'gemini-ocr-text-box';
            ocrBox.textContent = item.text;
            if (settings.textOrientation === 'forceVertical' || (settings.textOrientation === 'smart' && item.tightBoundingBox.height > item.tightBoundingBox.width)) {
                ocrBox.classList.add('gemini-ocr-text-vertical');
            }

            // Dynamic sizing from PC v21.5.9
            let boxWidth = `${item.tightBoundingBox.width*100}%`;
            let boxHeight = `${item.tightBoundingBox.height*100}%`;
            let span = document.createElement('span');
            span.style.cssText = "position:absolute; visibility:hidden; font:inherit; font-size:1em; white-space:nowrap;";
            span.textContent = item.text;
            overlay.appendChild(span); // Add to DOM to calculate size
            let spanStyle = window.getComputedStyle(span);
            if (ocrBox.classList.contains('gemini-ocr-text-vertical')){
                boxHeight = spanStyle.getPropertyValue('height');
            } else {
                boxWidth = spanStyle.getPropertyValue('width');
            }
            span.remove();

            Object.assign(ocrBox.style, {
                left: `${item.tightBoundingBox.x*100}%`, top: `${item.tightBoundingBox.y*100}%`,
                width: boxWidth, height: boxHeight
            });
            overlay.appendChild(ocrBox);
        });

        document.body.appendChild(overlay);
        const state = { overlay: overlay, hideTimeout: null };
        managedElements.set(targetImg, state);
        logDebug(`Created decoupled overlay for image: ...${targetImg.src.slice(-30)}`);

        // --- MOBILE INTERACTION LOGIC (Long-Press & Tap-to-Focus) ---
        let pressTimer = null;
        let longPressTriggered = false;

        const onHold = () => {
            longPressTriggered = true;
            const isNowVisible = overlay.classList.toggle('is-visible-on-mobile');
            logDebug(`OCR overlay toggled ${isNowVisible ? 'ON' : 'OFF'} via long-press.`);
            if (!isNowVisible) {
                overlay.classList.remove('has-manual-highlight');
                overlay.querySelectorAll('.manual-highlight').forEach(b => b.classList.remove('manual-highlight'));
            }
        };

        const pressDown = (e) => {
            longPressTriggered = false;
            pressTimer = setTimeout(onHold, LONG_PRESS_DURATION);
        };
        const pressUp = () => clearTimeout(pressTimer);
        const handleClick = (e) => { if (longPressTriggered) { e.preventDefault(); e.stopPropagation(); } };

        targetImg.addEventListener("touchstart", pressDown, { passive: true });
        targetImg.addEventListener("touchend", pressUp);
        targetImg.addEventListener("touchcancel", pressUp);
        targetImg.addEventListener("touchmove", pressUp);
        targetImg.addEventListener("contextmenu", e => e.preventDefault());
        targetImg.addEventListener("click", handleClick, { capture: true });

        // --- TAP-TO-FOCUS LOGIC (from PC "click" mode) ---
        overlay.addEventListener('click', (e) => {
            const tappedBox = e.target.closest('.gemini-ocr-text-box');
            if (!tappedBox) return;
            e.stopPropagation();

            const isAlreadyHighlighted = tappedBox.classList.contains('manual-highlight');
            overlay.querySelectorAll('.manual-highlight').forEach(b => b.classList.remove('manual-highlight'));

            if (isAlreadyHighlighted) {
                overlay.classList.remove('has-manual-highlight');
            } else {
                tappedBox.classList.add('manual-highlight');
                overlay.classList.add('has-manual-highlight');
            }
        });

        if (!overlayUpdateRunning) requestAnimationFrame(updateAllOverlays);
    }

    function updateAllOverlays() {
        overlayUpdateRunning = true;
        try {
            if (activeSiteConfig?.overflowFixSelector) {
                const el = document.querySelector(activeSiteConfig.overflowFixSelector);
                if (el && el.style.overflow !== 'visible') el.style.overflow = 'visible';
            }

            const elementsToDelete = [];
            for (const [img, state] of managedElements.entries()) {
                if (!document.body.contains(img) || !document.body.contains(state.overlay)) { elementsToDelete.push(img); continue; }
                const rect = img.getBoundingClientRect();
                if (rect.width === 0 || rect.height === 0) {
                     if (state.overlay.classList.contains('is-visible-on-mobile')) {
                         state.overlay.classList.remove('is-visible-on-mobile');
                     }
                    continue;
                }

                Object.assign(state.overlay.style, {
                    top: `${rect.top + window.scrollY}px`, left: `${rect.left + window.scrollX}px`,
                    width: `${rect.width}px`, height: `${rect.height}px`
                });
                const fontSize = Math.max(rect.height * (settings.fontSizePercent / 100), 12);
                state.overlay.querySelectorAll('.gemini-ocr-text-box').forEach(box => {
                    box.style.fontSize = `${fontSize}px`;
                });
            }
            elementsToDelete.forEach(img => {
                const state = managedElements.get(img);
                if (state?.overlay) state.overlay.remove();
                managedElements.delete(img);
                logDebug(`Garbage collected overlay.`);
            });
        } catch (error) { logDebug(`Critical error in updateAllOverlays: ${error.message}`); }
        finally {
            overlayUpdateRunning = false;
            if (managedElements.size > 0) requestAnimationFrame(updateAllOverlays);
        }
    }

    // --- UI & EVENT HANDLING ---
    function createUI() {
        let conditionalStyles = '';
        if (window.location.href.includes('/chapter/')) {
            logDebug("URL contains '/chapter/', applying scrollbar fix.");
            conditionalStyles = `html { overflow: hidden !important; } body { overflow-y: auto !important; overflow-x: hidden !important; -webkit-user-select: none; user-select: none; }`;
        }
        GM_addStyle(`
            ${conditionalStyles}
            /* --- Base Overlay State --- */
            .gemini-ocr-decoupled-overlay {
                position: absolute; z-index: 9999;
                opacity: 0; visibility: hidden; pointer-events: none;
                transition: opacity 0.2s ease, visibility 0.2s ease;
            }
            .gemini-ocr-decoupled-overlay.is-visible-on-mobile {
                opacity: 1; visibility: visible;
            }
            .gemini-ocr-text-box {
                position: absolute; background: rgba(10,25,40,0.85);
                border: 2px solid rgba(0,191,255,0.6); color: white;
                text-shadow: 1px 1px 2px rgba(0,0,0,0.8); backdrop-filter: blur(2px);
                display: flex; align-items: center; justify-content: center; text-align: center;
                border-radius: 4px; box-sizing: border-box;
                transition: all 0.2s ease-in-out; user-select: text;
                transform: scale(1); white-space: preserve nowrap;
                pointer-events: auto;
            }
            .gemini-ocr-text-vertical { writing-mode: vertical-rl; text-orientation: upright; }

            /* --- MOBILE TAP-TO-HIGHLIGHT LOGIC --- */
            /* When an item is tapped, fade out the others */
            .gemini-ocr-decoupled-overlay.has-manual-highlight .gemini-ocr-text-box:not(.manual-highlight) {
                opacity: 0.3; background: rgba(10,25,40,0.5); border-color: rgba(0,191,255,0.3);
            }
            /* Style for the single highlighted box */
            .gemini-ocr-decoupled-overlay .manual-highlight {
                opacity: 1; transform: scale(1.05); background: rgba(0,191,255,0.9);
                border-color: rgba(255,255,255,0.9); color: #000; text-shadow: none;
                box-shadow: 0 0 10px rgba(0,191,255,0.5), inset 0 0 0 2px white; z-index: 10000;
            }

            /* --- Standard UI Elements --- */
            #gemini-ocr-settings-button { position: fixed; bottom: 15px; right: 15px; z-index: 2147483647; background: #1A1D21; color: #EAEAEA; border: 1px solid #555; border-radius: 50%; width: 50px; height: 50px; font-size: 26px; cursor: pointer; display: flex; align-items: center; justify-content: center; box-shadow: 0 4px 12px rgba(0,0,0,0.5); user-select: none; }
            .gemini-ocr-modal { position: fixed; top: 50%; left: 50%; transform: translate(-50%, -50%); background-color: #1A1D21; border: 1px solid #00BFFF; border-radius: 15px; z-index: 2147483647; color: #EAEAEA; font-family: sans-serif; box-shadow: 0 8px 32px 0 rgba(0,0,0,0.5); width: 600px; max-width: 90vw; max-height: 90vh; display: flex; flex-direction: column; }
            .gemini-ocr-modal.is-hidden { display: none; }
            .gemini-ocr-modal-header { padding: 20px 25px; border-bottom: 1px solid #444; }
            .gemini-ocr-modal-content { padding: 10px 25px; overflow-y: auto; flex-grow: 1; }
            .gemini-ocr-modal-footer { padding: 15px 25px; border-top: 1px solid #444; display: flex; justify-content: flex-end; gap: 10px; align-items: center; }
            .gemini-ocr-modal h2 { margin: 0; color: #00BFFF; } .gemini-ocr-modal h3 { font-size: 1.1em; margin: 15px 0 10px 0; border-bottom: 1px solid #333; padding-bottom: 5px; color: #00BFFF; }
            .gemini-ocr-settings-grid { display: grid; grid-template-columns: max-content 1fr; gap: 10px 15px; align-items: center; } .full-width { grid-column: 1 / -1; }
            .gemini-ocr-modal input, .gemini-ocr-modal textarea, .gemini-ocr-modal select { width: 100%; padding: 8px; box-sizing: border-box; font-family: monospace; background-color: #2a2a2e; border: 1px solid #555; border-radius: 5px; color: #EAEAEA; }
            .gemini-ocr-modal button { padding: 10px 18px; background-color: #00BFFF; border: none; border-radius: 5px; color: #1A1D21; cursor: pointer; font-weight: bold; }
            #gemini-ocr-server-status { padding: 10px; border-radius: 5px; text-align: center; cursor: pointer; transition: background-color 0.3s; }
            #gemini-ocr-server-status.status-ok { background-color: #27ae60; } #gemini-ocr-server-status.status-error { background-color: #c0392b; } #gemini-ocr-server-status.status-checking { background-color: #3498db; }
        `);
        document.body.insertAdjacentHTML('beforeend', `
            <button id="gemini-ocr-settings-button">⚙️</button>
            <div id="gemini-ocr-settings-modal" class="gemini-ocr-modal is-hidden">
                <div class="gemini-ocr-modal-header"><h2>Local OCR Settings (v23.5.9 Mobile)</h2></div>
                <div class="gemini-ocr-modal-content">
                    <h3>Connection</h3><div class="gemini-ocr-settings-grid full-width"><label for="gemini-ocr-server-url">OCR Server URL:</label><input type="text" id="gemini-ocr-server-url"></div>
                    <div id="gemini-ocr-server-status" class="full-width" style="margin-top: 10px;">Click to check server status</div>
                    <h3>Display</h3><div class="gemini-ocr-settings-grid">
                        <label for="ocr-text-orientation">Text Orientation:</label><select id="ocr-text-orientation"><option value="smart">Smart</option><option value="forceHorizontal">Horizontal</option><option value="forceVertical">Vertical</option></select>
                        <label for="ocr-font-size">Font Size (%):</label><input type="number" id="ocr-font-size" min="1" max="50" step="0.5" style="width: 80px;">
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
            debugModal: document.getElementById('gemini-ocr-debug-modal'), serverUrlInput: document.getElementById('gemini-ocr-server-url'),
            debugModeCheckbox: document.getElementById('gemini-ocr-debug-mode'),
            textOrientationSelect: document.getElementById('ocr-text-orientation'),
            fontSizeInput: document.getElementById('ocr-font-size'), sitesConfigTextarea: document.getElementById('gemini-ocr-sites-config'),
            statusDiv: document.getElementById('gemini-ocr-server-status'), debugLogTextarea: document.getElementById('gemini-ocr-debug-log'),
            saveBtn: document.getElementById('gemini-ocr-save-btn'), closeBtn: document.getElementById('gemini-ocr-close-btn'),
            debugBtn: document.getElementById('gemini-ocr-debug-btn'), closeDebugBtn: document.getElementById('gemini-ocr-close-debug-btn'),
        });
        UI.settingsButton.addEventListener('click', () => UI.settingsModal.classList.toggle('is-hidden'));
        UI.statusDiv.addEventListener('click', checkServerStatus);
        UI.closeBtn.addEventListener('click', () => UI.settingsModal.classList.add('is-hidden'));
        UI.debugBtn.addEventListener('click', () => { UI.debugLogTextarea.value = debugLog.join('\n'); UI.debugModal.classList.remove('is-hidden'); UI.debugLogTextarea.scrollTop = UI.debugLogTextarea.scrollHeight; });
        UI.closeDebugBtn.addEventListener('click', () => UI.debugModal.classList.add('is-hidden'));

        UI.saveBtn.addEventListener('click', async () => {
            const newSettings = {
                ocrServerUrl: UI.serverUrlInput.value.trim(), debugMode: UI.debugModeCheckbox.checked,
                textOrientation: UI.textOrientationSelect.value, fontSizePercent: parseFloat(UI.fontSizeInput.value) || 4.5,
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

    // --- SCRIPT INITIALIZATION ---
    async function init() {
        const loadedSettings = await GM_getValue(SETTINGS_KEY);
        // Smartly merge settings to ensure new defaults are included
        if (loadedSettings) {
            try {
                const parsedSettings = JSON.parse(loadedSettings);
                const defaultSite = settings.sites[0];
                const loadedSite = parsedSettings.sites?.find(s => s.urlPattern === defaultSite.urlPattern);
                settings = { ...settings, ...parsedSettings };
                if (loadedSite) {
                    const combinedSelectors = [...defaultSite.imageContainerSelectors, ...loadedSite.imageContainerSelectors];
                    loadedSite.imageContainerSelectors = [...new Set(combinedSelectors)];
                    settings.sites = parsedSettings.sites;
                }
            } catch(e) {
                logDebug("Could not parse saved settings. Using defaults.");
            }
        }
        createUI();
        await PersistentCache.load();
        bindUIEvents();
        // Populate the UI with the final, potentially merged, settings
        UI.serverUrlInput.value = settings.ocrServerUrl;
        UI.debugModeCheckbox.checked = settings.debugMode;
        UI.textOrientationSelect.value = settings.textOrientation;
        UI.fontSizeInput.value = settings.fontSizePercent;
        UI.sitesConfigTextarea.value = settings.sites.map(s => [s.urlPattern, s.overflowFixSelector, ...(s.imageContainerSelectors || [])].join('; ')).join('\n');
        activateScanner();
    }
    init().catch(e => console.error(`[OCR v23.5.9 Mobile] Fatal Initialization Error: ${e.message}`));
})();
