// ==UserScript==
// @name         Automatic Content OCR (PC Hybrid Engine) - Modifier Key Merging
// @namespace    http://tampermonkey.net/
// @version      24.5.26-PC-FocusColor
// @description  Adds a stable, inline OCR button and modifier-key merging. Now includes a superior CSS blend mode for perfect text contrast on any background.
// @author       1Selxo (Original) & Gemini (Refactoring & PC-Centric Features)
// @match        *://127.0.0.1*/*
// @grant        GM_setValue
// @grant        GM_getValue
// @grant        GM_addStyle
// @grant        GM_xmlhttpRequest
// @connect      127.0.0.1
// @connect      localhost
// @downloadURL  https://github.com/kaihouguide/Mangatan/raw/main/desktop-script-server-merge-context.user.js
// @updateURL    https://github.com/kaihouguide/Mangatan/raw/main/desktop-script-server-merge-context.user.js
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
                'div.muiltr-18sieki', 'div.muiltr-cns6dc', '.MuiBox-root.muiltr-1noqzsz', '.MuiBox-root.muiltr-1tapw32'
            ],
            overflowFixSelector: '.MuiBox-root.muiltr-13djdhf',
            contentRootSelector: '#root'
        }],
        debugMode: true, textOrientation: 'smart', interactionMode: 'hover', dimmedOpacity: 0.3, fontMultiplierHorizontal: 1.0,
        fontMultiplierVertical: 1.0, boundingBoxAdjustment: 5, focusScaleMultiplier: 1.1, soloHoverMode: false,
        deleteModifierKey: 'Alt', mergeModifierKey: 'Control', addSpaceOnMerge: false, colorTheme: 'blue', brightnessMode: 'light',
        focusFontColor: 'default' // --- NEW ---
    };
    let debugLog = [];
    const SETTINGS_KEY = 'gemini_ocr_settings_v24_pc_focus_color'; // --- MODIFIED ---
    const ocrDataCache = new WeakMap();
    const managedElements = new Map(), managedContainers = new Map(), attachedAttributeObservers = new WeakMap();
    let activeSiteConfig = null, measurementSpan = null, activeImageForExport = null, hideButtonTimer = null, activeOverlay = null;
    const UI = {};
    let mergeState = { anchorBox: null };

    let resizeObserver, intersectionObserver, imageObserver, containerObserver, chapterObserver, navigationObserver;
    const visibleImages = new Set();
    let animationFrameId = null;

	const textSeparator = '\u00AD'; // ZWS \u200B  SHY \u00AD

	const cropModifierKey = 'Shift'; // better move this to settings

    const COLOR_THEMES = {
        blue: { accent: '72,144,255', background: '229,243,255' }, red: { accent: '255,72,75', background: '255,229,230' },
        green: { accent: '34,119,49', background: '239,255,229' }, orange: { accent: '243,156,18', background: '255,245,229' },
        purple: { accent: '155,89,182', background: '245,229,255' }, turquoise: { accent: '26,188,156', background: '229,255,250' },
        pink: { accent: '255,77,222', background: '255,229,255' }, grey: { accent: '149,165,166', background: '229,236,236' }
    };

    const logDebug = (message) => {
        if (!settings.debugMode) return;
        const timestamp = new Date().toLocaleTimeString(), logEntry = `[${timestamp}] ${message}`;
        console.log(`[OCR PC Hybrid] ${logEntry}`);
        debugLog.push(logEntry);
        document.dispatchEvent(new CustomEvent('ocr-log-update'));
    };

    // --- [ROBUST] Navigation Handling & State Reset ---
    function fullCleanupAndReset() {
        logDebug("NAVIGATION DETECTED: Starting full cleanup and reset.");
        if (animationFrameId !== null) { cancelAnimationFrame(animationFrameId); animationFrameId = null; }
        if (containerObserver) containerObserver.disconnect(); if (imageObserver) imageObserver.disconnect(); if (chapterObserver) chapterObserver.disconnect();
        for (const [img, state] of managedElements.entries()) {
            if (state.overlay?.isConnected) state.overlay.remove();
            resizeObserver.unobserve(img); intersectionObserver.unobserve(img);
        }
        managedElements.clear(); managedContainers.clear(); visibleImages.clear(); hideActiveOverlay();
        logDebug("All state maps cleared. Cleanup complete.");
    }
    function reinitializeScript() { logDebug("Re-initializing scanners."); activateScanner(); observeChapters(); }
    function setupNavigationObserver() {
        const contentRootSelector = activeSiteConfig?.contentRootSelector;
        if (!contentRootSelector) return logDebug("Warning: No `contentRootSelector` defined.");
        const targetNode = document.querySelector(contentRootSelector);
        if (!targetNode) return logDebug(`Navigation observer target not found: ${contentRootSelector}.`);
        navigationObserver = new MutationObserver((mutations) => {
            for (const mutation of mutations) for (const node of mutation.removedNodes)
                if (node.nodeType === 1 && (managedContainers.has(node) || managedElements.has(node))) {
                    fullCleanupAndReset();
                    setTimeout(reinitializeScript, 250);
                    return;
                }
        });
        navigationObserver.observe(targetNode, { childList: true, subtree: true });
        logDebug(`Robust navigation observer attached to ${targetNode.id || targetNode.className}.`);
    }

    // --- Hybrid Render Engine Core ---
    function updateVisibleOverlaysPosition() {
        for (const img of visibleImages) {
            const state = managedElements.get(img);
            if (state?.overlay.isConnected) {
                const rect = img.getBoundingClientRect();
                Object.assign(state.overlay.style, { top: `${rect.top}px`, left: `${rect.left}px` });
            }
        }
        animationFrameId = requestAnimationFrame(updateVisibleOverlaysPosition);
    }
    function updateOverlayDimensionsAndStyles(img, state, rect = null) {
        if (!rect) rect = img.getBoundingClientRect();
        if (rect.width > 0 && rect.height > 0) {
            Object.assign(state.overlay.style, { width: `${rect.width}px`, height: `${rect.height}px` });
            if (state.lastWidth !== rect.width || state.lastHeight !== rect.height) {
                if (state.overlay.classList.contains('is-focused')) {
                    calculateAndApplyOptimalStyles_Optimized(state.overlay, rect);
                }
                state.lastWidth = rect.width; state.lastHeight = rect.height;
            }
        }
    }
    const handleResize = (entries) => {
        for (const entry of entries) if (managedElements.has(entry.target))
            updateOverlayDimensionsAndStyles(entry.target, managedElements.get(entry.target), entry.contentRect);
    };
    const handleIntersection = (entries) => {
        for (const entry of entries) {
            const img = entry.target;
            if (entry.isIntersecting) {
                if (!visibleImages.has(img)) {
                    visibleImages.add(img);
                    const state = managedElements.get(img);
                    if (state) state.overlay.style.visibility = 'visible';
                    if (animationFrameId === null) animationFrameId = requestAnimationFrame(updateVisibleOverlaysPosition);
                }
            } else if (visibleImages.has(img)) {
                visibleImages.delete(img);
                const state = managedElements.get(img);
                if (state) state.overlay.style.visibility = 'hidden';
                if (visibleImages.size === 0 && animationFrameId !== null) {
                    cancelAnimationFrame(animationFrameId); animationFrameId = null;
                }
            }
        }
    };

    // --- Core Observation Logic ---
    function setupMutationObservers() {
        imageObserver = new MutationObserver((mutations) => { for (const m of mutations) for (const n of m.addedNodes) if (n.nodeType === 1) { if (n.tagName === 'IMG') observeImageForSrcChange(n); else n.querySelectorAll('img').forEach(observeImageForSrcChange); } });
        containerObserver = new MutationObserver((mutations) => { if (!activeSiteConfig) return; const sel = activeSiteConfig.imageContainerSelectors.join(', '); for (const m of mutations) for (const n of m.addedNodes) if (n.nodeType === 1) { if (n.matches(sel)) manageContainer(n); else n.querySelectorAll(sel).forEach(manageContainer); } });
        chapterObserver = new MutationObserver((mutations) => { for (const m of mutations) for (const n of m.addedNodes) if (n.nodeType === 1) { const links = n.matches('a[href*="/manga/"][href*="/chapter/"]') ? [n] : n.querySelectorAll('a[href*="/manga/"][href*="/chapter/"]'); links.forEach(addOcrButtonToChapter); } });
    }
    function manageContainer(container) {
        if (managedContainers.has(container)) return;
        logDebug(`New container found: ${container.className}`);
        container.querySelectorAll('img').forEach(observeImageForSrcChange);
        imageObserver.observe(container, { childList: true, subtree: true });
        managedContainers.set(container, true);
    }
    function activateScanner() {
        activeSiteConfig = settings.sites.find(site => window.location.href.includes(site.urlPattern));
        if (!activeSiteConfig?.imageContainerSelectors?.length) return logDebug(`No matching site config for URL: ${window.location.href}.`);
        const sel = activeSiteConfig.imageContainerSelectors.join(', ');
        document.querySelectorAll(sel).forEach(manageContainer);
        containerObserver.observe(document.body, { childList: true, subtree: true });
        logDebug("Main container observer is active.");
    }
    function observeChapters() {
        const targetNode = document.getElementById('root');
        if (!targetNode) return;
        targetNode.querySelectorAll('a[href*="/manga/"][href*="/chapter/"]').forEach(addOcrButtonToChapter);
        chapterObserver.observe(targetNode, { childList: true, subtree: true });
    }

    // --- Image Handling & OCR ---
    function observeImageForSrcChange(img) {
        const process = (src) => { if (src?.includes('/api/v1/manga/')) { primeImageForOcr(img); return true; } return false; };
        if (process(img.src) || attachedAttributeObservers.has(img)) return;
        const attrObserver = new MutationObserver((mutations) => { if (mutations.some(m => m.attributeName === 'src' && process(img.src))) { attrObserver.disconnect(); attachedAttributeObservers.delete(img); } });
        attrObserver.observe(img, { attributes: true }); attachedAttributeObservers.set(img, attrObserver);
    }
    function primeImageForOcr(img) {
        if (managedElements.has(img) || ocrDataCache.get(img) === 'pending') return;
        const doProcess = () => { img.crossOrigin = "anonymous"; processImage(img, img.src); };
        if (img.complete && img.naturalHeight > 0) doProcess(); else img.addEventListener('load', doProcess, { once: true });
    }
    function processImage(img, sourceUrl) {
        if (ocrDataCache.has(img)) { displayOcrResults(img); return; }
        logDebug(`Requesting OCR for ...${sourceUrl.slice(-30)}`);
        ocrDataCache.set(img, 'pending');
        const context = document.title;
        let ocrRequestUrl = `${settings.ocrServerUrl}/ocr?url=${encodeURIComponent(sourceUrl)}&context=${encodeURIComponent(context)}`;
        if (settings.imageServerUser) ocrRequestUrl += `&user=${encodeURIComponent(settings.imageServerUser)}&pass=${encodeURIComponent(settings.imageServerPassword)}`;
        GM_xmlhttpRequest({
            method: 'GET', url: ocrRequestUrl, timeout: 45000,
            onload: (res) => { try { const data = JSON.parse(res.responseText); if (data.error) throw new Error(data.error); if (!Array.isArray(data)) throw new Error('Server response not a valid OCR data array.'); ocrDataCache.set(img, data); displayOcrResults(img); } catch (e) { logDebug(`OCR Error for ${sourceUrl.slice(-30)}: ${e.message}`); ocrDataCache.delete(img); } },
            onerror: () => { logDebug(`Connection error.`); ocrDataCache.delete(img); },
            ontimeout: () => { logDebug(`Request timed out.`); ocrDataCache.delete(img); }
        });
    }

    // --- Rendering & Interaction Logic ---
    function calculateAndApplyStylesForSingleBox(box, imgRect) {
        if (!measurementSpan || !box || !imgRect || imgRect.width === 0 || imgRect.height === 0) return;
        const ocrData = box._ocrData, text = ocrData.text || '';
        const availableWidth = box.offsetWidth + settings.boundingBoxAdjustment, availableHeight = box.offsetHeight + settings.boundingBoxAdjustment;
        if (!text || availableWidth <= 0 || availableHeight <= 0) return;
        const isMerged = ocrData.isMerged || text.includes(textSeparator);
        const findBestFitSize = (isVerticalSearch) => {
            measurementSpan.style.writingMode = isVerticalSearch ? 'vertical-rl' : 'horizontal-tb';
            measurementSpan.style.whiteSpace = isMerged ? 'normal' : 'nowrap';
            measurementSpan.innerHTML = isMerged ? box.innerHTML : '';
            if (!isMerged) measurementSpan.textContent = text;
            let low = 1, high = 200, bestSize = 1;
            while (low <= high) { const mid = Math.floor((low + high) / 2); if (mid <= 0) break; measurementSpan.style.fontSize = `${mid}px`; const fits = isMerged ? (measurementSpan.offsetWidth <= availableWidth && measurementSpan.offsetHeight <= availableHeight) : (isVerticalSearch ? measurementSpan.offsetHeight <= availableHeight : measurementSpan.offsetWidth <= availableWidth); if (fits) { bestSize = mid; low = mid + 1; } else { high = mid - 1; } } return bestSize;
        };
        const horizontalFitSize = findBestFitSize(false), verticalFitSize = findBestFitSize(true);
        let finalFontSize = 0, isVertical = false;
        if (ocrData.forcedOrientation === 'vertical') { isVertical = true; finalFontSize = verticalFitSize; }
        else if (ocrData.forcedOrientation === 'horizontal') { isVertical = false; finalFontSize = horizontalFitSize; }
        else if (settings.textOrientation === 'forceVertical') { isVertical = true; finalFontSize = verticalFitSize; }
        else if (settings.textOrientation === 'forceHorizontal') { isVertical = false; finalFontSize = horizontalFitSize; }
        else { isVertical = verticalFitSize > horizontalFitSize; finalFontSize = isVertical ? verticalFitSize : horizontalFitSize; }
        const multiplier = isVertical ? settings.fontMultiplierVertical : settings.fontMultiplierHorizontal;
        box.style.fontSize = `${finalFontSize * multiplier}px`;
        box.classList.toggle('gemini-ocr-text-vertical', isVertical);
    }
    function calculateAndApplyOptimalStyles_Optimized(overlay, imgRect) {
        if (!measurementSpan || imgRect.width === 0 || imgRect.height === 0) return;
        const boxes = Array.from(overlay.querySelectorAll('.gemini-ocr-text-box'));
        if (boxes.length === 0) return;
        const baseStyle = getComputedStyle(boxes[0]);
        Object.assign(measurementSpan.style, { fontFamily: baseStyle.fontFamily, fontWeight: baseStyle.fontWeight, letterSpacing: baseStyle.letterSpacing });
        for (const box of boxes) calculateAndApplyStylesForSingleBox(box, imgRect);
        measurementSpan.style.writingMode = 'horizontal-tb';
    }
    function showOverlay(overlay, image) {
        if (activeOverlay && activeOverlay !== overlay) hideActiveOverlay();
        activeOverlay = overlay;
        activeImageForExport = image;
        overlay.classList.add('is-focused');
        const rect = image.getBoundingClientRect();
        calculateAndApplyOptimalStyles_Optimized(overlay, rect);
        UI.globalAnkiButton?.classList.remove('is-hidden');
    }
    function hideActiveOverlay() {
        if (!activeOverlay) return;
        activeOverlay.classList.remove('is-focused', 'has-manual-highlight');
        activeOverlay.querySelectorAll('.manual-highlight, .selected-for-merge').forEach(b => b.classList.remove('manual-highlight', 'selected-for-merge'));
        mergeState.anchorBox = null;
        UI.globalAnkiButton?.classList.add('is-hidden');
        if (activeImageForExport === managedElements.get(activeOverlay)?.image) activeImageForExport = null;
        activeOverlay = null;
    }
    function isModifierPressed(event, keyName) { if (!keyName) return false; const k = keyName.toLowerCase(); return (k === 'ctrl' || k === 'control') ? event.ctrlKey : (k === 'alt') ? event.altKey : (k === 'shift') ? event.shiftKey : (k === 'meta' || k === 'win' || k === 'cmd') ? event.metaKey : false; }
    function handleBoxDelete(boxElement, sourceImage) {
        logDebug(`Deleting box: "${boxElement.dataset.fullText}"`);
        const data = ocrDataCache.get(sourceImage);
        if (!data) return;
        const updatedData = data.filter((item, index) => index !== boxElement._ocrDataIndex);
        ocrDataCache.set(sourceImage, updatedData);
        boxElement.remove();
    }
    function handleBoxMerge(targetBox, sourceBox, sourceImage, overlay) {
        logDebug(`Merging "${sourceBox.dataset.fullText}" into "${targetBox.dataset.fullText}"`);
        const originalData = ocrDataCache.get(sourceImage);
        if (!originalData) return;

        const targetData = targetBox._ocrData;
        const sourceData = sourceBox._ocrData;
        const combinedText = (targetData.text || '') + (settings.addSpaceOnMerge ? ' ' : textSeparator) + (sourceData.text || '');

        const tb = targetData.tightBoundingBox;
        const sb = sourceData.tightBoundingBox;
        const newRight = Math.max(tb.x + tb.width, sb.x + sb.width);
        const newBottom = Math.max(tb.y + tb.height, sb.y + sb.height);
        const newBoundingBox = { x: Math.min(tb.x, sb.x), y: Math.min(tb.y, sb.y), width: 0, height: 0 };
        newBoundingBox.width = newRight - newBoundingBox.x;
        newBoundingBox.height = newBottom - newBoundingBox.y;

        const areBothVertical = targetBox.classList.contains('gemini-ocr-text-vertical') && sourceBox.classList.contains('gemini-ocr-text-vertical');
        const newOcrItem = { text: combinedText, tightBoundingBox: newBoundingBox, forcedOrientation: areBothVertical ? 'vertical' : 'auto', isMerged: true };

        const indicesToDelete = new Set([targetBox._ocrDataIndex, sourceBox._ocrDataIndex]);
        const newData = originalData.filter((item, index) => !indicesToDelete.has(index));
        newData.push(newOcrItem);
        ocrDataCache.set(sourceImage, newData);

        targetBox.remove();
        sourceBox.remove();

        const newBoxElement = document.createElement('div');
        newBoxElement.className = 'gemini-ocr-text-box';

		const sepRe1 = new RegExp(textSeparator, 'g');

        newBoxElement.innerHTML = newOcrItem.text.replace(sepRe1, "<br>");
        newBoxElement.dataset.fullText = newOcrItem.text;
        newBoxElement._ocrData = newOcrItem;
        newBoxElement._ocrDataIndex = newData.length - 1;
        newBoxElement.style.whiteSpace = 'normal';
        newBoxElement.style.textAlign = 'start';
        Object.assign(newBoxElement.style, { left: `${newOcrItem.tightBoundingBox.x*100}%`, top: `${newOcrItem.tightBoundingBox.y*100}%`, width: `${newOcrItem.tightBoundingBox.width*100}%`, height: `${newOcrItem.tightBoundingBox.height*100}%` });
        overlay.appendChild(newBoxElement);
        calculateAndApplyStylesForSingleBox(newBoxElement, sourceImage.getBoundingClientRect());
        mergeState.anchorBox = newBoxElement;
        newBoxElement.classList.add('selected-for-merge');
    }
    function displayOcrResults(targetImg) {
        if (managedElements.has(targetImg)) return;
        const data = ocrDataCache.get(targetImg);
        if (!data || data === 'pending' || !Array.isArray(data)) return;

        const overlay = document.createElement('div');
        overlay.className = `gemini-ocr-decoupled-overlay interaction-mode-${settings.interactionMode}`;
        overlay.classList.toggle('solo-hover-mode', settings.soloHoverMode);

        data.forEach((item, index) => {
            const ocrBox = document.createElement('div');
            ocrBox.className = 'gemini-ocr-text-box';
            ocrBox.dataset.fullText = item.text;
            ocrBox._ocrData = item; ocrBox._ocrDataIndex = index;

			const sepRe2 = new RegExp(textSeparator, 'g');

            ocrBox.innerHTML = item.text.replace(sepRe2, "<br>");
            if (item.isMerged) { ocrBox.style.whiteSpace = 'normal'; ocrBox.style.textAlign = 'start'; }
            Object.assign(ocrBox.style, { left: `${item.tightBoundingBox.x*100}%`, top: `${item.tightBoundingBox.y*100}%`, width: `${item.tightBoundingBox.width*100}%`, height: `${item.tightBoundingBox.height*100}%` });
            overlay.appendChild(ocrBox);
        });
        document.body.appendChild(overlay);

        const state = { overlay, lastWidth: 0, lastHeight: 0, image: targetImg };
        managedElements.set(targetImg, state);

        const show = () => { clearTimeout(hideButtonTimer); showOverlay(overlay, targetImg); };
        const hide = () => { hideButtonTimer = setTimeout(() => { if (!overlay.querySelector('.selected-for-merge')) hideActiveOverlay(); }, 300); };
        [targetImg, overlay].forEach(el => { el.addEventListener('mouseenter', show); el.addEventListener('mouseleave', hide); });

        overlay.addEventListener('click', (e) => {
            const clickedBox = e.target.closest('.gemini-ocr-text-box');
            if (!clickedBox) {
                overlay.querySelectorAll('.manual-highlight, .selected-for-merge').forEach(b => b.classList.remove('manual-highlight', 'selected-for-merge'));
                overlay.classList.remove('has-manual-highlight');
                mergeState.anchorBox = null;
                return;
            }
            e.stopPropagation();

            if (isModifierPressed(e, settings.deleteModifierKey)) {
                handleBoxDelete(clickedBox, targetImg);
            } else if (isModifierPressed(e, settings.mergeModifierKey)) {
                if (!mergeState.anchorBox) {
                    mergeState.anchorBox = clickedBox;
                    clickedBox.classList.add('selected-for-merge');
                } else if (mergeState.anchorBox !== clickedBox) {
                    handleBoxMerge(mergeState.anchorBox, clickedBox, targetImg, overlay);
                }
            } else if (isModifierPressed(e, cropModifierKey)) {
				logDebug('Pressed');
                exportCropImageToAnki(activeImageForExport);
            } else if (settings.interactionMode === 'click') {
                overlay.querySelectorAll('.manual-highlight').forEach(b => b.classList.remove('manual-highlight'));
                clickedBox.classList.add('manual-highlight');
                overlay.classList.add('has-manual-highlight');
            }
        });

        resizeObserver.observe(targetImg);
        intersectionObserver.observe(targetImg);
    }

    // --- Anki & Batch Processing ---
    async function ankiConnectRequest(action, params = {}) { return new Promise((resolve, reject) => { GM_xmlhttpRequest({ method: 'POST', url: settings.ankiConnectUrl, data: JSON.stringify({ action, version: 6, params }), headers: { 'Content-Type': 'application/json; charset=UTF-8' }, timeout: 15000, onload: (res) => { try { const data = JSON.parse(res.responseText); if (data.error) reject(new Error(data.error)); else resolve(data.result); } catch (e) { reject(new Error('Failed to parse Anki-Connect response.')); } }, onerror: () => reject(new Error('Connection to Anki-Connect failed.')), ontimeout: () => reject(new Error('Anki-Connect request timed out.')) }); }); }
    async function exportImageToAnki(targetImg) { if (!settings.ankiImageField) { alert('Anki Image Field is not set.'); return false; } if (!targetImg?.complete || !targetImg.naturalHeight) { alert('Anki Export Failed: Image not valid.'); return false; } try { const canvas = document.createElement('canvas'); canvas.width = targetImg.naturalWidth; canvas.height = targetImg.naturalHeight; const ctx = canvas.getContext('2d'); ctx.drawImage(targetImg, 0, 0); const base64data = canvas.toDataURL('image/png').split(',')[1]; if (!base64data) throw new Error("Canvas toDataURL failed."); const filename = `screenshot_${Date.now()}.png`; await ankiConnectRequest('storeMediaFile', { filename, data: base64data }); const notes = await ankiConnectRequest('findNotes', { query: 'added:1' }); if (!notes?.length) throw new Error('No recently added cards found. Create one first.'); const lastNoteId = notes.sort((a, b) => b - a)[0]; await ankiConnectRequest('updateNoteFields', { note: { id: lastNoteId, fields: { [settings.ankiImageField]: `<img src="${filename}">` } } }); return true; } catch (error) { logDebug(`Anki Export Error: ${error.message}`); alert(`Anki Export Failed: ${error.message}`); return false; } }

	// Shift+click to crop image
	async function exportCropImageToAnki(targetImg) {
		if (!settings.ankiImageField) { alert('Anki Image Field is not set in settings.'); return false; }
		if (!targetImg || !targetImg.complete || !targetImg.naturalHeight) { alert('Anki Export Failed: Image not valid or loaded.'); return false; }

		try {
			// === 1. Build popup dynamically ===
			const overlay = document.createElement('div');
			Object.assign(overlay.style, {
				position: 'fixed', top: 0, left: 0, right: 0, bottom: 0,
				background: 'rgba(0,0,0,0.6)',
				display: 'flex', justifyContent: 'center', alignItems: 'center',
				zIndex: 9999
			});

			const wrapper = document.createElement('div');
			wrapper.style.background = '#fff';
			wrapper.style.padding = '10px';
			wrapper.style.borderRadius = '8px';
			wrapper.style.textAlign = 'center';

			const canvas = document.createElement('canvas');
			canvas.width = targetImg.naturalWidth;
			canvas.height = targetImg.naturalHeight;
			canvas.style.maxWidth = '80vw';
			canvas.style.maxHeight = '80vh';
			canvas.style.cursor = 'crosshair';
			const ctx = canvas.getContext('2d');
			ctx.drawImage(targetImg, 0, 0);

			const cropBtn = document.createElement('button');
			cropBtn.textContent = 'Crop & Continue';
			cropBtn.style.margin = '5px';

			const cancelBtn = document.createElement('button');
			cancelBtn.textContent = 'Cancel';
			cancelBtn.style.margin = '5px';

			wrapper.appendChild(canvas);
			wrapper.appendChild(document.createElement('br'));
			wrapper.appendChild(cropBtn);
			wrapper.appendChild(cancelBtn);
			overlay.appendChild(wrapper);
			document.body.appendChild(overlay);

			// === 2. Cropping state ===
			let selection = null; // {x,y,w,h}
			let dragMode = null;  // "move", "resize", or null
			let dragOffset = {x: 0, y: 0};
			let activeHandle = null; // which corner/side we are resizing from

			const theme = COLOR_THEMES[settings.colorTheme] || COLOR_THEMES.blue;

			function getScale() {
				const rect = canvas.getBoundingClientRect();
				return {
					scaleX: canvas.width / rect.width,
					scaleY: canvas.height / rect.height,
					rect
				};
			}

			function redraw() {
				ctx.drawImage(targetImg, 0, 0);
				if (selection) {
					ctx.strokeStyle = `rgba(${theme.accent}, 1)`;
					ctx.lineWidth = 2;
					ctx.strokeRect(selection.x, selection.y, selection.w, selection.h);
					ctx.fillStyle = `rgba(${theme.background}, 0.5)`;
					ctx.fillRect(selection.x, selection.y, selection.w, selection.h);
					drawHandles();
				}
			}

			function drawHandles() {
				const size = 20;
				ctx.fillStyle = `rgba(${theme.accent}, 1)`;
				const {x, y, w, h} = selection;
				const points = [
					[x, y], [x + w / 2, y], [x + w, y],
					[x, y + h / 2], [x + w, y + h / 2],
					[x, y + h], [x + w / 2, y + h], [x + w, y + h]
				];
				points.forEach(([px, py]) => ctx.fillRect(px - size/2, py - size/2, size, size));
			}

			function pointInSelection(px, py) {
				return px >= selection.x && px <= selection.x + selection.w &&
					   py >= selection.y && py <= selection.y + selection.h;
			}

			function getHandleUnderCursor(px, py) {
				if (!selection) return null;
				const handleSize = 30;
				const {x, y, w, h} = selection;
				const handles = [
					{name: 'nw', cx: x, cy: y},
					{name: 'n',  cx: x + w/2, cy: y},
					{name: 'ne', cx: x + w, cy: y},
					{name: 'w',  cx: x, cy: y + h/2},
					{name: 'e',  cx: x + w, cy: y + h/2},
					{name: 'sw', cx: x, cy: y + h},
					{name: 's',  cx: x + w/2, cy: y + h},
					{name: 'se', cx: x + w, cy: y + h}
				];
				return handles.find(h => Math.abs(px - h.cx) <= handleSize/2 && Math.abs(py - h.cy) <= handleSize/2);
			}

			// === 3. Mouse events ===
			canvas.addEventListener('mousedown', e => {
				const {scaleX, scaleY, rect} = getScale();
				const px = (e.clientX - rect.left) * scaleX;
				const py = (e.clientY - rect.top) * scaleY;

				if (selection) {
					const handle = getHandleUnderCursor(px, py);
					if (handle) {
						dragMode = 'resize';
						activeHandle = handle.name;
						return;
					}
					if (pointInSelection(px, py)) {
						dragMode = 'move';
						dragOffset.x = px - selection.x;
						dragOffset.y = py - selection.y;
						return;
					}
				}
				// Start new selection
				selection = {x: px, y: py, w: 0, h: 0};
				dragMode = 'new';
			});

			canvas.addEventListener('mousemove', e => {
				if (!dragMode) return;
				const {scaleX, scaleY, rect} = getScale();
				const px = (e.clientX - rect.left) * scaleX;
				const py = (e.clientY - rect.top) * scaleY;

				if (dragMode === 'new') {
					selection.w = px - selection.x;
					selection.h = py - selection.y;
				} else if (dragMode === 'move') {
					selection.x = px - dragOffset.x;
					selection.y = py - dragOffset.y;
				} else if (dragMode === 'resize') {
					const {x, y, w, h} = selection;
					let nx = x, ny = y, nw = w, nh = h;
					if (activeHandle.includes('n')) { nh += (ny - py); ny = py; }
					if (activeHandle.includes('s')) { nh = py - ny; }
					if (activeHandle.includes('w')) { nw += (nx - px); nx = px; }
					if (activeHandle.includes('e')) { nw = px - nx; }
					selection.x = nx; selection.y = ny; selection.w = nw; selection.h = nh;
				}
				redraw();
			});

			canvas.addEventListener('mouseup', () => dragMode = null);
			canvas.addEventListener('mouseout', () => dragMode = null);

			redraw();

			// === 4. Wait for crop or cancel ===
			const croppedData = await new Promise((resolve, reject) => {
				cropBtn.addEventListener('click', () => {
					if (!selection) { alert('Please select an area first!'); return; }
					let sx = selection.x, sy = selection.y, sw = selection.w, sh = selection.h;
					if (sw < 0) { sx += sw; sw = Math.abs(sw); }
					if (sh < 0) { sy += sh; sh = Math.abs(sh); }
					if (sw < 1 || sh < 1) { alert('Selection too small!'); return; }

					const croppedCanvas = document.createElement('canvas');
					croppedCanvas.width = sw;
					croppedCanvas.height = sh;
					croppedCanvas.getContext('2d').drawImage(targetImg, sx, sy, sw, sh, 0, 0, sw, sh);

					const data = croppedCanvas.toDataURL('image/png').split(',')[1];
					document.body.removeChild(overlay);
					resolve(data);
				});

				cancelBtn.addEventListener('click', () => {
					document.body.removeChild(overlay);
					reject(new Error('User cancelled cropping.'));
				});
			});

			// === 5. Continue with original Anki export ===
			const filename = `screenshot_${Date.now()}.png`;
			await ankiConnectRequest('storeMediaFile', { filename, data: croppedData });
			const notes = await ankiConnectRequest('findNotes', { query: 'added:1' });
			if (!notes || notes.length === 0) throw new Error('No recently added cards found. Create a card first.');
			const lastNoteId = notes.sort((a, b) => b - a)[0];
			await ankiConnectRequest('updateNoteFields', {
				note: { id: lastNoteId, fields: { [settings.ankiImageField]: `<img src="${filename}">` } }
			});

			return true;

		} catch (error) { logDebug(`Anki Export Error: ${error.message}`); alert(`Anki Export Failed: ${error.message}`); return false; }
	}

    async function runProbingProcess(baseUrl, btn) {
        logDebug(`Requesting SERVER-SIDE job for: ${baseUrl}`); const originalText = btn.textContent; btn.disabled = true; btn.textContent = 'Starting...';
        const postData = { baseUrl: baseUrl, user: settings.imageServerUser, pass: settings.imageServerPassword, context: document.title };
        GM_xmlhttpRequest({
            method: 'POST', url: `${settings.ocrServerUrl}/preprocess-chapter`, headers: { 'Content-Type': 'application/json' }, data: JSON.stringify(postData), timeout: 10000,
            onload: (res) => { try { const data = JSON.parse(res.responseText); if (res.status === 202 && data.status === 'accepted') { btn.textContent = 'Accepted'; btn.style.borderColor = '#3498db'; checkServerStatus(); } else { throw new Error(data.error || `Server responded with status ${res.status}`); } } catch (e) { logDebug(`Error starting chapter job: ${e.message}`); btn.textContent = 'Error!'; btn.style.borderColor = '#c032b'; alert(`Failed to start chapter job: ${e.message}`); } },
            onerror: () => { logDebug('Connection error on chapter job.'); btn.textContent = 'Conn. Error!'; btn.style.borderColor = '#c0392b'; alert('Failed to connect to the OCR server to start the job.'); },
            ontimeout: () => { logDebug('Timeout on chapter job.'); btn.textContent = 'Timeout!'; btn.style.borderColor = '#c0392b'; alert('The request to start the chapter job timed out.'); },
            onloadend: () => { setTimeout(() => { if (btn.isConnected) { btn.textContent = originalText; btn.style.borderColor = ''; btn.disabled = false; } }, 3500); }
        });
    }
    async function batchProcessCurrentChapterFromURL() { const urlMatch = window.location.pathname.match(/\/manga\/\d+\/chapter\/\d+/); if (!urlMatch) return alert(`Error: URL does not match '.../manga/ID/chapter/ID'.`); await runProbingProcess(`${window.location.origin}/api/v1${urlMatch[0]}/page/`, UI.batchChapterBtn); }
    async function handleChapterBatchClick(event) { event.preventDefault(); event.stopPropagation(); const chapterLink = event.currentTarget.closest('a[href*="/manga/"][href*="/chapter/"]'); if (!chapterLink?.href) return; const urlPath = new URL(chapterLink.href).pathname; await runProbingProcess(`${window.location.origin}/api/v1${urlPath}/page/`, event.currentTarget); }
    function addOcrButtonToChapter(chapterLinkElement) { const moreButton = chapterLinkElement.querySelector('button[aria-label="more"]'); if (!moreButton) return; const actionContainer = moreButton.parentElement; if (!actionContainer || actionContainer.querySelector('.gemini-ocr-chapter-batch-btn')) return; const ocrButton = document.createElement('button'); ocrButton.textContent = 'OCR'; ocrButton.className = 'gemini-ocr-chapter-batch-btn'; ocrButton.title = 'Queue this chapter for background pre-processing on the server'; ocrButton.addEventListener('click', handleChapterBatchClick); actionContainer.insertBefore(ocrButton, moreButton); }

    // --- UI, Styles and Initialization ---
    // --- MODIFIED ---
    function applyTheme() {
        const theme = COLOR_THEMES[settings.colorTheme] || COLOR_THEMES.blue;
        const cssVars = `:root { --accent: ${theme.accent||'72,144,255'}; --background: ${theme.background||'229,243,255'}; --modal-header-color: rgba(${theme.accent||'72,144,255'}, 1); --ocr-dimmed-opacity: ${settings.dimmedOpacity}; --ocr-focus-scale: ${settings.focusScaleMultiplier}; }`;
        let styleTag = document.getElementById('gemini-ocr-dynamic-styles');
        if (!styleTag) { styleTag = document.createElement('style'); styleTag.id = 'gemini-ocr-dynamic-styles'; document.head.appendChild(styleTag); }
        styleTag.textContent = cssVars;

        document.body.className = document.body.className.replace(/\bocr-theme-\S+/g, '');
        document.body.classList.add(`ocr-theme-${settings.colorTheme}`);
        document.body.classList.toggle('ocr-brightness-dark', settings.brightnessMode === 'dark');
        document.body.classList.toggle('ocr-brightness-light', settings.brightnessMode === 'light');

        // Apply focus color mode class
        document.body.className = document.body.className.replace(/\bocr-focus-color-mode-\S+/g, '');
        if (settings.focusFontColor && settings.focusFontColor !== 'default') {
            document.body.classList.add(`ocr-focus-color-mode-${settings.focusFontColor}`);
        }
    }
    // --- MODIFIED ---
    function createUI() {
        GM_addStyle(`
            html.ocr-scroll-fix-active { overflow: hidden !important; } html.ocr-scroll-fix-active body { overflow-y: auto !important; overflow-x: hidden !important; }
            .gemini-ocr-decoupled-overlay { position: fixed; z-index: 9998; pointer-events: none; opacity: 0; display: none; }
            .gemini-ocr-decoupled-overlay.is-focused { opacity: 1; display: block; }
            .gemini-ocr-decoupled-overlay.is-focused .gemini-ocr-text-box { pointer-events: auto; }
            ::selection { background-color: rgba(var(--accent), 1); color: #FFFFFF; }
            .gemini-ocr-text-box { position: absolute; display: flex; align-items: center; justify-content: center; text-align: center; box-sizing: border-box; user-select: text; cursor: pointer; transition: all 0.2s ease-in-out; overflow: hidden; font-family: 'Noto Sans JP', sans-serif; font-weight: 600; padding: 4px; border-radius: 4px; border: none; text-shadow: none; pointer-events: none; }
            .gemini-ocr-text-box.selected-for-merge { outline: 3px solid #f1c40f !important; outline-offset: 2px; box-shadow: 0 0 12px #f1c40f !important; z-index: 2; }
            body.ocr-brightness-light .gemini-ocr-text-box { background: rgba(var(--background), 1); color: rgba(var(--accent), 0.5); box-shadow: 0 0 0 0.1em rgba(var(--background), 1); }
            body.ocr-brightness-light .interaction-mode-hover.is-focused .gemini-ocr-text-box:hover,
            body.ocr-brightness-light .interaction-mode-click.is-focused .manual-highlight { background: rgba(var(--background), 1); color: rgba(var(--accent), 1); box-shadow: 0 0 0 0.1em rgba(var(--background), 1), 0 0 0 0.2em rgba(var(--accent), 1); }
            body.ocr-brightness-dark .gemini-ocr-text-box { background: rgba(29, 34, 39, 0.9); color: rgba(var(--background), 0.7); box-shadow: 0 0 0 0.1em rgba(var(--accent), 0.4); backdrop-filter: blur(2px); }
            body.ocr-brightness-dark .interaction-mode-hover.is-focused .gemini-ocr-text-box:hover,
            body.ocr-brightness-dark .interaction-mode-click.is-focused .manual-highlight { background: rgba(var(--accent), 1); color: #FFFFFF; box-shadow: 0 0 0 0.1em rgba(var(--accent), 0.4), 0 0 0 0.2em rgba(var(--background), 1); }

            /* --- NEW --- Focus Color Logic */
            .ocr-focus-color-mode-black .interaction-mode-hover.is-focused .gemini-ocr-text-box:hover,
            .ocr-focus-color-mode-black .interaction-mode-click.is-focused .manual-highlight { color: #000000 !important; text-shadow: 0 0 2px #FFFFFF, 0 0 4px #FFFFFF; }
            .ocr-focus-color-mode-white .interaction-mode-hover.is-focused .gemini-ocr-text-box:hover,
            .ocr-focus-color-mode-white .interaction-mode-click.is-focused .manual-highlight { color: #FFFFFF !important; text-shadow: 0 0 2px #000000, 0 0 4px #000000; }
            .ocr-focus-color-mode-difference .interaction-mode-hover.is-focused .gemini-ocr-text-box:hover,
            .ocr-focus-color-mode-difference .interaction-mode-click.is-focused .manual-highlight { color: white !important; mix-blend-mode: difference; background: transparent !important; box-shadow: none !important; }

            .gemini-ocr-text-vertical { writing-mode: vertical-rl; text-orientation: upright; }
            .interaction-mode-hover.is-focused .gemini-ocr-text-box:hover,
            .interaction-mode-click.is-focused .manual-highlight { z-index: 1; transform: scale(var(--ocr-focus-scale)); overflow: visible !important; }
            .interaction-mode-hover.is-focused:not(.solo-hover-mode):has(.gemini-ocr-text-box:hover) .gemini-ocr-text-box:not(:hover),
            .interaction-mode-click.is-focused.has-manual-highlight .gemini-ocr-text-box:not(.manual-highlight) { opacity: var(--ocr-dimmed-opacity); }
            .solo-hover-mode.is-focused .gemini-ocr-text-box { opacity: 0; }
            .solo-hover-mode.is-focused .gemini-ocr-text-box:hover { opacity: 1; }
            .gemini-ocr-chapter-batch-btn { font-family: "Roboto","Helvetica","Arial",sans-serif; font-weight: 500; font-size: 0.75rem; padding: 2px 8px; border-radius: 4px; border: 1px solid rgba(240,153,136,0.5); color: #f09988; background-color: transparent; cursor: pointer; margin-right: 4px; transition: all 150ms; min-width: 80px; text-align: center; } .gemini-ocr-chapter-batch-btn:hover { background-color: rgba(240,153,136,0.08); } .gemini-ocr-chapter-batch-btn:disabled { color: grey; border-color: grey; cursor: wait; } #gemini-ocr-settings-button { position: fixed; bottom: 15px; right: 15px; z-index: 2147483647; background: #1A1D21; color: #EAEAEA; border: 1px solid #555; border-radius: 50%; width: 50px; height: 50px; font-size: 26px; cursor: pointer; display: flex; align-items: center; justify-content: center; box-shadow: 0 4px 12px rgba(0,0,0,0.5); user-select: none; } #gemini-ocr-global-anki-export-btn { position: fixed; bottom: 75px; right: 15px; z-index: 2147483646; background-color: #2ecc71; color: white; border: 1px solid white; border-radius: 50%; width: 50px; height: 50px; font-size: 30px; line-height: 50px; text-align: center; cursor: pointer; transition: all 0.2s; user-select: none; box-shadow: 0 4px 12px rgba(0,0,0,0.5); } #gemini-ocr-global-anki-export-btn:hover { background-color: #27ae60; transform: scale(1.1); } #gemini-ocr-global-anki-export-btn:disabled { background-color: #95a5a6; cursor: wait; transform: none; } #gemini-ocr-global-anki-export-btn.is-hidden { opacity: 0; visibility: hidden; pointer-events: none; transform: scale(0.5); } .gemini-ocr-modal { position: fixed; top: 50%; left: 50%; transform: translate(-50%, -50%); background-color: #1A1D21; border: 1px solid var(--modal-header-color, #00BFFF); border-radius: 15px; z-index: 2147483647; color: #EAEAEA; font-family: sans-serif; box-shadow: 0 8px 32px 0 rgba(0,0,0,0.5); width: 600px; max-width: 90vw; max-height: 90vh; display: flex; flex-direction: column; } .gemini-ocr-modal.is-hidden { display: none; } .gemini-ocr-modal-header { padding: 20px 25px; border-bottom: 1px solid #444; } .gemini-ocr-modal-header h2 { margin: 0; color: var(--modal-header-color, #00BFFF); } .gemini-ocr-modal-content { padding: 10px 25px; overflow-y: auto; flex-grow: 1; } .gemini-ocr-modal-footer { padding: 15px 25px; border-top: 1px solid #444; display: flex; justify-content: flex-start; gap: 10px; align-items: center; } .gemini-ocr-modal-footer button:last-of-type { margin-left: auto; } .gemini-ocr-modal h3 { font-size: 1.1em; margin: 15px 0 10px 0; border-bottom: 1px solid #333; padding-bottom: 5px; color: var(--modal-header-color, #00BFFF); } .gemini-ocr-settings-grid { display: grid; grid-template-columns: max-content 1fr; gap: 10px 15px; align-items: center; } .full-width { grid-column: 1 / -1; } .gemini-ocr-modal input, .gemini-ocr-modal textarea, .gemini-ocr-modal select { width: 100%; padding: 8px; box-sizing: border-box; font-family: monospace; background-color: #2a2a2e; border: 1px solid #555; border-radius: 5px; color: #EAEAEA; } .gemini-ocr-modal button { padding: 10px 18px; border: none; border-radius: 5px; color: #1A1D21; cursor: pointer; font-weight: bold; } #gemini-ocr-server-status { padding: 10px; border-radius: 5px; text-align: center; cursor: pointer; transition: background-color 0.3s; } #gemini-ocr-server-status.status-ok { background-color: #27ae60; } #gemini-ocr-server-status.status-error { background-color: #c0392b; } #gemini-ocr-server-status.status-checking { background-color: #3498db; }
        `);
        // --- MODIFIED ---
        document.body.insertAdjacentHTML('beforeend', ` <button id="gemini-ocr-global-anki-export-btn" class="is-hidden" title="Export Screenshot to Anki">✚</button> <button id="gemini-ocr-settings-button">⚙️</button> <div id="gemini-ocr-settings-modal" class="gemini-ocr-modal is-hidden"> <div class="gemini-ocr-modal-header"><h2>Automatic Content OCR Settings (PC Modifier Merge)</h2></div> <div class="gemini-ocr-modal-content"> <h3>OCR & Image Source</h3><div class="gemini-ocr-settings-grid full-width"> <label for="gemini-ocr-server-url">OCR Server URL:</label><input type="text" id="gemini-ocr-server-url"> <label for="gemini-image-server-user">Image Source Username:</label><input type="text" id="gemini-image-server-user" autocomplete="username" placeholder="Optional"> <label for="gemini-image-server-password">Image Source Password:</label><input type="password" id="gemini-image-server-password" autocomplete="current-password" placeholder="Optional"> </div> <div id="gemini-ocr-server-status" class="full-width" style="margin-top: 10px;">Click to check server status</div> <h3>Anki Integration</h3><div class="gemini-ocr-settings-grid"> <label for="gemini-ocr-anki-url">Anki-Connect URL:</label><input type="text" id="gemini-ocr-anki-url"> <label for="gemini-ocr-anki-field">Image Field Name:</label><input type="text" id="gemini-ocr-anki-field" placeholder="e.g., Image"> </div> <h3>Interaction & Display</h3><div class="gemini-ocr-settings-grid"> <label for="ocr-brightness-mode">Theme Mode:</label><select id="ocr-brightness-mode"><option value="light">Light</option><option value="dark">Dark</option></select> <label for="ocr-color-theme">Color Theme:</label><select id="ocr-color-theme">${Object.keys(COLOR_THEMES).map(t=>`<option value="${t}">${t.charAt(0).toUpperCase()+t.slice(1)}</option>`).join('')}</select> <label for="ocr-interaction-mode">Highlight Mode:</label><select id="ocr-interaction-mode"><option value="hover">On Hover</option><option value="click">On Click</option></select> <label for="ocr-focus-font-color">Focus Font Color:</label><select id="ocr-focus-font-color"><option value="default">Default</option><option value="black">Black</option><option value="white">White</option><option value="difference">Difference (Blend)</option></select> <label for="ocr-dimmed-opacity">Dimmed Box Opacity (%):</label><input type="number" id="ocr-dimmed-opacity" min="0" max="100" step="5"> <label for="ocr-focus-scale-multiplier">Focus Scale Multiplier:</label><input type="number" id="ocr-focus-scale-multiplier" min="1" max="3" step="0.05"> <label for="ocr-delete-key">Delete Modifier Key:</label><input type="text" id="ocr-delete-key" placeholder="Control, Alt, Shift..."> <label for="ocr-merge-key">Merge Modifier Key:</label><input type="text" id="ocr-merge-key" placeholder="Control, Alt, Shift..."> <label for="ocr-text-orientation">Text Orientation:</label><select id="ocr-text-orientation"><option value="smart">Smart</option><option value="forceHorizontal">Horizontal</option><option value="forceVertical">Vertical</option></select> <label for="ocr-font-multiplier-horizontal">H. Font Multiplier:</label><input type="number" id="ocr-font-multiplier-horizontal" min="0.1" max="5" step="0.1"> <label for="ocr-font-multiplier-vertical">V. Font Multiplier:</label><input type="number" id="ocr-font-multiplier-vertical" min="0.1" max="5" step="0.1"> <label for="ocr-bounding-box-adjustment-input">Box Adjustment (px):</label><input type="number" id="ocr-bounding-box-adjustment-input" min="0" max="100" step="1"> </div><div class="gemini-ocr-settings-grid full-width"><label><input type="checkbox" id="gemini-ocr-solo-hover-mode"> Only show hovered box (Hover Mode)</label><label><input type="checkbox" id="gemini-ocr-add-space-on-merge"> Add space on merge</label></div> <h3>Advanced</h3><div class="gemini-ocr-settings-grid full-width"><label><input type="checkbox" id="gemini-ocr-debug-mode"> Debug Mode</label></div> <div class="gemini-ocr-settings-grid full-width"><label for="gemini-ocr-sites-config">Site Configurations (URL; OverflowFix; Containers...)</label><textarea id="gemini-ocr-sites-config" rows="6" placeholder="127.0.0.1; .overflow-fix; .container1; .container2\n"></textarea></div> </div> <div class="gemini-ocr-modal-footer"> <button id="gemini-ocr-purge-cache-btn" style="background-color: #c0392b;" title="Deletes all entries from the server's OCR cache file.">Purge Server Cache</button> <button id="gemini-ocr-batch-chapter-btn" style="background-color: #3498db;" title="Queues the current chapter on the server for background pre-processing.">Pre-process Chapter</button> <button id="gemini-ocr-debug-btn" style="background-color: #777;">Debug</button> <button id="gemini-ocr-close-btn" style="background-color: #555;">Close</button> <button id="gemini-ocr-save-btn" style="background-color: #3ad602;">Save & Reload</button> </div> </div> <div id="gemini-ocr-debug-modal" class="gemini-ocr-modal is-hidden"><div class="gemini-ocr-modal-header"><h2>Debug Log</h2></div><div class="gemini-ocr-modal-content"><textarea id="gemini-ocr-debug-log" readonly style="width:100%; height: 100%; resize:none;"></textarea></div><div class="gemini-ocr-modal-footer"><button id="gemini-ocr-close-debug-btn" style="background-color: #555;">Close</button></div></div> `);
    }
    // --- MODIFIED ---
    function bindUIEvents() {
        Object.assign(UI, {
            settingsButton: document.getElementById('gemini-ocr-settings-button'), settingsModal: document.getElementById('gemini-ocr-settings-modal'), globalAnkiButton: document.getElementById('gemini-ocr-global-anki-export-btn'), debugModal: document.getElementById('gemini-ocr-debug-modal'), serverUrlInput: document.getElementById('gemini-ocr-server-url'), imageServerUserInput: document.getElementById('gemini-image-server-user'), imageServerPasswordInput: document.getElementById('gemini-image-server-password'), ankiUrlInput: document.getElementById('gemini-ocr-anki-url'), ankiFieldInput: document.getElementById('gemini-ocr-anki-field'), debugModeCheckbox: document.getElementById('gemini-ocr-debug-mode'), soloHoverCheckbox: document.getElementById('gemini-ocr-solo-hover-mode'), addSpaceOnMergeCheckbox: document.getElementById('gemini-ocr-add-space-on-merge'), interactionModeSelect: document.getElementById('ocr-interaction-mode'), dimmedOpacityInput: document.getElementById('ocr-dimmed-opacity'), textOrientationSelect: document.getElementById('ocr-text-orientation'), colorThemeSelect: document.getElementById('ocr-color-theme'), brightnessModeSelect: document.getElementById('ocr-brightness-mode'), focusFontColorSelect: document.getElementById('ocr-focus-font-color'), deleteKeyInput: document.getElementById('ocr-delete-key'), mergeKeyInput: document.getElementById('ocr-merge-key'), fontMultiplierHorizontalInput: document.getElementById('ocr-font-multiplier-horizontal'), fontMultiplierVerticalInput: document.getElementById('ocr-font-multiplier-vertical'), boundingBoxAdjustmentInput: document.getElementById('ocr-bounding-box-adjustment-input'), focusScaleMultiplierInput: document.getElementById('ocr-focus-scale-multiplier'), sitesConfigTextarea: document.getElementById('gemini-ocr-sites-config'), statusDiv: document.getElementById('gemini-ocr-server-status'), debugLogTextarea: document.getElementById('gemini-ocr-debug-log'), saveBtn: document.getElementById('gemini-ocr-save-btn'), closeBtn: document.getElementById('gemini-ocr-close-btn'), debugBtn: document.getElementById('gemini-ocr-debug-btn'), closeDebugBtn: document.getElementById('gemini-ocr-close-debug-btn'), batchChapterBtn: document.getElementById('gemini-ocr-batch-chapter-btn'), purgeCacheBtn: document.getElementById('gemini-ocr-purge-cache-btn'),
        });
        UI.settingsButton.addEventListener('click', () => UI.settingsModal.classList.toggle('is-hidden'));
        UI.globalAnkiButton.addEventListener('click', async () => { if (activeImageForExport) { const btn = UI.globalAnkiButton; btn.textContent = '…'; btn.disabled = true; const success = await exportImageToAnki(activeImageForExport); btn.textContent = success ? '✓' : '✖'; btn.style.backgroundColor = success ? '#27ae60' : '#c0392b'; setTimeout(() => { btn.textContent = '✚'; btn.style.backgroundColor = ''; btn.disabled = false; }, 2000); } else { alert("Hover an image to select it for export."); } });
        UI.globalAnkiButton.addEventListener('mouseenter', () => clearTimeout(hideButtonTimer));
        UI.globalAnkiButton.addEventListener('mouseleave', () => { hideButtonTimer = setTimeout(() => { UI.globalAnkiButton.classList.add('is-hidden'); activeImageForExport = null; }, 300); });
        UI.statusDiv.addEventListener('click', checkServerStatus);
        UI.closeBtn.addEventListener('click', () => UI.settingsModal.classList.add('is-hidden'));
        UI.debugBtn.addEventListener('click', () => { UI.debugLogTextarea.value = debugLog.join('\n'); UI.debugModal.classList.remove('is-hidden'); UI.debugLogTextarea.scrollTop = UI.debugLogTextarea.scrollHeight; });
        UI.closeDebugBtn.addEventListener('click', () => UI.debugModal.classList.add('is-hidden'));
        UI.batchChapterBtn.addEventListener('click', batchProcessCurrentChapterFromURL);
        UI.purgeCacheBtn.addEventListener('click', purgeServerCache);
        UI.saveBtn.addEventListener('click', async () => {
            const newSettings = {
                ocrServerUrl: UI.serverUrlInput.value.trim(), imageServerUser: UI.imageServerUserInput.value.trim(), imageServerPassword: UI.imageServerPasswordInput.value, ankiConnectUrl: UI.ankiUrlInput.value.trim(), ankiImageField: UI.ankiFieldInput.value.trim(), debugMode: UI.debugModeCheckbox.checked, soloHoverMode: UI.soloHoverCheckbox.checked, addSpaceOnMerge: UI.addSpaceOnMergeCheckbox.checked, interactionMode: UI.interactionModeSelect.value, textOrientation: UI.textOrientationSelect.value, colorTheme: UI.colorThemeSelect.value, brightnessMode: UI.brightnessModeSelect.value, deleteModifierKey: UI.deleteKeyInput.value.trim(), mergeModifierKey: UI.mergeKeyInput.value.trim(), dimmedOpacity: (parseInt(UI.dimmedOpacityInput.value, 10) || 30) / 100, fontMultiplierHorizontal: parseFloat(UI.fontMultiplierHorizontalInput.value) || 1.0, fontMultiplierVertical: parseFloat(UI.fontMultiplierVerticalInput.value) || 1.0, boundingBoxAdjustment: parseInt(UI.boundingBoxAdjustmentInput.value, 10) || 0, focusScaleMultiplier: parseFloat(UI.focusScaleMultiplierInput.value) || 1.1,
                focusFontColor: UI.focusFontColorSelect.value, // --- NEW ---
                sites: UI.sitesConfigTextarea.value.split('\n').filter(line => line.trim()).map(line => { const parts = line.split(';').map(s => s.trim()); return { urlPattern: parts[0] || '', overflowFixSelector: parts[1] || '', imageContainerSelectors: parts.slice(2,-1).filter(s => s), contentRootSelector: parts[parts.length -1] || '#root'  }; }),
            };
            try { await GM_setValue(SETTINGS_KEY, JSON.stringify(newSettings)); alert('Settings Saved. The page will now reload.'); window.location.reload(); } catch (e) { logDebug(`Failed to save settings: ${e.message}`); alert(`Error: Could not save settings.`); }
        });
        document.addEventListener('ocr-log-update', () => { if (UI.debugModal && !UI.debugModal.classList.contains('is-hidden')) { UI.debugLogTextarea.value = debugLog.join('\n'); UI.debugLogTextarea.scrollTop = UI.debugLogTextarea.scrollHeight; } });
    }
    function checkServerStatus() {
        const serverUrl = UI.serverUrlInput.value.trim(); if (!serverUrl) return;
        UI.statusDiv.className = 'status-checking'; UI.statusDiv.textContent = 'Checking...';
        GM_xmlhttpRequest({
            method: 'GET', url: serverUrl, timeout: 5000,
            onload: (res) => { try { const data = JSON.parse(res.responseText); if (data.status === 'running') { UI.statusDiv.className = 'status-ok'; const jobs = data.active_preprocess_jobs ?? 'N/A'; UI.statusDiv.textContent = `Connected (Cache: ${data.items_in_cache} | Active Jobs: ${jobs})`; } else { throw new Error('Unresponsive'); } } catch (e) { UI.statusDiv.className = 'status-error'; UI.statusDiv.textContent = 'Invalid Response'; } },
            onerror: () => { UI.statusDiv.className = 'status-error'; UI.statusDiv.textContent = 'Connection Failed'; },
            ontimeout: () => { UI.statusDiv.className = 'status-error'; UI.statusDiv.textContent = 'Timed Out'; }
        });
    }
    function purgeServerCache() {
        if (!confirm("Are you sure you want to permanently delete all items from the server's OCR cache?")) return;
        const btn = UI.purgeCacheBtn; const originalText = btn.textContent; btn.disabled = true; btn.textContent = 'Purging...';
        GM_xmlhttpRequest({
            method: 'POST', url: `${settings.ocrServerUrl}/purge-cache`, timeout: 10000,
            onload: (res) => { try { const data = JSON.parse(res.responseText); alert(data.message || data.error); checkServerStatus(); } catch (e) { alert('Failed to parse server response.'); } },
            onerror: () => alert('Failed to connect to server to purge cache.'),
            ontimeout: () => alert('Request to purge cache timed out.'),
            onloadend: () => { btn.disabled = false; btn.textContent = originalText; }
        });
    }
    function createMeasurementSpan() {
        if (measurementSpan) return;
        measurementSpan = document.createElement('span');
        measurementSpan.style.cssText = `position:fixed!important;visibility:hidden!important;height:auto!important;width:auto!important;white-space:nowrap!important;z-index:-1!important;top:-9999px;left:-9999px;padding:0!important;border:0!important;margin:0!important;`;
        document.body.appendChild(measurementSpan);
    }
    // --- MODIFIED ---
    async function init() {
        const loadedSettings = await GM_getValue(SETTINGS_KEY);
        if (loadedSettings) { try { settings = { ...settings, ...JSON.parse(loadedSettings) }; } catch (e) { logDebug("Could not parse saved settings. Using defaults."); } }
        createUI();
        bindUIEvents();
        applyTheme();
        createMeasurementSpan();
        logDebug("Initializing HYBRID engine with Focus Color (BlendMode).");
        resizeObserver = new ResizeObserver(handleResize);
        intersectionObserver = new IntersectionObserver(handleIntersection, { rootMargin: '100px 0px' });
        setupMutationObservers();
        UI.serverUrlInput.value = settings.ocrServerUrl; UI.imageServerUserInput.value = settings.imageServerUser || ''; UI.imageServerPasswordInput.value = settings.imageServerPassword || ''; UI.ankiUrlInput.value = settings.ankiConnectUrl; UI.ankiFieldInput.value = settings.ankiImageField; UI.debugModeCheckbox.checked = settings.debugMode; UI.soloHoverCheckbox.checked = settings.soloHoverMode; UI.addSpaceOnMergeCheckbox.checked = settings.addSpaceOnMerge; UI.interactionModeSelect.value = settings.interactionMode; UI.textOrientationSelect.value = settings.textOrientation; UI.colorThemeSelect.value = settings.colorTheme; UI.brightnessModeSelect.value = settings.brightnessMode; UI.focusFontColorSelect.value = settings.focusFontColor; UI.deleteKeyInput.value = settings.deleteModifierKey; UI.mergeKeyInput.value = settings.mergeModifierKey; UI.dimmedOpacityInput.value = settings.dimmedOpacity * 100; UI.fontMultiplierHorizontalInput.value = settings.fontMultiplierHorizontal; UI.fontMultiplierVerticalInput.value = settings.fontMultiplierVertical; UI.boundingBoxAdjustmentInput.value = settings.boundingBoxAdjustment; UI.focusScaleMultiplierInput.value = settings.focusScaleMultiplier;
        UI.sitesConfigTextarea.value = settings.sites.map(s => [s.urlPattern, s.overflowFixSelector, ...(s.imageContainerSelectors || []), s.contentRootSelector].join('; ')).join('\n');
        reinitializeScript();
        setupNavigationObserver();
        setInterval(() => { for (const [img] of managedElements.entries()) if (!img.isConnected) { logDebug("Detected disconnected image during cleanup."); fullCleanupAndReset(); setTimeout(reinitializeScript, 250); break; } }, 5000);
        setInterval(() => { const shouldBe = window.location.href.includes('/manga/'); document.documentElement.classList.toggle('ocr-scroll-fix-active', shouldBe); }, 500);
    }
    init().catch(e => console.error(`[OCR Hybrid] Fatal Initialization Error: ${e.message}`));
})();
