// ==UserScript==
// @name         Automatic Content OCR with Gemini (MutationObserver + Persistent Cache)
// @namespace    http://tampermonkey.net/
// @version      3.3
// @description  Reliably positions OCR by observing image 'src' changes, ensuring compatibility with lazy-loading sites. Uses Gemini 2.5, lookahead processing, and persistent caching.
// @author       1Selxo (modified by Gemini)
// @match        *://*/*
// @grant        GM_setValue
// @grant        GM_getValue
// @grant        GM_addStyle
// @grant        GM_xmlhttpRequest
// @connect      generativelanguage.googleapis.com
// @connect      fonts.googleapis.com
// @connect      fonts.gstatic.com
// ==/UserScript==

(function() {
    'use strict';

    const main = async () => {
        // --- 1. STYLES (Unchanged) ---
        GM_addStyle(`
            @import url('https://fonts.googleapis.com/css2?family=Noto+Sans+JP:wght@500&display=swap');
            #gemini-ocr-settings-button { position: fixed; bottom: 15px; right: 15px; z-index: 2147483646; background: #1F1F23; color: #EAEAEA; border: 1px solid #555; border-radius: 50%; width: 40px; height: 40px; font-size: 24px; cursor: pointer; display: flex; align-items: center; justify-content: center; box-shadow: 0 4px 12px rgba(0,0,0,0.4); }
            .gemini-ocr-modal { position: fixed; top: 50%; left: 50%; transform: translate(-50%, -50%); background-color: #1F1F23; border: 1px solid #00BFFF; border-radius: 15px; padding: 25px; z-index: 2147483647; color: #EAEAEA; font-family: 'Noto Sans JP', sans-serif; box-shadow: 0 8px 32px 0 rgba(0, 0, 0, 0.5); width: 600px; max-width: 90vw; }
            #gemini-ocr-debug-modal { width: 80vw; height: 80vh; flex-direction: column; }
            .gemini-ocr-modal.is-hidden { display: none !important; }
            .gemini-ocr-modal.is-visible { display: flex !important; flex-direction: column; }
            .gemini-ocr-modal h2 { margin-top: 0; color: #00BFFF; }
            .gemini-ocr-settings-grid { display: grid; grid-template-columns: max-content 1fr; gap: 12px; align-items: center; }
            .gemini-ocr-settings-grid label { justify-self: end; margin: 0; }
            .gemini-ocr-settings-grid .full-width { grid-column: 1 / -1; }
            .gemini-ocr-settings-grid .full-width label { justify-self: start; margin-bottom: 5px; }
            .gemini-ocr-modal-buttons { grid-column: 1 / -1; display: flex; flex-wrap: wrap; justify-content: flex-end; gap: 10px; margin-top: 15px; }
            .gemini-ocr-modal-cache-buttons { grid-column: 1 / -1; display: flex; justify-content: flex-start; gap: 10px; margin-top: 10px; padding-top: 15px; border-top: 1px solid #444; }
            .gemini-ocr-modal input, .gemini-ocr-modal textarea, .gemini-ocr-modal select, #gemini-ocr-debug-log { width: 100%; padding: 8px; box-sizing: border-box; font-family: monospace; background-color: #2a2a2e; border: 1px solid #555; border-radius: 5px; color: #EAEAEA; font-size: 14px; }
            .gemini-ocr-modal input[type="number"] { width: 80px; }
            .gemini-ocr-modal input[type="file"] { display: none; }
            .gemini-ocr-modal textarea { height: 120px; }
            #gemini-ocr-debug-log { flex-grow: 1; resize: none; white-space: pre; }
            .gemini-ocr-modal button, .gemini-ocr-modal .gemini-ocr-button-like { padding: 10px 18px; background-color: #00BFFF; border: none; border-radius: 5px; color: #1A1A1D; cursor: pointer; font-weight: bold; margin-top: 0; display: inline-block; text-align: center; }
            #gemini-ocr-api-keys-list { display: flex; flex-direction: column; gap: 8px; }
            .gemini-ocr-api-key-item { display: flex; align-items: center; gap: 8px; }
            .gemini-ocr-api-key-item input { flex-grow: 1; }
            .gemini-ocr-api-key-add-btn { font-size: 18px; padding: 0 10px; height: 30px; line-height: 30px; }
            .gemini-ocr-api-key-remove-btn { background-color: #FF6347; color: white; border-radius: 50%; width: 30px; height: 30px; font-weight: bold; }
            .gemini-ocr-label-wrapper { display: flex; align-items: center; justify-content: space-between; grid-column: 1 / -1; margin-bottom: -5px;}
            .gemini-ocr-label-wrapper label { justify-self: start; }
            .gemini-ocr-wrapper { position: relative !important; display: inline-block; }
            .gemini-ocr-wrapper > img { position: relative !important; z-index: 1 !important; }
            .gemini-ocr-overlay-container { position: absolute; top: 0; left: 0; width: 100%; height: 100%; z-index: 2 !important; pointer-events: none; visibility: hidden; opacity: 0; transform-origin: top left; transition: opacity 0.2s ease, visibility 0.2s ease; }
            .gemini-ocr-wrapper:hover .gemini-ocr-overlay-container { visibility: visible; opacity: 1; pointer-events: all; }
            .gemini-ocr-text-box { font-family: 'Noto Sans JP', sans-serif; position: absolute; background: rgba(10, 25, 40, 0.4); border: 2px solid rgba(0, 191, 255, 0.5); color: white; font-weight: 500; text-shadow: 1px 1px 2px #000, -1px -1px 2px #000, 1px -1px 2px #000, -1px 1px 2px #000; border-radius: 3px; backdrop-filter: blur(1px); box-sizing: border-box; cursor: text; overflow: hidden !important; display: flex; align-items: center; justify-content: center; line-height: 1.2; word-break: break-all; z-index: 10; transition: background-color 0.2s ease, border-color 0.2s ease, transform 0.2s ease; }
            .gemini-ocr-text-box.focused { background: rgba(15, 45, 70, 0.85); border-color: #33CFFF; transform: scale(1.03); z-index: 20; }
            .gemini-ocr-text-vertical { writing-mode: vertical-rl !important; text-orientation: upright !important; white-space: pre-line !important; text-align: center !important; display: block !important; letter-spacing: 0.1em; padding: 4px 2px; height: auto !important; }
            .gemini-ocr-text-box ruby { ruby-position: over; ruby-align: center; }
            .gemini-ocr-text-vertical ruby { ruby-position: right; }
            .gemini-ocr-text-box rt { font-size: 0.6em; color: #B0E0FF; text-shadow: 1px 1px 1px #000; line-height: 1; }
            #gemini-ocr-status-indicator { position: fixed; bottom: 15px; left: 15px; background: rgba(0, 0, 0, 0.7); color: #00BFFF; padding: 8px 15px; border-radius: 5px; z-index: 2147483647; font-family: sans-serif; font-size: 14px; display: none; }
        `);

        // --- 2. CACHE MODULE (Unchanged) ---
        const PersistentCache = {
            CACHE_KEY: 'gemini_ocr_cache_v1',
            data: new Map(),
            async load() { try { const storedData = await GM_getValue(this.CACHE_KEY); if (storedData) { this.data = new Map(Object.entries(JSON.parse(storedData))); logDebug(`Loaded ${this.data.size} items from persistent cache.`); } else { logDebug("No persistent cache found. Starting fresh."); } } catch (e) { logDebug(`Error loading persistent cache: ${e.message}. Starting fresh.`); this.data = new Map(); } },
            async save() { try { const storableData = Object.fromEntries(this.data); await GM_setValue(this.CACHE_KEY, JSON.stringify(storableData)); } catch (e) { logDebug(`Error saving persistent cache: ${e.message}`); showStatus('Error saving cache!', 'error'); } },
            get(key) { return this.data.get(key); },
            has(key) { return this.data.has(key); },
            async set(key, value) { this.data.set(key, value); await this.save(); },
            async merge(importedObject) { let newEntries = 0; for (const [key, value] of Object.entries(importedObject)) { if (!this.has(key)) { this.data.set(key, value); newEntries++; } } if (newEntries > 0) { await this.save(); logDebug(`Merged ${newEntries} new entries into the cache.`); } return newEntries; }
        };

        // --- 3. UTILITY & SETTINGS (Unchanged) ---
        let debugLog = [];
        const logDebug = (message) => { const timestamp = new Date().toLocaleTimeString(); const logEntry = `[${timestamp}] ${message}`; console.log(`Gemini OCR: ${logEntry}`); debugLog.push(logEntry); };
        const showStatus = (message, type = 'info', duration = 3000) => { const indicator = document.getElementById('gemini-ocr-status-indicator'); if (!indicator) return; indicator.textContent = message; indicator.style.color = type === 'error' ? '#FF4757' : (type === 'warning' ? '#FFD700' : '#00BFFF'); indicator.style.display = 'block'; if (duration > 0) setTimeout(() => indicator.style.display = 'none', duration); };
        let settings = { apiKeys: [''], model: 'gemini-2.5-flash', sites: [], debugMode: false, lookaheadLimit: 4 };
        let currentApiKeyIndex = 0;
        const createUI = async () => { const settingsButton = document.createElement('button'); settingsButton.id = 'gemini-ocr-settings-button'; settingsButton.innerHTML = '⚙️'; document.body.appendChild(settingsButton); const modal = document.createElement('div'); modal.id = 'gemini-ocr-settings-modal'; modal.classList.add('gemini-ocr-modal', 'is-hidden'); modal.innerHTML = ` <h2 class="full-width">Automatic OCR Settings</h2> <div class="gemini-ocr-settings-grid"> <div class="gemini-ocr-label-wrapper"> <label>Gemini API Keys:</label> <button id="gemini-ocr-api-key-add-btn" class="gemini-ocr-api-key-add-btn" title="Add another API key">+</button> </div> <div id="gemini-ocr-api-keys-list" class="full-width"></div> <label for="gemini-ocr-model-select">Vision Model:</label> <select id="gemini-ocr-model-select"> <option value="gemini-2.5-flash">Gemini 2.5 Flash</option> <option value="gemini-2.5-pro">Gemini 2.5 Pro</option> </select> <label for="gemini-ocr-lookahead-input">Lookahead Limit:</label> <input type="number" id="gemini-ocr-lookahead-input" min="1" max="20" title="How many images to process ahead of the one you are viewing."> <div class="full-width"> <label><input type="checkbox" id="gemini-ocr-debug-mode"> Debug Mode</label> </div> <div class="full-width"> <label for="gemini-ocr-sites-config">Site Configurations (URL_Pattern, CSS_Selector):</label> <textarea id="gemini-ocr-sites-config" placeholder="Example:\nrawotaku.com, #images-content"></textarea> </div> <div class="gemini-ocr-modal-cache-buttons full-width"> <label for="gemini-ocr-import-cache-input" class="gemini-ocr-button-like" style="background-color: #4CAF50;">Import Cache</label> <input type="file" id="gemini-ocr-import-cache-input" accept=".json"> <button id="gemini-ocr-export-cache-btn" style="background-color: #2196F3;">Export Cache</button> </div> <div class="gemini-ocr-modal-buttons full-width"> <button id="gemini-ocr-debug-btn" style="background-color: #777; margin-right: auto;">Debug Logs</button> <button id="gemini-ocr-close-btn" style="background-color: #555;">Close</button> <button id="gemini-ocr-save-btn">Save and Reload</button> </div> </div>`; document.body.appendChild(modal); const debugModal = document.createElement('div'); debugModal.id = 'gemini-ocr-debug-modal'; debugModal.classList.add('gemini-ocr-modal', 'is-hidden'); debugModal.innerHTML = `<h2>Debug Log</h2><textarea id="gemini-ocr-debug-log" readonly></textarea><button id="gemini-ocr-close-debug-btn" style="background-color: #555;">Close</button>`; document.body.appendChild(debugModal); const statusIndicator = document.createElement('div'); statusIndicator.id = 'gemini-ocr-status-indicator'; document.body.appendChild(statusIndicator); const loadedSettings = await GM_getValue('gemini_ocr_settings_v30'); if (loadedSettings) { const parsed = JSON.parse(loadedSettings); if (parsed.apiKey) { parsed.apiKeys = [parsed.apiKey]; delete parsed.apiKey; } settings = { ...settings, ...parsed }; } else { settings.sites = [{ urlPattern: 'rawotaku.com', selector: '#images-content' }]; } renderApiKeys(); document.getElementById('gemini-ocr-model-select').value = settings.model; document.getElementById('gemini-ocr-debug-mode').checked = settings.debugMode; document.getElementById('gemini-ocr-lookahead-input').value = settings.lookaheadLimit; document.getElementById('gemini-ocr-sites-config').value = settings.sites.map(s => `${s.urlPattern}, ${s.selector}`).join('\n'); settingsButton.addEventListener('click', () => { modal.classList.remove('is-hidden'); modal.classList.add('is-visible'); }); document.getElementById('gemini-ocr-close-btn').addEventListener('click', () => { modal.classList.add('is-hidden'); modal.classList.remove('is-visible'); }); document.getElementById('gemini-ocr-debug-btn').addEventListener('click', () => { document.getElementById('gemini-ocr-debug-log').value = debugLog.slice(-150).join('\n'); debugModal.classList.remove('is-hidden'); debugModal.classList.add('is-visible'); }); document.getElementById('gemini-ocr-close-debug-btn').addEventListener('click', () => { debugModal.classList.add('is-hidden'); debugModal.classList.remove('is-visible'); }); document.getElementById('gemini-ocr-api-key-add-btn').addEventListener('click', addApiKeyInput); document.getElementById('gemini-ocr-export-cache-btn').addEventListener('click', exportCache); document.getElementById('gemini-ocr-import-cache-input').addEventListener('change', importCache); document.getElementById('gemini-ocr-save-btn').addEventListener('click', async () => { const keyInputs = document.querySelectorAll('.gemini-ocr-api-key-input'); const apiKeys = Array.from(keyInputs).map(input => input.value.trim()).filter(key => key); const newSettings = { apiKeys: apiKeys.length > 0 ? apiKeys : [''], model: document.getElementById('gemini-ocr-model-select').value, debugMode: document.getElementById('gemini-ocr-debug-mode').checked, lookaheadLimit: parseInt(document.getElementById('gemini-ocr-lookahead-input').value, 10) || 4, sites: document.getElementById('gemini-ocr-sites-config').value.split('\n').filter(line => line.includes(',')).map(line => { const [urlPattern, selector] = line.split(',').map(s => s.trim()); return { urlPattern, selector }; }) }; await GM_setValue('gemini_ocr_settings_v30', JSON.stringify(newSettings)); alert('Settings Saved. The page will now reload.'); window.location.reload(); }); };
        function renderApiKeys() { const container = document.getElementById('gemini-ocr-api-keys-list'); container.innerHTML = ''; (settings.apiKeys.length > 0 ? settings.apiKeys : ['']).forEach((key, index) => { const item = document.createElement('div'); item.className = 'gemini-ocr-api-key-item'; item.innerHTML = `<input type="password" class="gemini-ocr-api-key-input" value="${key}" placeholder="Enter Gemini API Key"/><button class="gemini-ocr-api-key-remove-btn" data-index="${index}" title="Remove this key">-</button>`; container.appendChild(item); }); container.querySelectorAll('.gemini-ocr-api-key-remove-btn').forEach(button => button.addEventListener('click', removeApiKeyInput)); }
        function addApiKeyInput() { settings.apiKeys.push(''); renderApiKeys(); }
        function removeApiKeyInput(event) { const index = parseInt(event.target.dataset.index, 10); settings.apiKeys.splice(index, 1); renderApiKeys(); }
        const exportCache = () => { const dataStr = "data:text/json;charset=utf-8," + encodeURIComponent(JSON.stringify(Object.fromEntries(PersistentCache.data), null, 2)); const downloadAnchorNode = document.createElement('a'); downloadAnchorNode.setAttribute("href", dataStr); downloadAnchorNode.setAttribute("download", "gemini-ocr-cache.json"); document.body.appendChild(downloadAnchorNode); downloadAnchorNode.click(); downloadAnchorNode.remove(); showStatus('Cache exported successfully!', 'info'); };
        const importCache = (event) => { const file = event.target.files[0]; if (!file) return; const reader = new FileReader(); reader.onload = async (e) => { try { const importedData = JSON.parse(e.target.result); const newCount = await PersistentCache.merge(importedData); alert(`Import complete. Merged ${newCount} new OCR entries into your cache. Please reload the page to see the changes.`); event.target.value = ''; } catch (err) { alert(`Failed to import cache file. Error: ${err.message}`); } }; reader.readAsText(file); };

        // --- 4. CORE LOGIC (Major Change: Using MutationObserver) ---
        const ocrCache = new WeakMap();
        const imageQueue = [];
        let intersectionObserver;
        let imagesScheduledForOcr = 0;
        let imagesProcessedCount = 0;
        const activateScanner = () => { logDebug("Script activating..."); const validApiKeys = settings.apiKeys.filter(k => k); if (validApiKeys.length === 0) { showStatus('API Key not set. Click the gear icon.', 'error', 10000); return; } logDebug(`${validApiKeys.length} API key(s) loaded.`); const activeSite = settings.sites.find(site => window.location.href.includes(site.urlPattern)); if (!activeSite) { return logDebug(`No matching site config for URL: ${window.location.href}`); } initializeIntersectionObserver(); showStatus(`OCR Active. Watching for: ${activeSite.selector}`, 'info', 5000); const pageObserver = new MutationObserver((mutations, observer) => { const container = document.querySelector(activeSite.selector); if (container) { logDebug(`Target container "${activeSite.selector}" found. Starting monitor.`); observer.disconnect(); monitorContainer(container); } }); pageObserver.observe(document.body, { childList: true, subtree: true }); };
        const initializeIntersectionObserver = () => { logDebug("Initializing Intersection Observer."); intersectionObserver = new IntersectionObserver((entries) => { entries.forEach(entry => { if (entry.isIntersecting) { const img = entry.target; const currentIndex = imageQueue.indexOf(img); logDebug(`Image #${currentIndex + 1} is now visible. Scheduling next batch.`); attemptToDisplayOcr(img); scheduleOcrForRange(currentIndex + 1, settings.lookaheadLimit); intersectionObserver.unobserve(img); } }); }, { rootMargin: '200px 0px' }); };
        function monitorContainer(container) { discoverAndQueueImages(container); const newImageObserver = new MutationObserver(() => { discoverAndQueueImages(container); }); newImageObserver.observe(container, { childList: true, subtree: true }); }
        function discoverAndQueueImages(container) { const images = Array.from(container.querySelectorAll('img:not([data-ocr-queued])')); if (images.length === 0) return; logDebug(`Discovered ${images.length} new images.`); images.forEach(img => { img.dataset.ocrQueued = 'true'; imageQueue.push(img); intersectionObserver.observe(img); }); if (imagesScheduledForOcr === 0 && imageQueue.length > 0) { logDebug("Kicking off initial OCR processing for the first batch."); scheduleOcrForRange(0, settings.lookaheadLimit); } }
        function scheduleOcrForRange(startIndex, count) { logDebug(`Scheduling OCR for images from index ${startIndex} to ${startIndex + count - 1}.`); for (let i = 0; i < count; i++) { const imageIndex = startIndex + i; if (imageIndex >= imageQueue.length) break; const img = imageQueue[imageIndex]; if (!ocrCache.has(img)) { primeImage(img, imageIndex + 1); } else { attemptToDisplayOcr(img); } } }

        function primeImage(img, imageNumber) {
            // New Robust Logic with MutationObserver
            const observer = new MutationObserver((mutations) => {
                for (const mutation of mutations) {
                    if (mutation.type === 'attributes' && mutation.attributeName === 'src') {
                        logDebug(`'src' changed for image #${imageNumber}. Re-evaluating.`);
                        // Give the browser a moment to render the new image
                        setTimeout(() => attemptToDisplayOcr(img), 150);
                        // Once the real src is set, we don't need to watch anymore.
                        observer.disconnect();
                    }
                }
            });

            observer.observe(img, { attributes: true, attributeFilter: ['src'] });

            // Also check on the standard load event as a fallback
            img.addEventListener('load', () => {
                logDebug(`Image #${imageNumber} 'load' event fired. Re-validating OCR display.`);
                setTimeout(() => attemptToDisplayOcr(img), 100);
            }, { once: true });

            const realSrc = img.dataset.src || img.src;
            // Check cache right away
            if (PersistentCache.has(realSrc)) {
                logDebug(`[${imageNumber}/${imageQueue.length}] Found image in persistent cache. Loading OCR...`);
                const cachedData = PersistentCache.get(realSrc);
                ocrCache.set(img, cachedData);
                attemptToDisplayOcr(img);
            } else if (realSrc && !realSrc.includes('data:image')) { // Don't process placeholders
                // If not in cache, start the API process
                processImage(img, imageNumber);
            }
        }

        const processImage = (img, imageNumber) => {
            if (ocrCache.has(img) && ocrCache.get(img) !== 'pending') return;
            const realSrc = img.dataset.src || img.src;
            if (realSrc && realSrc.startsWith('http')) {
                logDebug(`[${imageNumber}/${imageQueue.length}] Starting background fetch for ...${realSrc.slice(-40)}`);
                imagesScheduledForOcr++;
                ocrCache.set(img, 'pending');
                updateStatus();
                fetchImageAsBase64(realSrc, (base64Data, mimeType) => { if (base64Data) { fetchOcrData(base64Data, mimeType, img, realSrc, imageNumber, 0); } else { logDebug(`Failed to fetch image data for ...${realSrc.slice(-40)}`); ocrCache.delete(img); imagesScheduledForOcr--; } });
            }
        };

        const fetchImageAsBase64 = (url, callback) => { GM_xmlhttpRequest({ method: 'GET', url: url, responseType: 'blob', onload: (response) => { const blob = response.response; const reader = new FileReader(); reader.onload = () => callback(reader.result.split(',')[1], blob.type); reader.onerror = () => callback(null); reader.readAsDataURL(blob); }, onerror: (error) => { logDebug(`Image fetch error for ${url}: ${JSON.stringify(error)}`); callback(null); } }); };
        const fetchOcrData = (base64Data, mimeType, targetImg, sourceUrl, imageNumber, attempt) => { const validApiKeys = settings.apiKeys.filter(k => k); if (attempt >= validApiKeys.length) { showStatus(`All ${validApiKeys.length} API keys failed.`, 'error', 10000); logDebug(`All API keys failed for image #${imageNumber}. Aborting.`); ocrCache.delete(targetImg); imagesScheduledForOcr--; updateStatus(); return; } const apiKey = validApiKeys[currentApiKeyIndex]; logDebug(`Sending image #${imageNumber} to Gemini (Key #${currentApiKeyIndex + 1}, Attempt #${attempt + 1}) ...${sourceUrl.slice(-40)}`); const prompt = `Analyze this manga page with extreme precision. For each text element (speech bubbles, captions, sound effects):\n1. Extract ALL text including main text and furigana (ruby text).\n2. Provide a TIGHT-FITTING bounding box that minimizes empty space around the text. Coordinates MUST be decimal percentages (0.0-1.0). (x,y) is the TOP-LEFT corner.\n3. Determine text orientation: HORIZONTAL or VERTICAL.\n4. Measure the font size relative to the image's total height (e.g., a value of 0.04 means the font is 4% of the image height).\n5. Identify furigana relationships.\nOutput ONLY a valid JSON array.\nJSON structure:\n[{"text": "main text", "furigana": [{"base": "漢字", "ruby": "かんじ", "position": 0}], "orientation": "VERTICAL", "tightBoundingBox": {"x": 0.123, "y": 0.456, "width": 0.078, "height": 0.234}, "fontSize": 0.045, "confidence": 0.95}]`; GM_xmlhttpRequest({ method: 'POST', url: `https://generativelanguage.googleapis.com/v1beta/models/${settings.model}:generateContent?key=${apiKey}`, headers: { 'Content-Type': 'application/json' }, data: JSON.stringify({ contents: [{ parts: [{ inline_data: { mime_type: mimeType, data: base64Data } }, { text: prompt }] }] }), onload: (response) => { try { if (response.status === 429 || response.status >= 500) { throw new Error(`API returned status ${response.status}. Trying next key.`); } if (response.status !== 200) { throw new Error(`API returned status ${response.status}: ${response.statusText}`); } const result = JSON.parse(response.responseText); const ocrDataText = result.candidates?.[0]?.content?.parts?.[0]?.text; if (!ocrDataText) { if (result.promptFeedback?.blockReason) { throw new Error(`API blocked request: ${result.promptFeedback.blockReason}. ${JSON.stringify(result.promptFeedback.safetyRatings)}`); } throw new Error(JSON.stringify(result.error || 'No content returned from API')); } const jsonMatch = ocrDataText.match(/\[.*\]/s); if (!jsonMatch) throw new Error("API did not return a valid JSON array."); const parsedData = JSON.parse(jsonMatch[0]); PersistentCache.set(sourceUrl, parsedData); ocrCache.set(targetImg, parsedData); imagesProcessedCount++; updateStatus(); logDebug(`[${imagesProcessedCount}/${imagesScheduledForOcr}] OCR success for image #${imageNumber} with Key #${currentApiKeyIndex + 1}. Result saved to cache.`); attemptToDisplayOcr(targetImg); } catch (e) { logDebug(`OCR Error on image #${imageNumber} with key #${currentApiKeyIndex + 1}: ${e.message}`); currentApiKeyIndex = (currentApiKeyIndex + 1) % validApiKeys.length; showStatus(`Key #${(currentApiKeyIndex - 1 + validApiKeys.length) % validApiKeys.length + 1} failed. Switching to Key #${currentApiKeyIndex + 1}...`, 'warning', 5000); fetchOcrData(base64Data, mimeType, targetImg, sourceUrl, imageNumber, attempt + 1); } }, onerror: (error) => { logDebug(`Gemini API network error for image #${imageNumber} with key #${currentApiKeyIndex + 1}: ${JSON.stringify(error)}`); currentApiKeyIndex = (currentApiKeyIndex + 1) % validApiKeys.length; showStatus(`Network error with Key #${(currentApiKeyIndex - 1 + validApiKeys.length) % validApiKeys.length + 1}. Switching to Key #${currentApiKeyIndex + 1}...`, 'warning', 5000); fetchOcrData(base64Data, mimeType, targetImg, sourceUrl, imageNumber, attempt + 1); } }); };
        const updateStatus = () => { if (imagesProcessedCount < imagesScheduledForOcr) { showStatus(`Processing ${imagesProcessedCount} / ${imagesScheduledForOcr} images...`, 'info', 0); } else if (imagesScheduledForOcr > 0 && imageQueue.length > imagesScheduledForOcr) { showStatus(`Processed ${imagesProcessedCount}/${imageQueue.length} total. Scroll to load more.`, 'success'); } else if (imagesScheduledForOcr > 0 && imagesProcessedCount === imageQueue.length) { showStatus(`All ${imageQueue.length} images processed!`, 'success'); } };

        // --- 5. DISPLAY LOGIC (Unchanged from v3.2) ---
        const attemptToDisplayOcr = (targetImg) => {
            const data = ocrCache.get(targetImg);
            // Wait for data AND for the image to be physically rendered.
            if (data && data !== 'pending' && targetImg.offsetWidth > 50 && targetImg.offsetHeight > 50) {
                displayOcrResults(targetImg);
            } else if (data && data !== 'pending') {
                logDebug(`Skipping OCR display for now, image dimensions are not ready (${targetImg.offsetWidth}x${targetImg.offsetHeight}). Will retry on change/load.`);
            }
        };
        const displayOcrResults = (targetImg) => { const data = ocrCache.get(targetImg); if (!data || data === 'pending') return; const dimensions = { w: targetImg.offsetWidth, h: targetImg.offsetHeight }; if (!targetImg.parentElement || !targetImg.parentElement.classList.contains('gemini-ocr-wrapper')) { const wrapper = document.createElement('div'); wrapper.classList.add('gemini-ocr-wrapper'); if (targetImg.parentElement) targetImg.parentElement.insertBefore(wrapper, targetImg); wrapper.appendChild(targetImg); } let container = targetImg.parentElement.querySelector('.gemini-ocr-overlay-container'); if (!container) { container = document.createElement('div'); container.className = 'gemini-ocr-overlay-container'; targetImg.parentElement.appendChild(container); container.addEventListener('mouseover', (e) => { if (e.target.classList.contains('gemini-ocr-text-box')) { container.querySelectorAll('.gemini-ocr-text-box.focused').forEach(el => el.classList.remove('focused')); e.target.classList.add('focused'); } }); container.addEventListener('mouseleave', () => { container.querySelectorAll('.gemini-ocr-text-box.focused').forEach(el => el.classList.remove('focused')); }); } if (container.dataset.width && container.dataset.width == dimensions.w) { return; } container.innerHTML = ''; container.dataset.width = dimensions.w; const { w: displayWidth, h: displayHeight } = dimensions; if (displayWidth === 0) { return; } data.forEach((item) => { if (!item?.tightBoundingBox?.width || !item.text || typeof item.fontSize !== 'number') return; const ocrBox = document.createElement('div'); ocrBox.className = 'gemini-ocr-text-box'; if (item.orientation === 'VERTICAL') ocrBox.classList.add('gemini-ocr-text-vertical'); if (item.furigana?.length > 0) { let processedText = item.text; item.furigana.sort((a, b) => (b.position || 0) - (a.position || 0)).forEach(furi => { const base = furi.base.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); try { processedText = processedText.replace(new RegExp(base), `<ruby>${furi.base}<rt>${furi.ruby}</rt></ruby>`); } catch(e) { logDebug(`Regex error with furigana base: ${furi.base}`); } }); ocrBox.innerHTML = processedText; } else { ocrBox.textContent = item.text; } const { x, y, width, height } = item.tightBoundingBox; ocrBox.style.left = `${x * displayWidth}px`; ocrBox.style.top = `${y * displayHeight}px`; ocrBox.style.width = `${width * displayWidth}px`; ocrBox.style.height = `${height * displayHeight}px`; ocrBox.title = `Confidence: ${((item.confidence || 0.8) * 100).toFixed(1)}%`; const reductionFactor = 0.85; let initialFontSize = Math.max(item.fontSize * displayHeight * reductionFactor, 10); ocrBox.style.fontSize = `${initialFontSize}px`; container.appendChild(ocrBox); const minFontSize = 8; let iterations = 0; const maxIterations = 25; while ((ocrBox.scrollHeight > ocrBox.clientHeight + 1 || ocrBox.scrollWidth > ocrBox.clientWidth + 1) && initialFontSize > minFontSize && iterations < maxIterations) { initialFontSize -= 1; ocrBox.style.fontSize = `${initialFontSize}px`; iterations++; } if (iterations > 0 && settings.debugMode) { logDebug(`Resized font for "${item.text.substring(0,10)}..." to ${initialFontSize.toFixed(1)}px in ${iterations} steps.`); } }); };

        // --- SCRIPT START ---
        await PersistentCache.load();
        await createUI();
        activateScanner();
    };

    if (document.readyState === 'loading') { document.addEventListener('DOMContentLoaded', main); } else { main(); }
})();
