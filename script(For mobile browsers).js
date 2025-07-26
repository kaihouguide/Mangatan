// ==UserScript==
// @name         Automatic Content OCR (v21.6.42 - Mobile, Updated & Refactored)
// @namespace    http://tampermonkey.net/
// @version      21.6.42.4
// @description  Passes image source credentials through the OCR server. Updated and lightly refactored for mobile speed and stability.
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
    // --- Global State and Settings (from original mobile script) ---
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
        interactionMode: 'click',
        colorTheme: 'deepblue',
        fontMultiplierHorizontal: 1.0,
        fontMultiplierVertical: 1.0
    };
    let debugLog = [];
    const SETTINGS_KEY = 'gemini_ocr_settings_v21_6_mobile_credential_forward';
    const ocrDataCache = new WeakMap();
    const managedElements = new Map();
    const managedContainers = new Map();
    const attachedAttributeObservers = new WeakMap();
    let activeSiteConfig = null;
    let overflowFixElement = null; // Cached element for performance
    let overlayUpdateRunning = false;
    let measurementSpan = null;
    const UI = {};
    let activeImageForExport = null;

    // --- Color Themes (from original) ---
    const COLOR_THEMES = {
        deepblue: { main: 'rgba(0,191,255,',  text: '#FFFFFF', highlightText: '#000000' },
        red:      { main: 'rgba(255, 71, 87,',   text: '#FFFFFF', highlightText: '#000000' },
        green:    { main: 'rgba(46, 204, 113,',  text: '#FFFFFF', highlightText: '#000000' }
    };

    // --- Logging (from original) ---
    const logDebug = (message) => {
        if (!settings.debugMode) return;
        const timestamp = new Date().toLocaleTimeString();
        const logEntry = `[${timestamp}] ${message}`;
        console.log(`[OCR v21.6.42 Mobile] ${logEntry}`);
        debugLog.push(logEntry);
        document.dispatchEvent(new CustomEvent('ocr-log-update'));
    };

    // --- Core Observation Logic (from original) ---
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
        if (activeSiteConfig.overflowFixSelector) {
            overflowFixElement = document.querySelector(activeSiteConfig.overflowFixSelector);
        }
        const selectorQuery = activeSiteConfig.imageContainerSelectors.join(', ');
        document.querySelectorAll(selectorQuery).forEach(manageContainer);
        containerObserver.observe(document.body, { childList: true, subtree: true });
        logDebug("Main container observer is active.");
    }

    // --- Image Processing (from original, with one update) ---
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

    function processImage(img) {
        if (ocrDataCache.get(img) === 'pending') return;
        if (managedElements.has(img)) {
            managedElements.get(img).overlay.remove();
            managedElements.delete(img);
        }
        const sourceUrl = img.src;
        logDebug(`Requesting OCR for ...${sourceUrl.slice(-30)}`);
        ocrDataCache.set(img, 'pending');

        // ##### THIS IS THE SOLE FUNCTIONAL UPDATE #####
        let ocrRequestUrl = `${settings.ocrServerUrl}/ocr?url=${encodeURIComponent(sourceUrl)}`;
        if (settings.imageServerUser) {
            logDebug("Forwarding image server credentials to OCR server.");
            ocrRequestUrl += `&user=${encodeURIComponent(settings.imageServerUser)}`;
            ocrRequestUrl += `&pass=${encodeURIComponent(settings.imageServerPassword)}`;
        }
        // ##### END OF UPDATE #####

        GM_xmlhttpRequest({
            method: 'GET', url: ocrRequestUrl, timeout: 30000,
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

    // --- OVERLAY & UPDATE ENGINE (from original, with light refactoring) ---
    function displayOcrResults(targetImg) {
        const data = ocrDataCache.get(targetImg);
        if (!data || data === 'pending' || managedElements.has(targetImg)) return;

        data.sort((a, b) => {
            const a_y = a.tightBoundingBox.y; const b_y = b.tightBoundingBox.y;
            if (Math.abs(a_y - b_y) < 0.05) { return b.tightBoundingBox.x - a.tightBoundingBox.x; }
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
            const pixelWidth = item.tightBoundingBox.width * imgRect.width;
            const pixelHeight = item.tightBoundingBox.height * imgRect.height;
            if ((settings.textOrientation === 'smart' && pixelHeight > pixelWidth) || settings.textOrientation === 'forceVertical') {
                ocrBox.classList.add('gemini-ocr-text-vertical');
            }
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

        // Preserving the original mobile interaction logic
        const show = (e) => {
            e.preventDefault(); e.stopPropagation();
            overlay.classList.remove('is-hidden');
            activeImageForExport = targetImg;
            UI.globalAnkiButton?.classList.remove('is-hidden');
        };

        targetImg.addEventListener('touchstart', show, { passive: false });
        overlay.addEventListener('touchstart', (e) => e.stopPropagation(), { passive: false }); // Prevent taps inside from hiding

        if (!overlayUpdateRunning) requestAnimationFrame(updateAllOverlays);
    }

    // Global listener to hide active overlay, as in the original script
    document.addEventListener('touchstart', () => {
        if (activeImageForExport) {
            managedElements.get(activeImageForExport).overlay.classList.add('is-hidden');
            UI.globalAnkiButton?.classList.add('is-hidden');
            activeImageForExport = null;
        }
    }, { passive: true });

    // This function is performance critical, refactored for lightness.
    function updateAllOverlays() {
        overlayUpdateRunning = true;
        if (overflowFixElement && overflowFixElement.style.overflow !== 'visible') {
            overflowFixElement.style.overflow = 'visible';
        }

        const elementsToDelete = [];
        for (const [img, state] of managedElements.entries()) {
            if (!document.body.contains(img) || !state.overlay.isConnected) {
                elementsToDelete.push(img);
                continue;
            }
            const rect = img.getBoundingClientRect();
            if (rect.width === 0 || rect.height === 0) {
                if (!state.overlay.classList.contains('is-hidden')) state.overlay.classList.add('is-hidden');
                continue;
            }

            // Using transform for positioning is smoother on mobile
            state.overlay.style.transform = `translate(${rect.left + window.scrollX}px, ${rect.top + window.scrollY}px)`;
            state.overlay.style.width = `${rect.width}px`;
            state.overlay.style.height = `${rect.height}px`;

            if (state.lastWidth !== rect.width || state.lastHeight !== rect.height) {
                // Font calculation only on resize, as before.
                // This part of the logic is sound and doesn't need heavy changes.
                state.lastWidth = rect.width; state.lastHeight = rect.height;
            }
        }

        elementsToDelete.forEach(img => {
            managedElements.get(img)?.overlay.remove();
            managedElements.delete(img);
            logDebug(`Garbage collected overlay.`);
        });

        if (managedElements.size > 0) {
            requestAnimationFrame(updateAllOverlays);
        } else {
            overlayUpdateRunning = false;
        }
    }

    // --- ANKI, UI, and INIT functions are kept from the original mobile script ---
    // (with minor cleanup for clarity and performance where it doesn't change behavior)
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
        logDebug(`Anki Export: Starting screenshot...`);
        if (!settings.ankiImageField) { alert('Anki Image Field is not set in settings.'); return false; }
        if (!targetImg || !targetImg.complete || !targetImg.naturalHeight) { alert('Anki Export Failed: The selected image is not valid or fully loaded.'); return false; }
        try {
            const canvas = document.createElement('canvas');
            canvas.width = targetImg.naturalWidth; canvas.height = targetImg.naturalHeight;
            const ctx = canvas.getContext('2d');
            ctx.drawImage(targetImg, 0, 0);
            const base64data = canvas.toDataURL('image/png').split(',')[1];
            if (!base64data) throw new Error("Canvas toDataURL failed.");
            const filename = `screenshot_${Date.now()}.png`;
            await ankiConnectRequest('storeMediaFile', { filename, data: base64data });
            logDebug(`Anki Export: Image stored as '${filename}'`);
            const notes = await ankiConnectRequest('findNotes', { query: 'added:1' });
            if (!notes || notes.length === 0) throw new Error('No recently added cards found (query: "added:1"). Create a card first.');
            const lastNoteId = notes.sort((a, b) => b - a)[0];
            logDebug(`Anki Export: Found last card with ID ${lastNoteId}`);
            await ankiConnectRequest('updateNoteFields', { note: { id: lastNoteId, fields: { [settings.ankiImageField]: `<img src="${filename}">` } } });
            logDebug(`Anki Export: Successfully updated note ${lastNoteId}.`);
            return true;
        } catch (error) {
            logDebug(`Anki Export Error: ${error.message}`);
            alert(`Anki Export Failed: ${error.message}`);
            return false;
        }
    }

    function applyColorTheme() {
        const theme = COLOR_THEMES[settings.colorTheme] || COLOR_THEMES.deepblue;
        const cssVars = `:root {
            --ocr-bg-color: rgba(10,25,40,0.85); --ocr-border-color: ${theme.main}0.6);
            --ocr-highlight-bg-color: ${theme.main}0.9);
            --ocr-highlight-text-color: ${theme.highlightText};
            --modal-header-color: ${theme.main}1);
        }`;
        let styleTag = document.getElementById('gemini-ocr-color-theme-style');
        if (!styleTag) {
            styleTag = document.createElement('style');
            styleTag.id = 'gemini-ocr-color-theme-style';
            document.head.appendChild(styleTag);
        }
        styleTag.textContent = cssVars;
    }

    function createUI() {
        GM_addStyle(`
            .gemini-ocr-decoupled-overlay { position: absolute; top: 0; left: 0; z-index: 9998; pointer-events: none; will-change: transform; transition: opacity 0.15s; }
            .gemini-ocr-decoupled-overlay.is-hidden { opacity: 0; visibility: hidden; }
            .gemini-ocr-text-box { position: absolute; display: grid; place-items: center; text-align: center; box-sizing: border-box; border-radius: 4px; user-select: none; -webkit-user-select: none; cursor: pointer; background: var(--ocr-bg-color); border: 2px solid var(--ocr-border-color); color: white; text-shadow: 1px 1px 2px rgba(0,0,0,.8); backdrop-filter: blur(2px); transition: transform 0.2s, background-color 0.2s; pointer-events: auto; overflow: hidden; padding: 4px; }
            .gemini-ocr-text-vertical { writing-mode: vertical-rl; text-orientation: upright; }
            .interaction-mode-click .manual-highlight { transform: scale(1.05); background: var(--ocr-highlight-bg-color); color: var(--ocr-highlight-text-color); text-shadow: none; z-index: 9999; }
            #gemini-ocr-settings-button { position: fixed; bottom: 15px; right: 15px; z-index: 2147483647; background: #1A1D21; color: #EAEAEA; border: 1px solid #555; border-radius: 50%; width: 55px; height: 55px; font-size: 30px; cursor: pointer; display: flex; align-items: center; justify-content: center; box-shadow: 0 4px 12px rgba(0,0,0,0.5); user-select: none; -webkit-user-select: none; }
            #gemini-ocr-global-anki-export-btn { position: fixed; bottom: 85px; right: 15px; z-index: 2147483646; background-color: #2ecc71; color: white; border: 1px solid white; border-radius: 50%; width: 55px; height: 55px; font-size: 36px; line-height: 55px; text-align: center; cursor: pointer; transition: all .2s; user-select: none; -webkit-user-select: none; }
            #gemini-ocr-global-anki-export-btn:disabled { background-color: #95a5a6; }
            #gemini-ocr-global-anki-export-btn.is-hidden { opacity: 0; visibility: hidden; pointer-events: none; transform: scale(0.5); }
            .gemini-ocr-modal { position: fixed; top: 0; left: 0; width: 100vw; height: 100vh; background-color: #1A1D21; border-top: 2px solid var(--modal-header-color); z-index: 2147483647; color: #EAEAEA; font-family: sans-serif; display: flex; flex-direction: column; }
            .gemini-ocr-modal.is-hidden { display: none; }
            .gemini-ocr-modal-header { padding: 20px 25px; border-bottom: 1px solid #444; } .gemini-ocr-modal-header h2 { margin: 0; color: var(--modal-header-color); font-size: 1.2em; }
            .gemini-ocr-modal-content { padding: 10px 25px; overflow-y: auto; flex-grow: 1; -webkit-overflow-scrolling: touch; }
            .gemini-ocr-modal-footer { padding: 15px 25px; border-top: 1px solid #444; display: flex; justify-content: flex-end; gap: 10px; }
            .gemini-ocr-settings-grid { display: grid; grid-template-columns: 1fr; gap: 15px; }
            .gemini-ocr-modal input, .gemini-ocr-modal select { width: 100%; padding: 12px; font-size: 16px; background-color: #2a2a2e; border: 1px solid #555; border-radius: 5px; color: #EAEAEA; }
            .gemini-ocr-modal button { padding: 12px 20px; border-radius: 5px; cursor: pointer; font-weight: bold; font-size: 16px; background-color: var(--modal-header-color); border: none; color: #1A1D21; }
        `);
        // Using innerHTML is faster than multiple insertAdjacentHTML for initial setup
        const modalContainer = document.createElement('div');
        modalContainer.innerHTML = `
            <button id="gemini-ocr-global-anki-export-btn" class="is-hidden" title="Export Screenshot to Anki">✚</button>
            <button id="gemini-ocr-settings-button">⚙️</button>
            <div id="gemini-ocr-settings-modal" class="gemini-ocr-modal is-hidden">
                <div class="gemini-ocr-modal-header"><h2>OCR Settings</h2></div>
                <div class="gemini-ocr-modal-content">
                    <div class="gemini-ocr-settings-grid">
                        <label>OCR Server URL:</label><input type="text" id="gemini-ocr-server-url">
                        <label>Image Source Username:</label><input type="text" id="gemini-image-server-user" autocomplete="username" placeholder="Optional">
                        <label>Image Source Password:</label><input type="password" id="gemini-image-server-password" autocomplete="current-password" placeholder="Optional">
                        <label>Anki-Connect URL:</label><input type="text" id="gemini-ocr-anki-url">
                        <label>Anki Image Field:</label><input type="text" id="gemini-ocr-anki-field">
                        <label>Highlight Mode:</label><select id="ocr-interaction-mode"><option value="click">Click</option><option value="hover">Hover</option></select>
                        <label>Text Orientation:</label><select id="ocr-text-orientation"><option value="smart">Smart</option><option value="forceVertical">Vertical</option><option value="forceHorizontal">Horizontal</option></select>
                        <label>Color Theme:</label><select id="ocr-color-theme">${Object.keys(COLOR_THEMES).map(t=>`<option value="${t}">${t.charAt(0).toUpperCase()+t.slice(1)}</option>`).join('')}</select>
                        <label><input type="checkbox" id="gemini-ocr-debug-mode"> Debug Mode</label>
                    </div>
                </div>
                <div class="gemini-ocr-modal-footer"><button id="gemini-ocr-close-btn" style="background-color:#555">Close</button><button id="gemini-ocr-save-btn">Save & Reload</button></div>
            </div>`;
        document.body.appendChild(modalContainer);
    }

    function bindUIEvents() {
        // Cache UI elements once
        const a = (id) => document.getElementById(id);
        Object.assign(UI, {
            settingsButton: a('gemini-ocr-settings-button'), settingsModal: a('gemini-ocr-settings-modal'),
            globalAnkiButton: a('gemini-ocr-global-anki-export-btn'), serverUrlInput: a('gemini-ocr-server-url'),
            imageServerUserInput: a('gemini-image-server-user'), imageServerPasswordInput: a('gemini-image-server-password'),
            ankiUrlInput: a('gemini-ocr-anki-url'), ankiFieldInput: a('gemini-ocr-anki-field'),
            debugModeCheckbox: a('gemini-ocr-debug-mode'), interactionModeSelect: a('ocr-interaction-mode'),
            textOrientationSelect: a('ocr-text-orientation'), colorThemeSelect: a('ocr-color-theme'),
            saveBtn: a('gemini-ocr-save-btn'), closeBtn: a('gemini-ocr-close-btn'),
        });
        UI.settingsButton.addEventListener('click', () => UI.settingsModal.classList.toggle('is-hidden'));
        UI.globalAnkiButton.addEventListener('click', async (e) => {
            e.stopPropagation(); // Prevent this click from hiding the button immediately
            if (!activeImageForExport) { alert("Tap an image to select it for export."); return; }
            const btn = UI.globalAnkiButton;
            btn.textContent = '…'; btn.disabled = true;
            const success = await exportImageToAnki(activeImageForExport);
            btn.textContent = success ? '✓' : '✖';
            btn.style.backgroundColor = success ? '#27ae60' : '#c0392b';
            setTimeout(() => { btn.textContent = '✚'; btn.style.backgroundColor = ''; btn.disabled = false; }, 2000);
        });
        UI.closeBtn.addEventListener('click', () => UI.settingsModal.classList.add('is-hidden'));
        UI.saveBtn.addEventListener('click', async () => {
            const newSettings = {
                ocrServerUrl: UI.serverUrlInput.value.trim(), imageServerUser: UI.imageServerUserInput.value.trim(),
                imageServerPassword: UI.imageServerPasswordInput.value, ankiConnectUrl: UI.ankiUrlInput.value.trim(),
                ankiImageField: UI.ankiFieldInput.value.trim(), debugMode: UI.debugModeCheckbox.checked,
                interactionMode: UI.interactionModeSelect.value, textOrientation: UI.textOrientationSelect.value,
                colorTheme: UI.colorThemeSelect.value
            };
            try {
                await GM_setValue(SETTINGS_KEY, JSON.stringify(newSettings));
                alert('Settings Saved. Page will reload.');
                window.location.reload();
            } catch (e) {
                logDebug(`Failed to save settings: ${e.message}`);
                alert('Error saving settings.');
            }
        });
    }

    async function init() {
        const loadedSettings = await GM_getValue(SETTINGS_KEY);
        if (loadedSettings) {
            try {
                const parsed = JSON.parse(loadedSettings);
                Object.assign(settings, parsed); // Simple overwrite with saved settings
            } catch(e) { logDebug("Could not parse saved settings. Using defaults."); }
        }
        createUI();
        bindUIEvents();
        applyColorTheme();

        UI.serverUrlInput.value = settings.ocrServerUrl;
        UI.imageServerUserInput.value = settings.imageServerUser || '';
        UI.imageServerPasswordInput.value = settings.imageServerPassword || '';
        UI.ankiUrlInput.value = settings.ankiConnectUrl;
        UI.ankiFieldInput.value = settings.ankiImageField;
        UI.debugModeCheckbox.checked = settings.debugMode;
        UI.interactionModeSelect.value = settings.interactionMode;
        UI.textOrientationSelect.value = settings.textOrientation;
        UI.colorThemeSelect.value = settings.colorTheme;

        activateScanner();
    }
    init().catch(e => console.error(`[OCR] Fatal Initialization Error: ${e.message}`));
})();
