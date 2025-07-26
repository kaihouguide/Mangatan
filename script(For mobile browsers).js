// ==UserScript==
// @name         Automatic Content OCR (v21.6.42 - Mobile Port, Updated & Refactored)
// @namespace    http://tampermonkey.net/
// @version      21.6.42.3
// @description  Passes image source credentials through the OCR server. Updated and refactored for mobile speed.
// @author       1Selxo & Gemini
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
                'div.muiltr-masn8', 'div.muiltr-79elbk', 'div.muiltr-u43rde',
                'div.muiltr-1r1or1s', 'div.muiltr-18sieki', 'div.muiltr-cns6dc',
                '.MuiBox-root.muiltr-1noqzsz'
            ],
            overflowFixSelector: '.MuiBox-root.muiltr-13djdhf'
        }],
        debugMode: true,
        textOrientation: 'smart',
        interactionMode: 'click', // Retain mobile-friendly default
        colorTheme: 'deepblue',
        fontMultiplierHorizontal: 1.0,
        fontMultiplierVertical: 1.0
    };
    let debugLog = [];
    const SETTINGS_KEY = 'gemini_ocr_settings_v21_6_mobile_credential_forward'; // Keep original key for compatibility
    const ocrDataCache = new WeakMap();
    const managedElements = new Map();
    const managedContainers = new Map();
    const attachedAttributeObservers = new WeakMap();
    let activeSiteConfig = null;
    let overlayUpdateRunning = false;
    let measurementSpan = null;
    const UI = {};
    let activeImageForExport = null;

    const COLOR_THEMES = {
        deepblue: { main: 'rgba(0,191,255,',  text: '#FFFFFF', highlightText: '#000000' },
        red:      { main: 'rgba(255, 71, 87,',   text: '#FFFFFF', highlightText: '#000000' },
        green:    { main: 'rgba(46, 204, 113,',  text: '#FFFFFF', highlightText: '#000000' }
    };

    const logDebug = (message) => {
        if (!settings.debugMode) return;
        const timestamp = new Date().toLocaleTimeString();
        const logEntry = `[${timestamp}] ${message}`;
        console.log(`[OCR v21.6.42 Mobile] ${logEntry}`);
        debugLog.push(logEntry);
        document.dispatchEvent(new CustomEvent('ocr-log-update'));
    };

    const imageObserver = new MutationObserver((mutations) => {
        for (const mutation of mutations) {
            for (const node of mutation.addedNodes) {
                if (node.nodeType === 1) {
                    if (node.tagName === 'IMG') {
                        observeImageForSrcChange(node);
                    } else {
                        node.querySelectorAll('img').forEach(observeImageForSrcChange);
                    }
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
                if (node.nodeType === 1) {
                    if (node.matches(selectorQuery)) {
                        manageContainer(node);
                    } else {
                        node.querySelectorAll(selectorQuery).forEach(manageContainer);
                    }
                }
            }
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

    function observeImageForSrcChange(img) {
        const processTheImage = (src) => {
            if (src?.includes('/api/v1/manga/')) {
                img.crossOrigin = "anonymous";
                if (img.complete && img.naturalHeight > 0) {
                    processImage(img);
                } else {
                    img.addEventListener('load', () => processImage(img), { once: true });
                }
                return true;
            }
            return false;
        };
        if (processTheImage(img.src)) return;
        if (attachedAttributeObservers.has(img)) return;
        const attributeObserver = new MutationObserver((mutations) => {
            for (const mutation of mutations) {
                if (mutation.attributeName === 'src' && processTheImage(img.src)) {
                    attributeObserver.disconnect();
                    attachedAttributeObservers.delete(img);
                    break;
                }
            }
        });
        attributeObserver.observe(img, { attributes: true });
        attachedAttributeObservers.set(img, attributeObserver);
    }

    // ##### UPDATED FUNCTION #####
    function processImage(img) {
        if (ocrDataCache.get(img) === 'pending') return;
        if (managedElements.has(img)) {
            managedElements.get(img).overlay.remove();
            managedElements.delete(img);
        }
        const sourceUrl = img.src;
        logDebug(`Requesting OCR for ...${sourceUrl.slice(-30)}`);
        ocrDataCache.set(img, 'pending');

        let ocrRequestUrl = `${settings.ocrServerUrl}/ocr?url=${encodeURIComponent(sourceUrl)}`;

        // *** THIS IS THE INTEGRATED UPDATE FROM THE PC VERSION ***
        if (settings.imageServerUser) {
            logDebug("Forwarding image server credentials to OCR server.");
            ocrRequestUrl += `&user=${encodeURIComponent(settings.imageServerUser)}`;
            ocrRequestUrl += `&pass=${encodeURIComponent(settings.imageServerPassword)}`;
        }
        // *** END OF UPDATE ***

        GM_xmlhttpRequest({
            method: 'GET',
            url: ocrRequestUrl,
            timeout: 30000,
            onload: (res) => {
                try {
                    const data = JSON.parse(res.responseText);
                    if (data.error) throw new Error(data.error);
                    ocrDataCache.set(img, data);
                    logDebug(`OCR success for ...${sourceUrl.slice(-30)}`);
                    displayOcrResults(img);
                } catch (e) { logDebug(`OCR Error: ${e.message}`); ocrDataCache.delete(img); }
            },
            onerror: (res) => { logDebug(`Connection error. Status: ${res.status}`); ocrDataCache.delete(img); },
            ontimeout: () => { logDebug(`Request timed out.`); ocrDataCache.delete(img); }
        });
    }

    // ##### REFACTORED AND OPTIMIZED FUNCTIONS #####
    function displayOcrResults(targetImg) {
        const data = ocrDataCache.get(targetImg);
        if (!data || data === 'pending' || managedElements.has(targetImg)) return;

        data.sort((a, b) => {
            const a_y = a.tightBoundingBox.y; const b_y = b.tightBoundingBox.y;
            if (Math.abs(a_y - b_y) < 0.05) return b.tightBoundingBox.x - a.tightBoundingBox.x;
            return a_y - b_y;
        });

        const overlay = document.createElement('div');
        overlay.className = `gemini-ocr-decoupled-overlay is-hidden interaction-mode-${settings.interactionMode}`;
        const fragment = document.createDocumentFragment();
        const imgRect = targetImg.getBoundingClientRect();

        data.forEach((item) => {
            const ocrBox = document.createElement('div');
            ocrBox.className = 'gemini-ocr-text-box';
            ocrBox.textContent = item.text;
            ocrBox.dataset.ocrWidth = item.tightBoundingBox.width;
            ocrBox.dataset.ocrHeight = item.tightBoundingBox.height;

            const pixelWidth = item.tightBoundingBox.width * imgRect.width;
            const pixelHeight = item.tightBoundingBox.height * imgRect.height;

            const isVertical = (settings.textOrientation === 'forceVertical') ||
                             (settings.textOrientation === 'smart' && (pixelHeight > pixelWidth || item.orientation === 90)) ||
                             (settings.textOrientation === 'serverAngle' && item.orientation === 90);

            if (isVertical) ocrBox.classList.add('gemini-ocr-text-vertical');
            Object.assign(ocrBox.style, {
                left: `${item.tightBoundingBox.x * 100}%`, top: `${item.tightBoundingBox.y * 100}%`,
                width: `${item.tightBoundingBox.width * 100}%`, height: `${item.tightBoundingBox.height * 100}%`
            });
            fragment.appendChild(ocrBox);
        });

        overlay.appendChild(fragment);
        document.body.appendChild(overlay);

        const state = { overlay, lastWidth: 0, lastHeight: 0 };
        managedElements.set(targetImg, state);
        logDebug(`Created overlay for ...${targetImg.src.slice(-30)}`);

        // Refactored Touch Logic for better performance and reliability
        const showOverlay = (e) => {
            e.stopPropagation();
            managedElements.forEach((s, i) => {
                if (i !== targetImg) s.overlay.classList.add('is-hidden');
            });
            overlay.classList.remove('is-hidden');
            UI.globalAnkiButton?.classList.remove('is-hidden');
            activeImageForExport = targetImg;
        };

        targetImg.addEventListener('click', showOverlay);
        overlay.addEventListener('click', (e) => {
            e.stopPropagation(); // Prevent clicks on boxes from hiding the overlay
            const clickedBox = e.target.closest('.gemini-ocr-text-box');
            overlay.querySelectorAll('.manual-highlight').forEach(b => b.classList.remove('manual-highlight'));
            if (clickedBox) clickedBox.classList.add('manual-highlight');
        });

        if (!overlayUpdateRunning) requestAnimationFrame(updateAllOverlays);
    }

    // This listener efficiently handles hiding the overlay when tapping outside
    document.addEventListener('click', (e) => {
        if (activeImageForExport && managedElements.has(activeImageForExport)) {
            const state = managedElements.get(activeImageForExport);
            if (!state.overlay.contains(e.target) && e.target !== activeImageForExport) {
                 state.overlay.classList.add('is-hidden');
                 UI.globalAnkiButton?.classList.add('is-hidden');
                 activeImageForExport = null;
            }
        }
    }, true); // Use capture phase to ensure it runs before other clicks

    function calculateAndApplyFontSizes(overlay, imgRect) {
        if (!measurementSpan) return;
        const textBoxes = overlay.querySelectorAll('.gemini-ocr-text-box');
        if (textBoxes.length === 0) return;

        const baseStyle = getComputedStyle(textBoxes[0]);
        Object.assign(measurementSpan.style, {
            fontFamily: baseStyle.fontFamily, fontWeight: baseStyle.fontWeight,
            letterSpacing: baseStyle.letterSpacing, lineHeight: '1',
        });

        textBoxes.forEach(box => {
            const text = box.textContent || '';
            if (!text) return;
            const availableWidth = parseFloat(box.dataset.ocrWidth) * imgRect.width - 8;
            const availableHeight = parseFloat(box.dataset.ocrHeight) * imgRect.height - 8;
            if (availableWidth <= 0 || availableHeight <= 0) return;

            let bestSize = 8; let multiplier;
            measurementSpan.textContent = text;
            const isVertical = box.classList.contains('gemini-ocr-text-vertical');
            if (isVertical) {
                measurementSpan.style.writingMode = 'vertical-rl';
                measurementSpan.style.textOrientation = 'upright';
                multiplier = settings.fontMultiplierVertical;
            } else {
                box.style.whiteSpace = 'nowrap';
                multiplier = settings.fontMultiplierHorizontal;
            }

            let low = 8, high = 150;
            while (low <= high) {
                const mid = Math.floor((low + high) / 2);
                if (mid <= 0) break;
                measurementSpan.style.fontSize = `${mid}px`;
                const checkWidth = isVertical ? measurementSpan.offsetHeight : measurementSpan.offsetWidth;
                const checkHeight = isVertical ? measurementSpan.offsetWidth : measurementSpan.offsetHeight;
                if ((checkWidth <= availableWidth) && (checkHeight <= availableHeight)) {
                    bestSize = mid; low = mid + 1;
                } else { high = mid - 1; }
            }
            if (isVertical) {
                measurementSpan.style.writingMode = '';
                measurementSpan.style.textOrientation = '';
            } else {
                box.style.whiteSpace = 'normal';
            }
            box.style.fontSize = `${bestSize * multiplier}px`;
        });
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
                if (!document.body.contains(img) || !document.body.contains(state.overlay)) {
                    elementsToDelete.push(img); continue;
                }
                const rect = img.getBoundingClientRect();
                if (rect.width === 0 || rect.height === 0) {
                    if (!state.overlay.classList.contains('is-hidden')) state.overlay.classList.add('is-hidden');
                    continue;
                }
                Object.assign(state.overlay.style, {
                    top: `${rect.top + window.scrollY}px`, left: `${rect.left + window.scrollX}px`,
                    width: `${rect.width}px`, height: `${rect.height}px`
                });
                if (state.lastWidth !== rect.width || state.lastHeight !== rect.height) {
                    calculateAndApplyFontSizes(state.overlay, rect);
                    state.lastWidth = rect.width; state.lastHeight = rect.height;
                }
            }
            elementsToDelete.forEach(img => {
                managedElements.get(img)?.overlay.remove();
                managedElements.delete(img);
                logDebug(`Garbage collected overlay.`);
            });
        } catch (error) { logDebug(`Critical error in updateAllOverlays: ${error.message}`); }
        finally {
            overlayUpdateRunning = managedElements.size > 0;
            if (overlayUpdateRunning) requestAnimationFrame(updateAllOverlays);
        }
    }

    // --- ANKI, UI, AND INITIALIZATION (Retained from mobile script) ---
    async function ankiConnectRequest(action, params = {}) {
        logDebug(`Anki-Connect: Firing action '${action}'`);
        return new Promise((resolve, reject) => {
            GM_xmlhttpRequest({
                method: 'POST', url: settings.ankiConnectUrl,
                data: JSON.stringify({ action, version: 6, params }),
                headers: { 'Content-Type': 'application/json; charset=UTF-8' }, timeout: 15000,
                onload: (res) => { try { const data = JSON.parse(res.responseText); if (data.error) reject(new Error(data.error)); else resolve(data.result); } catch (e) { reject(new Error('Failed to parse Anki-Connect response.')); } },
                onerror: () => reject(new Error('Connection to Anki-Connect failed.')),
                ontimeout: () => reject(new Error('Anki-Connect request timed out.'))
            });
        });
    }

    async function exportImageToAnki(targetImg) {
        logDebug(`Anki Export: Starting...`);
        if (!settings.ankiImageField) { alert('Anki Image Field is not set.'); return false; }
        if (!targetImg || !targetImg.complete || !targetImg.naturalHeight) { alert('Anki Export Failed: Image not valid.'); return false; }
        try {
            const canvas = document.createElement('canvas');
            canvas.width = targetImg.naturalWidth; canvas.height = targetImg.naturalHeight;
            const ctx = canvas.getContext('2d');
            ctx.drawImage(targetImg, 0, 0);
            const base64data = canvas.toDataURL('image/png').split(',')[1];
            const filename = `screenshot_${Date.now()}.png`;
            await ankiConnectRequest('storeMediaFile', { filename, data: base64data });
            logDebug(`Anki Export: Image stored as '${filename}'`);
            const notes = await ankiConnectRequest('findNotes', { query: 'added:1' });
            if (!notes || notes.length === 0) throw new Error('No recently added cards found. Create a card first.');
            const lastNoteId = notes.sort((a, b) => b - a)[0];
            await ankiConnectRequest('updateNoteFields', { note: { id: lastNoteId, fields: { [settings.ankiImageField]: `<img src="${filename}">` } } });
            logDebug(`Anki Export: Success for note ${lastNoteId}.`);
            return true;
        } catch (error) {
            logDebug(`Anki Export Error: ${error.message}`);
            alert(`Anki Export Failed: ${error.message}`);
            return false;
        }
    }

    function manageScrollFix() {
        const urlPattern = '/manga/';
        const shouldBeActive = window.location.href.includes(urlPattern);
        const isActive = document.documentElement.classList.contains('ocr-scroll-fix-active');
        if (shouldBeActive && !isActive) document.documentElement.classList.add('ocr-scroll-fix-active');
        else if (!shouldBeActive && isActive) document.documentElement.classList.remove('ocr-scroll-fix-active');
    }

    function applyColorTheme() {
        const theme = COLOR_THEMES[settings.colorTheme] || COLOR_THEMES.deepblue;
        const cssVars = `:root {
            --ocr-bg-color: rgba(10,25,40,0.85); --ocr-border-color: ${theme.main}0.6);
            --ocr-border-color-dim: ${theme.main}0.3); --ocr-border-color-hover: ${theme.main}0.8);
            --ocr-text-color: ${theme.text}; --ocr-highlight-bg-color: ${theme.main}0.9);
            --ocr-highlight-border-color: rgba(255,255,255,0.9); --ocr-highlight-text-color: ${theme.highlightText};
            --modal-header-color: ${theme.main}1);
        }`;
        let styleTag = document.getElementById('gemini-ocr-color-theme-style');
        if (!styleTag) {
            styleTag = document.createElement('style'); styleTag.id = 'gemini-ocr-color-theme-style';
            document.head.appendChild(styleTag);
        }
        styleTag.textContent = cssVars;
    }

    function createUI() {
        GM_addStyle(`
            html.ocr-scroll-fix-active{overflow:hidden!important}html.ocr-scroll-fix-active body{overflow-y:auto!important;overflow-x:hidden!important}
            .gemini-ocr-decoupled-overlay{position:absolute;z-index:9998;pointer-events:none!important;transition:opacity .15s,visibility .15s}
            .gemini-ocr-decoupled-overlay.is-hidden{opacity:0;visibility:hidden}
            .gemini-ocr-text-box{position:absolute;display:grid;place-items:center;text-align:center;box-sizing:border-box;border-radius:4px;user-select:text;cursor:pointer;background:var(--ocr-bg-color);border:2px solid var(--ocr-border-color);color:var(--ocr-text-color);text-shadow:1px 1px 2px rgba(0,0,0,.8);backdrop-filter:blur(2px);transition:all .2s ease-in-out;pointer-events:auto!important;overflow:hidden;padding:4px}
            .gemini-ocr-text-vertical{writing-mode:vertical-rl!important;text-orientation:upright!important}
            .interaction-mode-click.is-focused .manual-highlight{transform:scale(1.05);background:var(--ocr-highlight-bg-color);border-color:var(--ocr-highlight-border-color);color:var(--ocr-highlight-text-color);text-shadow:none;box-shadow:0 0 10px var(--ocr-highlight-shadow),inset 0 0 0 2px #fff;z-index:9999}
            #gemini-ocr-settings-button{position:fixed;bottom:15px;right:15px;z-index:2147483647;background:#1a1d21;color:#eaeaea;border:1px solid #555;border-radius:50%;width:55px;height:55px;font-size:30px;cursor:pointer;display:flex;align-items:center;justify-content:center;box-shadow:0 4px 12px rgba(0,0,0,.5);user-select:none}
            #gemini-ocr-global-anki-export-btn{position:fixed;bottom:85px;right:15px;z-index:2147483646;background-color:#2ecc71;color:#fff;border:1px solid #fff;border-radius:50%;width:55px;height:55px;font-size:36px;line-height:55px;text-align:center;cursor:pointer;transition:all .2s ease-in-out;user-select:none;box-shadow:0 4px 12px rgba(0,0,0,.5)}
            #gemini-ocr-global-anki-export-btn:disabled{background-color:#95a5a6;cursor:wait;transform:none}
            #gemini-ocr-global-anki-export-btn.is-hidden{opacity:0;visibility:hidden;pointer-events:none;transform:scale(.5)}
            .gemini-ocr-modal{position:fixed;top:0;left:0;width:100vw;height:100vh;background-color:#1a1d21;border:1px solid var(--modal-header-color);z-index:2147483647;color:#eaeaea;font-family:sans-serif;display:flex;flex-direction:column}
            .gemini-ocr-modal.is-hidden{display:none}
            .gemini-ocr-modal-header{padding:20px 25px;border-bottom:1px solid #444}.gemini-ocr-modal-header h2{margin:0;color:var(--modal-header-color);font-size:1.2em}
            .gemini-ocr-modal-content{padding:10px 25px;overflow-y:auto;flex-grow:1;-webkit-overflow-scrolling:touch}
            .gemini-ocr-modal-footer{padding:15px 25px;border-top:1px solid #444;display:flex;justify-content:flex-end;gap:10px;align-items:center;flex-wrap:wrap}
            .gemini-ocr-modal h3{font-size:1.1em;margin:20px 0 15px;border-bottom:1px solid #333;padding-bottom:8px;color:var(--modal-header-color)}
            .gemini-ocr-settings-grid{display:grid;grid-template-columns:1fr;gap:15px}
            .gemini-ocr-modal input,.gemini-ocr-modal textarea,.gemini-ocr-modal select{width:100%;padding:12px;box-sizing:border-box;font-size:16px;background-color:#2a2a2e;border:1px solid #555;border-radius:5px;color:#eaeaea}
            .gemini-ocr-modal button{padding:12px 20px;border-radius:5px;cursor:pointer;font-weight:700;font-size:16px;background-color:var(--modal-header-color);border:none;color:#1a1d21}
            #gemini-ocr-server-status{padding:12px;border-radius:5px;text-align:center;cursor:pointer;transition:background-color .3s}
            #gemini-ocr-server-status.status-ok{background-color:#27ae60}#gemini-ocr-server-status.status-error{background-color:#c0392b}#gemini-ocr-server-status.status-checking{background-color:#3498db}
        `);
        document.body.insertAdjacentHTML('beforeend', `
            <button id="gemini-ocr-global-anki-export-btn" class="is-hidden" title="Export Screenshot to Anki">✚</button>
            <button id="gemini-ocr-settings-button">⚙️</button>
            <div id="gemini-ocr-settings-modal" class="gemini-ocr-modal is-hidden">
                <div class="gemini-ocr-modal-header"><h2>Automatic Content OCR Settings</h2></div>
                <div class="gemini-ocr-modal-content">
                    <h3>OCR & Image Source</h3><div class="gemini-ocr-settings-grid">
                        <label for="gemini-ocr-server-url">OCR Server URL:</label><input type="text" id="gemini-ocr-server-url">
                        <label for="gemini-image-server-user">Image Source Username:</label><input type="text" id="gemini-image-server-user" autocomplete="username" placeholder="Optional">
                        <label for="gemini-image-server-password">Image Source Password:</label><input type="password" id="gemini-image-server-password" autocomplete="current-password" placeholder="Optional">
                    </div>
                    <div id="gemini-ocr-server-status" style="margin-top:10px">Click to check server status</div>
                    <h3>Anki Integration</h3><div class="gemini-ocr-settings-grid">
                        <label for="gemini-ocr-anki-url">Anki-Connect URL:</label><input type="text" id="gemini-ocr-anki-url">
                        <label for="gemini-ocr-anki-field">Image Field Name:</label><input type="text" id="gemini-ocr-anki-field" placeholder="e.g., Image">
                    </div>
                    <h3>Interaction & Display</h3><div class="gemini-ocr-settings-grid">
                        <label for="ocr-color-theme">Color Theme:</label><select id="ocr-color-theme">${Object.keys(COLOR_THEMES).map(t=>`<option value="${t}">${t.charAt(0).toUpperCase()+t.slice(1)}</option>`).join('')}</select>
                        <label for="ocr-interaction-mode">Highlight Mode:</label><select id="ocr-interaction-mode"><option value="hover">Hover</option><option value="click">Click</option></select>
                        <label for="ocr-text-orientation">Text Orientation:</label><select id="ocr-text-orientation"><option value="smart">Smart</option><option value="serverAngle">Server</option><option value="forceHorizontal">Horizontal</option><option value="forceVertical">Vertical</option></select>
                    </div>
                    <h3>Advanced</h3><div class="gemini-ocr-settings-grid"><label><input type="checkbox" id="gemini-ocr-debug-mode"> Debug Mode</label></div>
                </div>
                <div class="gemini-ocr-modal-footer"><button id="gemini-ocr-close-btn" style="background-color:#555">Close</button><button id="gemini-ocr-save-btn">Save & Reload</button></div>
            </div>`);
    }

    function bindUIEvents() {
        Object.assign(UI, {
            settingsButton: document.getElementById('gemini-ocr-settings-button'), settingsModal: document.getElementById('gemini-ocr-settings-modal'),
            globalAnkiButton: document.getElementById('gemini-ocr-global-anki-export-btn'),
            serverUrlInput: document.getElementById('gemini-ocr-server-url'),
            imageServerUserInput: document.getElementById('gemini-image-server-user'), imageServerPasswordInput: document.getElementById('gemini-image-server-password'),
            ankiUrlInput: document.getElementById('gemini-ocr-anki-url'), ankiFieldInput: document.getElementById('gemini-ocr-anki-field'),
            debugModeCheckbox: document.getElementById('gemini-ocr-debug-mode'),
            interactionModeSelect: document.getElementById('ocr-interaction-mode'), textOrientationSelect: document.getElementById('ocr-text-orientation'),
            colorThemeSelect: document.getElementById('ocr-color-theme'),
            statusDiv: document.getElementById('gemini-ocr-server-status'),
            saveBtn: document.getElementById('gemini-ocr-save-btn'),
            closeBtn: document.getElementById('gemini-ocr-close-btn'),
        });
        UI.settingsButton.addEventListener('click', () => UI.settingsModal.classList.toggle('is-hidden'));
        UI.globalAnkiButton.addEventListener('click', async () => {
            if (!activeImageForExport) { alert("Tap an image to select it for export."); return; }
            const btn = UI.globalAnkiButton;
            btn.textContent = '…'; btn.disabled = true;
            const success = await exportImageToAnki(activeImageForExport);
            btn.textContent = success ? '✓' : '✖';
            btn.style.backgroundColor = success ? '#27ae60' : '#c0392b';
            setTimeout(() => { btn.textContent = '✚'; btn.style.backgroundColor = ''; btn.disabled = false; }, 2000);
        });
        UI.statusDiv.addEventListener('click', checkServerStatus);
        UI.closeBtn.addEventListener('click', () => UI.settingsModal.classList.add('is-hidden'));
        UI.colorThemeSelect.addEventListener('change', () => {
            settings.colorTheme = UI.colorThemeSelect.value;
            applyColorTheme();
        });
        UI.saveBtn.addEventListener('click', async () => {
            const newSettings = {
                ocrServerUrl: UI.serverUrlInput.value.trim(),
                imageServerUser: UI.imageServerUserInput.value.trim(),
                imageServerPassword: UI.imageServerPasswordInput.value,
                ankiConnectUrl: UI.ankiUrlInput.value.trim(),
                ankiImageField: UI.ankiFieldInput.value.trim(),
                debugMode: UI.debugModeCheckbox.checked,
                interactionMode: UI.interactionModeSelect.value,
                textOrientation: UI.textOrientationSelect.value,
                colorTheme: UI.colorThemeSelect.value
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
    }

    function checkServerStatus() {
        const serverUrl = UI.serverUrlInput.value.trim(); if (!serverUrl) return;
        UI.statusDiv.className = 'status-checking'; UI.statusDiv.textContent = 'Checking...';
        GM_xmlhttpRequest({
            method: 'GET', url: serverUrl, timeout: 5000,
            onload: (res) => { try { const data = JSON.parse(res.responseText); UI.statusDiv.className = data.status === 'running' ? 'status-ok' : 'status-error'; UI.statusDiv.textContent = data.status === 'running' ? `Connected` : 'Unresponsive'; } catch (e) { UI.statusDiv.className = 'status-error'; UI.statusDiv.textContent = 'Invalid Response'; } },
            onerror: () => { UI.statusDiv.className = 'status-error'; UI.statusDiv.textContent = 'Connection Failed'; },
            ontimeout: () => { UI.statusDiv.className = 'status-error'; UI.statusDiv.textContent = 'Timed Out'; }
        });
    }

    function createMeasurementSpan() {
        if (measurementSpan) return;
        measurementSpan = document.createElement('span');
        measurementSpan.style.cssText = `position:absolute!important;visibility:hidden!important;height:auto!important;width:auto!important;white-space:nowrap!important;z-index:-1!important;`;
        document.body.appendChild(measurementSpan);
        logDebug("Created shared measurement span.");
    }

    async function init() {
        const loadedSettings = await GM_getValue(SETTINGS_KEY);
        if (loadedSettings) {
            try {
                // Only overwrite settings that exist in the loaded data
                const parsed = JSON.parse(loadedSettings);
                Object.keys(settings).forEach(key => {
                    if (parsed[key] !== undefined) settings[key] = parsed[key];
                });
            } catch(e) { logDebug("Could not parse saved settings. Using defaults."); }
        }
        createUI();
        bindUIEvents();
        applyColorTheme();
        createMeasurementSpan();

        UI.serverUrlInput.value = settings.ocrServerUrl;
        UI.imageServerUserInput.value = settings.imageServerUser || '';
        UI.imageServerPasswordInput.value = settings.imageServerPassword || '';
        UI.ankiUrlInput.value = settings.ankiConnectUrl;
        UI.ankiFieldInput.value = settings.ankiImageField;
        UI.debugModeCheckbox.checked = settings.debugMode;
        UI.interactionModeSelect.value = settings.interactionMode;
        UI.textOrientationSelect.value = settings.textOrientation;
        UI.colorThemeSelect.value = settings.colorTheme;

        setInterval(manageScrollFix, 1000); // Less frequent check is fine for this
        activateScanner();
    }
    init().catch(e => console.error(`[OCR] Fatal Initialization Error: ${e.message}`));
})();
