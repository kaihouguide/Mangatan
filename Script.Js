// ==UserScript==
// @name         Automatic Content OCR with Gemini (Sequential Lookahead + Fallback Keys)
// @namespace    http://tampermonkey.net/
// @version      2.1
// @description  Finds all images in order, intelligently pre-loads OCR data using the correct gemini-2.5 models, and automatically cycles through multiple API keys if one gets rate-limited.
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
            .gemini-ocr-modal-buttons { grid-column: 1 / -1; display: flex; justify-content: flex-end; gap: 10px; margin-top: 15px; }
            .gemini-ocr-modal input, .gemini-ocr-modal textarea, .gemini-ocr-modal select, #gemini-ocr-debug-log { width: 100%; padding: 8px; box-sizing: border-box; font-family: monospace; background-color: #2a2a2e; border: 1px solid #555; border-radius: 5px; color: #EAEAEA; font-size: 14px; }
            .gemini-ocr-modal input[type="number"] { width: 80px; }
            .gemini-ocr-modal textarea { height: 120px; }
            #gemini-ocr-debug-log { flex-grow: 1; resize: none; white-space: pre; }
            .gemini-ocr-modal button { padding: 10px 18px; background-color: #00BFFF; border: none; border-radius: 5px; color: #1A1A1D; cursor: pointer; font-weight: bold; margin-top: 0; }
            #gemini-ocr-api-keys-list { display: flex; flex-direction: column; gap: 8px; }
            .gemini-ocr-api-key-item { display: flex; align-items: center; gap: 8px; }
            .gemini-ocr-api-key-item input { flex-grow: 1; }
            .gemini-ocr-api-key-add-btn { font-size: 18px; padding: 0 10px; height: 30px; line-height: 30px; }
            .gemini-ocr-api-key-remove-btn { background-color: #FF6347; color: white; border-radius: 50%; width: 30px; height: 30px; font-weight: bold; }
            .gemini-ocr-label-wrapper { display: flex; align-items: center; justify-content: space-between; grid-column: 1 / -1; margin-bottom: -5px;}
            .gemini-ocr-label-wrapper label { justify-self: start; }
            .gemini-ocr-wrapper { position: relative !important; display: inline-block; }
            .gemini-ocr-wrapper > img { position: relative !important; z-index: 1 !important; }
            .gemini-ocr-overlay-container { position: absolute; top: 0; left: 0; width: 100%; height: 100%; z-index: 2 !important; pointer-events: none; visibility: hidden; opacity: 0; transform-origin: top left; transform: scale(0.95); transition: opacity 0.2s ease, visibility 0.2s ease, transform 0.2s ease; }
            .gemini-ocr-wrapper:hover .gemini-ocr-overlay-container { visibility: visible; opacity: 1; transform: scale(1); }
            .gemini-ocr-text-box { font-family: 'Noto Sans JP', sans-serif; position: absolute; border: 2px solid #00BFFF; background: rgba(0, 191, 255, 0.15); color: white; font-weight: 500; text-shadow: 1px 1px 2px #000, -1px -1px 2px #000, 1px -1px 2px #000, -1px 1px 2px #000; border-radius: 3px; backdrop-filter: blur(1px); box-sizing: border-box; pointer-events: all !important; cursor: text; overflow: visible !important; display: flex; align-items: center; justify-content: center; line-height: 1.2; word-wrap: break-word; z-index: 10; }
            .gemini-ocr-text-vertical { writing-mode: vertical-rl !important; text-orientation: upright !important; white-space: pre-line !important; overflow-wrap: break-word !important; word-break: break-all !important; text-align: center !important; display: block !important; letter-spacing: 0.1em; padding: 4px 2px; height: auto !important; }
            .gemini-ocr-text-box ruby { ruby-position: over; ruby-align: center; }
            .gemini-ocr-text-vertical ruby { ruby-position: right; }
            .gemini-ocr-text-box rt { font-size: 0.6em; color: #B0E0FF; text-shadow: 1px 1px 1px #000; line-height: 1; }
            .gemini-ocr-text-box.high-accuracy { border-color: #00FF7F; background: rgba(0, 255, 127, 0.1); }
            .gemini-ocr-text-box.low-accuracy { border-color: #FF6347; background: rgba(255, 99, 71, 0.1); }
            .gemini-ocr-debug .gemini-ocr-text-box { background: rgba(255, 0, 0, 0.3) !important; border: 2px solid red !important; color: yellow !important; }
            #gemini-ocr-status-indicator { position: fixed; bottom: 15px; left: 15px; background: rgba(0, 0, 0, 0.7); color: #00BFFF; padding: 8px 15px; border-radius: 5px; z-index: 2147483647; font-family: sans-serif; font-size: 14px; display: none; }
        `);

        // --- 2. UTILITY FUNCTIONS (Unchanged) ---
        let debugLog = [];
        const logDebug = (message) => { const timestamp = new Date().toLocaleTimeString(); const logEntry = `[${timestamp}] ${message}`; console.log(`Gemini OCR: ${logEntry}`); debugLog.push(logEntry); };
        const showStatus = (message, type = 'info', duration = 3000) => { const indicator = document.getElementById('gemini-ocr-status-indicator'); if (!indicator) return; indicator.textContent = message; indicator.style.color = type === 'error' ? '#FF4757' : (type === 'warning' ? '#FFD700' : '#00BFFF'); indicator.style.display = 'block'; if (duration > 0) setTimeout(() => indicator.style.display = 'none', duration); };

        // --- 3. UI & SETTINGS (Models Corrected) ---
        let settings = { apiKeys: [''], model: 'gemini-2.5-flash', sites: [], debugMode: false, lookaheadLimit: 4 };
        let currentApiKeyIndex = 0;

        const createUI = async () => {
            const settingsButton = document.createElement('button'); settingsButton.id = 'gemini-ocr-settings-button'; settingsButton.innerHTML = '⚙️'; document.body.appendChild(settingsButton);
            const modal = document.createElement('div'); modal.id = 'gemini-ocr-settings-modal'; modal.classList.add('gemini-ocr-modal', 'is-hidden');
            // --- CORRECTED: Updated model names and text in the dropdown menu ---
            modal.innerHTML = `
                <h2 class="full-width">Automatic OCR Settings</h2>
                <div class="gemini-ocr-settings-grid">
                    <div class="gemini-ocr-label-wrapper">
                        <label>Gemini API Keys:</label>
                        <button id="gemini-ocr-api-key-add-btn" class="gemini-ocr-api-key-add-btn" title="Add another API key">+</button>
                    </div>
                    <div id="gemini-ocr-api-keys-list" class="full-width"></div>

                    <label for="gemini-ocr-model-select">Vision Model:</label>
                    <select id="gemini-ocr-model-select">
                        <option value="gemini-2.5-flash">Gemini 2.5 Flash</option>
                        <option value="gemini-2.5-pro">Gemini 2.5 Pro</option>
                    </select>

                    <label for="gemini-ocr-lookahead-input">Lookahead Limit:</label>
                    <input type="number" id="gemini-ocr-lookahead-input" min="1" max="20" title="How many images to process ahead of the one you are viewing.">

                    <div class="full-width">
                        <label><input type="checkbox" id="gemini-ocr-debug-mode"> Debug Mode (Show Bounding Boxes)</label>
                    </div>

                    <div class="full-width">
                        <label for="gemini-ocr-sites-config">Site Configurations (URL_Pattern, CSS_Selector):</label>
                        <textarea id="gemini-ocr-sites-config" placeholder="Example:\nrawotaku.com, #images-content\nraw1001.net, #chapterContent"></textarea>
                    </div>

                    <div class="gemini-ocr-modal-buttons full-width">
                        <button id="gemini-ocr-debug-btn" style="background-color: #777; margin-right: auto;">Debug Logs</button>
                        <button id="gemini-ocr-close-btn" style="background-color: #555;">Close</button>
                        <button id="gemini-ocr-save-btn">Save and Reload</button>
                    </div>
                </div>`;
            document.body.appendChild(modal);

            const debugModal = document.createElement('div'); debugModal.id = 'gemini-ocr-debug-modal'; debugModal.classList.add('gemini-ocr-modal', 'is-hidden');
            debugModal.innerHTML = `<h2>Debug Log</h2><textarea id="gemini-ocr-debug-log" readonly></textarea><button id="gemini-ocr-close-debug-btn" style="background-color: #555;">Close</button>`; document.body.appendChild(debugModal);
            const statusIndicator = document.createElement('div'); statusIndicator.id = 'gemini-ocr-status-indicator'; document.body.appendChild(statusIndicator);

            const loadedSettings = await GM_getValue('gemini_ocr_settings_v30'); // Incremented version for new settings
             if (loadedSettings) {
                const parsed = JSON.parse(loadedSettings);
                if (parsed.apiKey) { // Backwards compatibility
                    parsed.apiKeys = [parsed.apiKey];
                    delete parsed.apiKey;
                }
                settings = { ...settings, ...parsed };
            } else {
                settings.sites = [{ urlPattern: 'rawotaku.com', selector: '#images-content' }, { urlPattern: 'raw1001.net', selector: '#chapterContent' }];
            }

            renderApiKeys();
            document.getElementById('gemini-ocr-model-select').value = settings.model;
            document.getElementById('gemini-ocr-debug-mode').checked = settings.debugMode;
            document.getElementById('gemini-ocr-lookahead-input').value = settings.lookaheadLimit;
            document.getElementById('gemini-ocr-sites-config').value = settings.sites.map(s => `${s.urlPattern}, ${s.selector}`).join('\n');

            settingsButton.addEventListener('click', () => { modal.classList.remove('is-hidden'); modal.classList.add('is-visible'); });
            document.getElementById('gemini-ocr-close-btn').addEventListener('click', () => { modal.classList.add('is-hidden'); modal.classList.remove('is-visible'); });
            document.getElementById('gemini-ocr-debug-btn').addEventListener('click', () => { document.getElementById('gemini-ocr-debug-log').value = debugLog.slice(-150).join('\n'); debugModal.classList.remove('is-hidden'); debugModal.classList.add('is-visible'); });
            document.getElementById('gemini-ocr-close-debug-btn').addEventListener('click', () => { debugModal.classList.add('is-hidden'); debugModal.classList.remove('is-visible'); });
            document.getElementById('gemini-ocr-api-key-add-btn').addEventListener('click', addApiKeyInput);

            document.getElementById('gemini-ocr-save-btn').addEventListener('click', async () => {
                const keyInputs = document.querySelectorAll('.gemini-ocr-api-key-input');
                const apiKeys = Array.from(keyInputs).map(input => input.value.trim()).filter(key => key);

                const newSettings = {
                    apiKeys: apiKeys.length > 0 ? apiKeys : [''],
                    model: document.getElementById('gemini-ocr-model-select').value,
                    debugMode: document.getElementById('gemini-ocr-debug-mode').checked,
                    lookaheadLimit: parseInt(document.getElementById('gemini-ocr-lookahead-input').value, 10) || 4,
                    sites: document.getElementById('gemini-ocr-sites-config').value.split('\n').filter(line => line.includes(',')).map(line => { const [urlPattern, selector] = line.split(',').map(s => s.trim()); return { urlPattern, selector }; })
                };
                await GM_setValue('gemini_ocr_settings_v30', JSON.stringify(newSettings));
                alert('Settings Saved. The page will now reload.');
                window.location.reload();
            });
        };

        function renderApiKeys() {
            const container = document.getElementById('gemini-ocr-api-keys-list');
            container.innerHTML = '';
            (settings.apiKeys.length > 0 ? settings.apiKeys : ['']).forEach((key, index) => {
                const item = document.createElement('div');
                item.className = 'gemini-ocr-api-key-item';
                item.innerHTML = `
                    <input type="password" class="gemini-ocr-api-key-input" value="${key}" placeholder="Enter Gemini API Key"/>
                    <button class="gemini-ocr-api-key-remove-btn" data-index="${index}" title="Remove this key">-</button>
                `;
                container.appendChild(item);
            });
            container.querySelectorAll('.gemini-ocr-api-key-remove-btn').forEach(button => {
                button.addEventListener('click', removeApiKeyInput);
            });
        }

        function addApiKeyInput() {
            settings.apiKeys.push('');
            renderApiKeys();
        }

        function removeApiKeyInput(event) {
            const index = parseInt(event.target.dataset.index, 10);
            settings.apiKeys.splice(index, 1);
            renderApiKeys();
        }

        // --- 4. CORE LOGIC (Unchanged from previous fallback version) ---
        const ocrCache = new WeakMap();
        const imageQueue = [];
        let intersectionObserver;
        let imagesScheduledForOcr = 0;
        let imagesProcessedCount = 0;

        const activateScanner = () => {
            logDebug("Script activating...");
            const validApiKeys = settings.apiKeys.filter(k => k);
            if (validApiKeys.length === 0) {
                showStatus('API Key not set. Click the gear icon.', 'error', 10000);
                return;
            }
            logDebug(`${validApiKeys.length} API key(s) loaded.`);

            const activeSite = settings.sites.find(site => window.location.href.includes(site.urlPattern));
            if (!activeSite) { return logDebug(`No matching site config for URL: ${window.location.href}`); }

            initializeIntersectionObserver();

            showStatus(`OCR Active. Watching for: ${activeSite.selector}`, 'info', 5000);
            const pageObserver = new MutationObserver((mutations, observer) => {
                const container = document.querySelector(activeSite.selector);
                if (container) {
                    logDebug(`Target container "${activeSite.selector}" found. Starting monitor.`);
                    observer.disconnect();
                    monitorContainer(container);
                }
            });
            pageObserver.observe(document.body, { childList: true, subtree: true });
        };

        const initializeIntersectionObserver = () => {
            logDebug("Initializing Intersection Observer.");
            intersectionObserver = new IntersectionObserver((entries) => {
                entries.forEach(entry => {
                    if (entry.isIntersecting) {
                        const img = entry.target;
                        const currentIndex = imageQueue.indexOf(img);
                        logDebug(`Image #${currentIndex + 1} is now visible. Scheduling next batch.`);
                        scheduleOcrForRange(currentIndex + 1, settings.lookaheadLimit);
                        intersectionObserver.unobserve(img);
                    }
                });
            }, { rootMargin: '200px 0px' });
        };

        function monitorContainer(container) {
            discoverAndQueueImages(container);
            const newImageObserver = new MutationObserver(() => { discoverAndQueueImages(container); });
            newImageObserver.observe(container, { childList: true, subtree: true });
        }

        function discoverAndQueueImages(container) {
            const images = Array.from(container.querySelectorAll('img:not([data-ocr-queued])'));
            if (images.length === 0) return;
            logDebug(`Discovered ${images.length} new images.`);
            images.forEach(img => {
                img.dataset.ocrQueued = 'true';
                imageQueue.push(img);
                intersectionObserver.observe(img);
            });
            if (imagesScheduledForOcr === 0) {
                logDebug("Kicking off initial OCR processing for the first batch.");
                scheduleOcrForRange(0, settings.lookaheadLimit);
            }
        }

        function scheduleOcrForRange(startIndex, count) {
            logDebug(`Scheduling OCR for images from index ${startIndex} to ${startIndex + count - 1}.`);
            for (let i = 0; i < count; i++) {
                const imageIndex = startIndex + i;
                if (imageIndex >= imageQueue.length) break;
                const img = imageQueue[imageIndex];
                if (!ocrCache.has(img)) {
                    primeImage(img, imageIndex + 1);
                }
            }
        }

        function primeImage(img, imageNumber) {
            const realSrc = img.dataset.src || img.src;
            if (realSrc && realSrc.startsWith('http')) {
                processImage(img, realSrc, imageNumber);
            } else {
                logDebug(`Image #${imageNumber} has no valid src yet. Attaching attribute observer.`);
                const attrObserver = new MutationObserver(() => {
                    const updatedSrc = img.dataset.src || img.src;
                    if (updatedSrc && updatedSrc.startsWith('http')) {
                        attrObserver.disconnect();
                        processImage(img, updatedSrc, imageNumber);
                    }
                });
                attrObserver.observe(img, { attributes: true, attributeFilter: ['src', 'data-src'] });
            }
        }

        const processImage = (img, imageUrl, imageNumber) => {
            logDebug(`[${imageNumber}/${imageQueue.length}] Starting background fetch for ...${imageUrl.slice(-40)}`);
            imagesScheduledForOcr++;
            ocrCache.set(img, 'pending');
            updateStatus();
            fetchImageAsBase64(imageUrl, (base64Data, mimeType) => {
                if (base64Data) {
                    fetchOcrData(base64Data, mimeType, img, imageUrl, imageNumber, 0); // Start with the first attempt
                } else {
                    logDebug(`Failed to fetch image data for ...${imageUrl.slice(-40)}`);
                    ocrCache.delete(img);
                    imagesScheduledForOcr--;
                }
            });
        };

        const fetchImageAsBase64 = (url, callback) => {
            GM_xmlhttpRequest({
                method: 'GET', url: url, responseType: 'blob',
                onload: (response) => {
                    const blob = response.response;
                    const reader = new FileReader();
                    reader.onload = () => callback(reader.result.split(',')[1], blob.type);
                    reader.onerror = () => callback(null);
                    reader.readAsDataURL(blob);
                },
                onerror: (error) => { logDebug(`Image fetch error for ${url}: ${JSON.stringify(error)}`); callback(null); }
            });
        };

        const fetchOcrData = (base64Data, mimeType, targetImg, sourceUrl, imageNumber, attempt) => {
            const validApiKeys = settings.apiKeys.filter(k => k);
            if (attempt >= validApiKeys.length) {
                showStatus(`All ${validApiKeys.length} API keys failed.`, 'error', 10000);
                logDebug(`All API keys failed for image #${imageNumber}. Aborting.`);
                ocrCache.delete(targetImg);
                imagesScheduledForOcr--;
                updateStatus();
                return;
            }

            const apiKey = validApiKeys[currentApiKeyIndex];
            logDebug(`Sending image #${imageNumber} to Gemini (Key #${currentApiKeyIndex + 1}, Attempt #${attempt + 1}) ...${sourceUrl.slice(-40)}`);
            const prompt = `Analyze this manga page with extreme precision. For each text element (speech bubbles, captions, sound effects):\n1. Extract ALL text including main text and furigana (ruby text).\n2. Provide precise bounding box coordinates as decimal percentages (0.0-1.0). (x,y) MUST be the TOP-LEFT corner.\n3. Determine text orientation: HORIZONTAL or VERTICAL.\n4. Measure the font size relative to the image's total height (e.g., a value of 0.04 means the font is 4% of the image height).\n5. Identify furigana relationships.\nOutput ONLY a valid JSON array.\nJSON structure:\n[{"text": "main text", "furigana": [{"base": "漢字", "ruby": "かんじ", "position": 0}], "orientation": "VERTICAL", "boundingBox": {"x": 0.123, "y": 0.456, "width": 0.078, "height": 0.234}, "fontSize": 0.045, "confidence": 0.95}]`;

            GM_xmlhttpRequest({
                method: 'POST',
                url: `https://generativelanguage.googleapis.com/v1beta/models/${settings.model}:generateContent?key=${apiKey}`,
                headers: { 'Content-Type': 'application/json' },
                data: JSON.stringify({ contents: [{ parts: [{ inline_data: { mime_type: mimeType, data: base64Data } }, { text: prompt }] }] }),
                onload: (response) => {
                    try {
                        if (response.status === 429 || response.status >= 500) {
                             throw new Error(`API returned status ${response.status}. Trying next key.`);
                        }
                        if (response.status !== 200) {
                            throw new Error(`API returned status ${response.status}: ${response.statusText}`);
                        }

                        const result = JSON.parse(response.responseText);
                        const ocrDataText = result.candidates?.[0]?.content?.parts?.[0]?.text;
                         if (!ocrDataText) {
                             if (result.promptFeedback?.blockReason) {
                                throw new Error(`API blocked request: ${result.promptFeedback.blockReason}. ${JSON.stringify(result.promptFeedback.safetyRatings)}`);
                            }
                            throw new Error(JSON.stringify(result.error || 'No content returned from API'));
                        }
                        const jsonMatch = ocrDataText.match(/\[.*\]/s);
                        if (!jsonMatch) throw new Error("API did not return a valid JSON array.");
                        const parsedData = JSON.parse(jsonMatch[0]);

                        ocrCache.set(targetImg, parsedData);
                        imagesProcessedCount++;
                        updateStatus();
                        logDebug(`[${imagesProcessedCount}/${imagesScheduledForOcr}] OCR success for image #${imageNumber} with Key #${currentApiKeyIndex + 1}`);
                        targetImg.addEventListener('mouseover', () => displayOcrResults(targetImg));
                    } catch (e) {
                         logDebug(`OCR Error on image #${imageNumber} with key #${currentApiKeyIndex + 1}: ${e.message}`);
                         currentApiKeyIndex = (currentApiKeyIndex + 1) % validApiKeys.length;
                         showStatus(`Key #${(currentApiKeyIndex - 1 + validApiKeys.length) % validApiKeys.length + 1} failed. Switching to Key #${currentApiKeyIndex + 1}...`, 'warning', 5000);
                         fetchOcrData(base64Data, mimeType, targetImg, sourceUrl, imageNumber, attempt + 1);
                    }
                },
                onerror: (error) => {
                     logDebug(`Gemini API network error for image #${imageNumber} with key #${currentApiKeyIndex + 1}: ${JSON.stringify(error)}`);
                     currentApiKeyIndex = (currentApiKeyIndex + 1) % validApiKeys.length;
                     showStatus(`Network error with Key #${(currentApiKeyIndex - 1 + validApiKeys.length) % validApiKeys.length + 1}. Switching to Key #${currentApiKeyIndex + 1}...`, 'warning', 5000);
                     fetchOcrData(base64Data, mimeType, targetImg, sourceUrl, imageNumber, attempt + 1);
                }
            });
        };

        const updateStatus = () => {
            if (imagesProcessedCount < imagesScheduledForOcr) {
                showStatus(`Processing ${imagesProcessedCount} / ${imagesScheduledForOcr} images...`, 'info', 0);
            } else if (imagesScheduledForOcr > 0 && imageQueue.length > imagesScheduledForOcr) {
                 showStatus(`Processed ${imagesProcessedCount}/${imageQueue.length} total. Scroll to load more.`, 'success');
            } else if (imagesScheduledForOcr > 0 && imagesProcessedCount === imageQueue.length) {
                showStatus(`All ${imageQueue.length} images processed!`, 'success');
            }
        };

        const displayOcrResults = (targetImg) => {
            const data = ocrCache.get(targetImg);
            if (!data || data === 'pending') return;
            const dimensions = { w: targetImg.offsetWidth, h: targetImg.offsetHeight };
            if (!targetImg.parentElement || !targetImg.parentElement.classList.contains('gemini-ocr-wrapper')) {
                const wrapper = document.createElement('div'); wrapper.classList.add('gemini-ocr-wrapper');
                if (targetImg.parentElement) targetImg.parentElement.insertBefore(wrapper, targetImg);
                wrapper.appendChild(targetImg);
            }
            let container = targetImg.parentElement.querySelector('.gemini-ocr-overlay-container');
            if (!container) {
                container = document.createElement('div'); container.className = 'gemini-ocr-overlay-container';
                if (settings.debugMode) container.classList.add('gemini-ocr-debug');
                targetImg.parentElement.appendChild(container);
            }
            if (container.dataset.renderedFor === targetImg.src && container.dataset.width === dimensions.w) return;
            container.innerHTML = '';
            container.dataset.renderedFor = targetImg.src;
            container.dataset.width = dimensions.w;
            const { w: displayWidth, h: displayHeight } = dimensions;
            if (displayWidth === 0) return;
            data.forEach((item) => {
                if (!item?.boundingBox?.width || !item.text || typeof item.fontSize !== 'number') return;
                const ocrBox = document.createElement('div'); ocrBox.className = 'gemini-ocr-text-box';
                const confidence = item.confidence || 0.8;
                ocrBox.classList.add(confidence >= 0.9 ? 'high-accuracy' : (confidence < 0.7 ? 'low-accuracy' : ''));
                if (item.orientation === 'VERTICAL') ocrBox.classList.add('gemini-ocr-text-vertical');
                if (item.furigana?.length > 0) {
                    let processedText = item.text;
                    item.furigana.sort((a, b) => (b.position || 0) - (a.position || 0)).forEach(furi => { processedText = processedText.replace(furi.base, `<ruby>${furi.base}<rt>${furi.ruby}</rt></ruby>`); });
                    ocrBox.innerHTML = processedText;
                } else { ocrBox.textContent = item.text; }
                const reductionFactor = 0.8;
                const calculatedFontSize = Math.max(item.fontSize * displayHeight * reductionFactor, 10);
                ocrBox.style.fontSize = `${calculatedFontSize}px`;
                const { x, y, width, height } = item.boundingBox;
                ocrBox.style.left = `${x * displayWidth}px`;
                ocrBox.style.top = `${y * displayHeight}px`;
                ocrBox.style.minWidth = `${width * displayWidth}px`;
                ocrBox.style.minHeight = `${height * displayHeight}px`;
                ocrBox.title = `Confidence: ${(confidence * 100).toFixed(1)}%`;
                container.appendChild(ocrBox);
            });
        };

        // --- SCRIPT START ---
        await createUI();
        activateScanner();
    };

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', main);
    } else {
        main();
    }
})();
