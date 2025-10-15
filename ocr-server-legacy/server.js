// server.js - V4.0 with Auto-Merging, Context Logging, and Configurable Host/Port
import express from 'express';
import LensCore from 'chrome-lens-ocr/src/core.js';
import fs from 'node:fs';
import path from 'node:path';
import multer from 'multer';
import fetch from 'node-fetch';
import { program } from 'commander';

const app = express();

// --- Command-line Argument Parsing ---
program
    .option('--ip <string>', 'Specify the server IP address to bind to', '127.0.0.1')
    .option('--port <number>', 'Specify the server port to listen on', 3000)
    .option('--cache-path <string>', 'Specify a custom path for the cache file', process.cwd())
    .parse(process.argv);

const options = program.opts();
const host = options.ip;
const port = options.port;
const customCachePath = path.resolve(options.cachePath);

const lens = new LensCore();
const CACHE_FILE_PATH = path.join(customCachePath, 'ocr-cache.json');
const upload = multer({ dest: 'uploads/' });
let ocrCache = new Map();
let ocrRequestsProcessed = 0;
let activeJobCount = 0;

// --- Auto-Merge Configuration (Ported from Python Server) ---
const AUTO_MERGE_CONFIG = {
    enabled: true,
    dist_k: 1.2,
    font_ratio: 1.3,
    perp_tol: 0.5,
    overlap_min: 0.1,
    min_line_ratio: 0.5,
    font_ratio_for_mixed: 1.1,
    mixed_min_overlap_ratio: 0.5,
    add_space_on_merge: false, // Use Zero-Width-Space for line breaks
};

// --- Auto-Merge Logic (Ported from Python Server) ---

class UnionFind {
    constructor(size) {
        this.parent = Array.from({ length: size }, (_, i) => i);
        this.rank = Array(size).fill(0);
    }
    find(i) {
        if (this.parent[i] === i) return i;
        return this.parent[i] = this.find(this.parent[i]);
    }
    union(i, j) {
        const rootI = this.find(i);
        const rootJ = this.find(j);
        if (rootI !== rootJ) {
            if (this.rank[rootI] > this.rank[rootJ]) this.parent[rootJ] = rootI;
            else if (this.rank[rootI] < this.rank[rootJ]) this.parent[rootI] = rootJ;
            else { this.parent[rootJ] = rootI; this.rank[rootI]++; }
            return true;
        }
        return false;
    }
}

function median(data) {
    if (!data || data.length === 0) return 0;
    const sorted = [...data].sort((a, b) => a - b);
    const mid = Math.floor(sorted.length / 2);
    return sorted.length % 2 === 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid];
}

function autoMergeOcrData(lines, config) {
    if (!config.enabled || !lines || lines.length < 2) return lines;

    const scale = 1000;
    const processedLines = lines.map((line, i) => {
        const bbox = line.tightBoundingBox;
        const isVertical = bbox.width <= bbox.height;
        const fontSize = (isVertical ? bbox.width : bbox.height) * scale;
        return {
            ...line,
            originalIndex: i, isVertical, fontSize,
            bbox: {
                x: bbox.x * scale, y: bbox.y * scale, width: bbox.width * scale, height: bbox.height * scale,
                right: (bbox.x + bbox.width) * scale, bottom: (bbox.y + bbox.height) * scale,
            }
        };
    });

    const horizontalLines = processedLines.filter(l => !l.isVertical);
    const verticalLines = processedLines.filter(l => l.isVertical);
    const hMedianHeight = median(horizontalLines.map(l => l.fontSize)) || 20;
    const vMedianWidth = median(verticalLines.map(l => l.fontSize)) || 20;

    const uf = new UnionFind(processedLines.length);
    for (let i = 0; i < processedLines.length; i++) {
        for (let j = i + 1; j < processedLines.length; j++) {
            const lineA = processedLines[i], lineB = processedLines[j];
            if (lineA.isVertical !== lineB.isVertical) continue;
            const fontRatio = Math.max(lineA.fontSize / lineB.fontSize, lineB.fontSize / lineA.fontSize);
            if (fontRatio > config.font_ratio) continue;

            const distThreshold = lineA.isVertical ? vMedianWidth * config.dist_k : hMedianHeight * config.dist_k;
            const perpTol = lineA.isVertical ? hMedianHeight * config.perp_tol : vMedianWidth * config.perp_tol;
            let readingGap, perpOverlap, perpOffset;
            if (lineA.isVertical) {
                readingGap = Math.max(0, Math.max(lineA.bbox.x, lineB.bbox.x) - Math.min(lineA.bbox.right, lineB.bbox.right));
                perpOverlap = Math.max(0, Math.min(lineA.bbox.bottom, lineB.bbox.bottom) - Math.max(lineA.bbox.y, lineB.bbox.y));
                perpOffset = Math.abs((lineA.bbox.y + lineA.bbox.height / 2) - (lineB.bbox.y + lineB.bbox.height / 2));
            } else {
                readingGap = Math.max(0, Math.max(lineA.bbox.y, lineB.bbox.y) - Math.min(lineA.bbox.bottom, lineB.bbox.bottom));
                perpOverlap = Math.max(0, Math.min(lineA.bbox.right, lineB.bbox.right) - Math.max(lineA.bbox.x, lineB.bbox.x));
                perpOffset = Math.abs((lineA.bbox.x + lineA.bbox.width / 2) - (lineB.bbox.x + lineB.bbox.width / 2));
            }
            if (readingGap > distThreshold) continue;
            const smallerPerpSize = lineA.isVertical ? Math.min(lineA.bbox.height, lineB.bbox.height) : Math.min(lineA.bbox.width, lineB.bbox.width);
            if (perpOffset > perpTol && (smallerPerpSize === 0 || perpOverlap / smallerPerpSize < config.overlap_min)) continue;
            uf.union(i, j);
        }
    }

    const groups = {};
    for (let i = 0; i < processedLines.length; i++) {
        const root = uf.find(i);
        if (!groups[root]) groups[root] = [];
        groups[root].push(processedLines[i]);
    }

    const finalMergedData = [];
    for (const rootId in groups) {
        const group = groups[rootId];
        if (group.length === 1) {
            finalMergedData.push(lines[group[0].originalIndex]);
        } else {
            const isVertical = group[0].isVertical;
            group.sort((a, b) => isVertical ? (b.bbox.x - a.bbox.x) : (a.bbox.y - b.bbox.y));
            const joinChar = config.add_space_on_merge ? ' ' : '\u200B';
            const combinedText = group.map(l => l.text).join(joinChar);
            const bbox = group.reduce((acc, line) => ({
                minX: Math.min(acc.minX, line.bbox.x), minY: Math.min(acc.minY, line.bbox.y),
                maxX: Math.max(acc.maxX, line.bbox.right), maxY: Math.max(acc.maxY, line.bbox.bottom)
            }), { minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity });
            finalMergedData.push({
                text: combinedText, isMerged: true, forcedOrientation: isVertical ? 'vertical' : 'horizontal',
                tightBoundingBox: { x: bbox.minX / scale, y: bbox.minY / scale, width: (bbox.maxX - bbox.minX) / scale, height: (bbox.maxY - bbox.minY) / scale }
            });
        }
    }
    if (finalMergedData.length < lines.length) console.log(`[AutoMerge] Finished. Initial: ${lines.length}, Final: ${finalMergedData.length}`);
    return finalMergedData;
}

// --- Utility Functions ---

function loadCacheFromFile() {
    try {
        if (fs.existsSync(CACHE_FILE_PATH)) {
            const fileContent = fs.readFileSync(CACHE_FILE_PATH, 'utf-8');
            const data = JSON.parse(fileContent);
            ocrCache = new Map(Object.entries(data));
            console.log(`[Cache] Loaded ${ocrCache.size} items from ${CACHE_FILE_PATH}`);
        } else {
            console.log(`[Cache] No cache file found. Starting fresh at ${CACHE_FILE_PATH}`);
        }
    } catch (error) {
        console.error('[Cache] Error loading cache from file:', error);
    }
}

function saveCacheToFile() {
    try {
        const cacheDir = path.dirname(CACHE_FILE_PATH);
        if (!fs.existsSync(cacheDir)) fs.mkdirSync(cacheDir, { recursive: true });
        const data = Object.fromEntries(ocrCache);
        fs.writeFileSync(CACHE_FILE_PATH, JSON.stringify(data, null, 2));
    } catch (error) {
        console.error('[Cache] Error saving cache to file:', error);
    }
}

function transformOcrData(lensResult) {
    if (!lensResult?.segments) return [];
    return lensResult.segments.map(({ text, boundingBox }) => ({
        text: text,
        tightBoundingBox: {
            x: boundingBox.centerPerX - (boundingBox.perWidth / 2), y: boundingBox.centerPerY - (boundingBox.perHeight / 2),
            width: boundingBox.perWidth, height: boundingBox.perHeight,
        }
    }));
}

// --- Background Job for Chapter Pre-processing ---

async function runChapterProcessingJob(baseUrl, authUser, authPass, context) {
    activeJobCount++;
    console.log(`[JobRunner] [${context}] Started job for ...${baseUrl.slice(-40)}. Active jobs: ${activeJobCount}`);

    let pageIndex = 0;
    let consecutiveErrors = 0;
    const CONSECUTIVE_ERROR_THRESHOLD = 3;
    const SERVER_URL_BASE = `http://${host}:${port}`;

    while (consecutiveErrors < CONSECUTIVE_ERROR_THRESHOLD) {
        const imageUrl = `${baseUrl}${pageIndex}`;

        if (ocrCache.has(imageUrl)) {
            console.log(`[JobRunner] [${context}] Skip (in cache): ${imageUrl}`);
            pageIndex++;
            consecutiveErrors = 0;
            continue;
        }

        const encodedUrl = encodeURIComponent(imageUrl);
        const encodedContext = encodeURIComponent(context);
        let targetUrl = `${SERVER_URL_BASE}/ocr?url=${encodedUrl}&context=${encodedContext}`;
        if (authUser) targetUrl += `&user=${authUser}&pass=${authPass || ''}`;

        try {
            console.log(`[JobRunner] [${context}] Requesting: ${imageUrl}`);
            const response = await fetch(targetUrl, { timeout: 45000 });
            if (response.ok) consecutiveErrors = 0;
            else {
                consecutiveErrors++;
                console.log(`[JobRunner] [${context}] Got non-200 status (${response.status}) for ${imageUrl}. Errors: ${consecutiveErrors}`);
                if (response.status === 404) console.log("[JobRunner] (Page not found, likely end of chapter)");
            }
        } catch (e) {
            consecutiveErrors++;
            console.error(`[JobRunner] [${context}] Request failed for ${imageUrl}. Errors: ${consecutiveErrors}. Details: ${e.message}`);
        }

        pageIndex++;
        await new Promise(resolve => setTimeout(resolve, 100));
    }

    console.log(`[JobRunner] [${context}] Finished job for ...${baseUrl.slice(-40)}. Reached ${consecutiveErrors} errors.`);
    activeJobCount--;
}

// --- Middleware & Endpoints ---

app.use(express.json());
app.use((req, res, next) => {
    res.header('Access-Control-Allow-Origin', '*');
    res.header('Access-Control-Allow-Headers', 'Origin, X-Requested-With, Content-Type, Accept');
    next();
});

app.get('/', (req, res) => {
    res.json({
        status: 'running', message: 'Local OCR server is active.', requests_processed: ocrRequestsProcessed,
        items_in_cache: ocrCache.size, active_preprocess_jobs: activeJobCount, server_host: host, server_port: port
    });
});

app.get('/ocr', async (req, res) => {
    const { url: imageUrl, user: authUser, pass: authPass, context = "No Context" } = req.query;

    if (!imageUrl) return res.status(400).json({ error: 'Image URL is required' });

    if (ocrCache.has(imageUrl)) {
        const cachedEntry = ocrCache.get(imageUrl);
        // Handle both new {context, data} and old array formats
        const responseData = cachedEntry.data !== undefined ? cachedEntry.data : cachedEntry;
        console.log(`[OCR] [${cachedEntry.context || context}] Cache HIT for: ...${imageUrl.slice(-40)}`);
        return res.json(responseData);
    }

    console.log(`[OCR] [${context}] Processing new image: ...${imageUrl.slice(-40)}`);
    try {
        let ocrResult;
        if (authUser) {
            const auth = 'Basic ' + Buffer.from(authUser + ":" + (authPass || '')).toString('base64');
            const response = await fetch(imageUrl, { headers: { 'Authorization': auth } });
            if (!response.ok) throw new Error(`Failed to download image. Status: ${response.status} ${response.statusText}`);
            const imageBuffer = Buffer.from(await response.arrayBuffer());
            const mimeType = response.headers.get('content-type') || 'image/jpeg';
            const dataUrl = `data:${mimeType};base64,${imageBuffer.toString('base64')}`;
            ocrResult = await lens.scanByURL(dataUrl);
        } else {
            ocrResult = await lens.scanByURL(imageUrl);
        }

        const transformedResult = transformOcrData(ocrResult);
        const finalResult = autoMergeOcrData(transformedResult, AUTO_MERGE_CONFIG);

        ocrRequestsProcessed++;
        const cacheEntry = { context: context, data: finalResult };
        ocrCache.set(imageUrl, cacheEntry);
        saveCacheToFile();
        
        console.log(`[OCR] [${context}] Successful for ...${imageUrl.slice(-40)}.`);
        res.json(finalResult);

    } catch (error) {
        console.error(`[OCR] [${context}] Process failed for ${imageUrl}:`, error.message);
        res.status(500).json({ error: `OCR process failed: ${error.message}` });
    }
});

app.post("/preprocess-chapter", (req, res) => {
    const { baseUrl, user, pass, context = "No Context" } = req.body;
    if (!baseUrl) return res.status(400).json({ error: "baseUrl is required" });
    runChapterProcessingJob(baseUrl, user, pass, context);
    console.log(`[Queue] [${context}] Job started in background for ...${baseUrl.slice(-40)}`);
    return res.status(202).json({ status: "accepted", message: "Chapter pre-processing job has been started." });
});

app.post("/purge-cache", (req, res) => {
    const count = ocrCache.size;
    ocrCache.clear();
    saveCacheToFile();
    console.log(`[Cache] Purged. Removed ${count} items.`);
    res.json({ status: "success", message: `Cache purged. Removed ${count} items.` });
});

app.get('/export-cache', (req, res) => {
    if (fs.existsSync(CACHE_FILE_PATH)) res.download(CACHE_FILE_PATH, 'ocr-cache.json');
    else res.status(404).json({ error: 'No cache file to export.' });
});

app.post('/import-cache', upload.single('cacheFile'), (req, res) => {
    if (!req.file) return res.status(400).json({ error: 'No file uploaded.' });
    try {
        const fileContent = fs.readFileSync(req.file.path, 'utf-8');
        const importedData = JSON.parse(fileContent);
        let newItemsCount = 0;
        for (const [key, value] of Object.entries(importedData)) {
            if (!ocrCache.has(key)) {
                // Handle both old (array) and new ({context, data}) formats
                if (Array.isArray(value)) {
                    ocrCache.set(key, { context: "Imported Data", data: value });
                } else if (value && value.data) {
                    ocrCache.set(key, value);
                }
                newItemsCount++;
            }
        }
        if (newItemsCount > 0) saveCacheToFile();
        fs.unlinkSync(req.file.path);
        res.json({ message: `Import successful. Added ${newItemsCount} new items.`, total_items_in_cache: ocrCache.size });
    } catch (error) {
        if (req.file?.path) fs.unlinkSync(req.file.path);
        res.status(500).json({ error: `Failed to import cache: ${error.message}` });
    }
});

// --- Server Initialization ---

app.listen(port, host, (err) => {
    if (err) {
        console.error('Error starting server:', err);
    } else {
        loadCacheFromFile();
        console.log(`Local OCR Server V4.0 listening at http://${host}:${port}`);
        console.log(`Cache file path: ${CACHE_FILE_PATH}`);
        console.log('Features: Auto-Merging, Context Logging, Persistent Caching, Import/Export, Auth, Chapter Pre-processing');
    }
});
