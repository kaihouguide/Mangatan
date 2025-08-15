// server.js - V3.2 with Configurable Host & Port using Commander.js
import express from 'express';
import LensCore from 'chrome-lens-ocr/src/core.js';
import fs from 'node:fs';
import path from 'node:path';
import multer from 'multer';
import fetch from 'node-fetch';
import { program } from 'commander'; // Needed AFAIK for CMD Below

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
let activeJobCount = 0; // Counter for active background jobs

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
        // Ensure the directory exists before saving the file
        const cacheDir = path.dirname(CACHE_FILE_PATH);
        if (!fs.existsSync(cacheDir)) {
            fs.mkdirSync(cacheDir, { recursive: true });
        }
        const data = Object.fromEntries(ocrCache);
        fs.writeFileSync(CACHE_FILE_PATH, JSON.stringify(data, null, 2));
    } catch (error) {
        console.error('[Cache] Error saving cache to file:', error);
    }
}

function transformOcrData(lensResult) {
    if (!lensResult || !lensResult.segments) {
        return [];
    }
    return lensResult.segments.map(segment => {
        const { text, boundingBox } = segment;
        return {
            text: text,
            tightBoundingBox: {
                x: boundingBox.centerPerX - (boundingBox.perWidth / 2),
                y: boundingBox.centerPerY - (boundingBox.perHeight / 2),
                width: boundingBox.perWidth,
                height: boundingBox.perHeight,
            },
            orientation: 'HORIZONTAL',
            fontSize: 0.04,
            confidence: 0.98
        };
    });
}

// --- Background Job for Chapter Pre-processing ---

async function runChapterProcessingJob(baseUrl, authUser, authPass) {
    activeJobCount++;
    console.log(`[JobRunner] Started job for ...${baseUrl.slice(-40)}. Active jobs: ${activeJobCount}`);

    let pageIndex = 0;
    let consecutiveErrors = 0;
    const CONSECUTIVE_ERROR_THRESHOLD = 3;
    const SERVER_URL_BASE = `http://${host}:${port}`;

    while (consecutiveErrors < CONSECUTIVE_ERROR_THRESHOLD) {
        const imageUrl = `${baseUrl}${pageIndex}`;

        if (ocrCache.has(imageUrl)) {
            console.log(`[JobRunner] Skip (in cache): ${imageUrl}`);
            pageIndex++;
            consecutiveErrors = 0;
            continue;
        }

        const encodedUrl = encodeURIComponent(imageUrl);
        let targetUrl = `${SERVER_URL_BASE}/ocr?url=${encodedUrl}`;
        if (authUser) {
            targetUrl += `&user=${authUser}&pass=${authPass || ''}`;
        }

        try {
            console.log(`[JobRunner] Requesting: ${imageUrl}`);
            const response = await fetch(targetUrl, { timeout: 45000 });

            if (response.ok) {
                consecutiveErrors = 0;
            } else {
                consecutiveErrors++;
                console.log(`[JobRunner] Got non-200 status (${response.status}) for ${imageUrl}. Errors: ${consecutiveErrors}`);
                if (response.status === 404) {
                    console.log("[JobRunner] (Page not found, likely end of chapter)");
                }
            }
        } catch (e) {
            consecutiveErrors++;
            console.error(`[JobRunner] Request failed for ${imageUrl}. Errors: ${consecutiveErrors}. Details: ${e.message}`);
        }

        pageIndex++;
        await new Promise(resolve => setTimeout(resolve, 100)); // Sleep for 100ms
    }

    console.log(`[JobRunner] Finished job for ...${baseUrl.slice(-40)}. Reached ${consecutiveErrors} errors.`);
    activeJobCount--;
}

// --- Middleware & Endpoints ---

app.use(express.json()); // Middleware to parse JSON bodies
app.use((req, res, next) => {
    res.header('Access-Control-Allow-Origin', '*');
    res.header('Access-Control-Allow-Headers', 'Origin, X-Requested-With, Content-Type, Accept');
    next();
});

app.get('/', (req, res) => {
    res.json({
        status: 'running',
        message: 'Local OCR server is active.',
        requests_processed: ocrRequestsProcessed,
        items_in_cache: ocrCache.size,
        active_preprocess_jobs: activeJobCount,
        server_host: host,
        server_port: port
    });
});

app.get('/ocr', async (req, res) => {
    const imageUrl = req.query.url;
    const authUser = req.query.user;
    const authPass = req.query.pass;

    if (!imageUrl) {
        return res.status(400).json({ error: 'Image URL is required' });
    }

    if (ocrCache.has(imageUrl)) {
        console.log(`[Cache HIT] Returning cached result for: ...${imageUrl.slice(-40)}`);
        return res.json(ocrCache.get(imageUrl));
    }

    console.log(`[Cache MISS] Processing new image: ...${imageUrl.slice(-40)}`);

    try {
        let ocrResult;
        if (authUser) {
            console.log(`[Auth] Credentials detected for user '${authUser}'. Using manual fetch method.`);
            const fetchOptions = { headers: { 'Authorization': 'Basic ' + Buffer.from(authUser + ":" + (authPass || '')).toString('base64') } };
            const response = await fetch(imageUrl, fetchOptions);
            if (!response.ok) throw new Error(`Failed to download image. Status: ${response.status} ${response.statusText}`);
            const imageArrayBuffer = await response.arrayBuffer();
            const imageBuffer = Buffer.from(imageArrayBuffer);
            const mimeType = response.headers.get('content-type');
            if (!mimeType || !mimeType.startsWith('image/')) throw new Error(`Invalid content type: ${mimeType || 'None'}`);
            const dataUrl = `data:${mimeType};base64,${imageBuffer.toString('base64')}`;
            ocrResult = await lens.scanByURL(dataUrl);
        } else {
            console.log("[Auth] No credentials detected. Using direct URL method.");
            ocrResult = await lens.scanByURL(imageUrl);
        }

        console.log(`OCR successful for ...${imageUrl.slice(-40)}. Transforming and caching result.`);
        ocrRequestsProcessed++;
        const transformedResult = transformOcrData(ocrResult);

        ocrCache.set(imageUrl, transformedResult);
        saveCacheToFile();
        res.json(transformedResult);

    } catch (error) {
        console.error(`OCR process failed for ${imageUrl}:`, error.message);
        res.status(500).json({ error: `OCR process failed: ${error.message}` });
    }
});

// Endpoint to start a chapter pre-processing job
app.post("/preprocess-chapter", (req, res) => {
    const { baseUrl, user, pass } = req.body;
    if (!baseUrl) {
        return res.status(400).json({ error: "baseUrl is required" });
    }

    runChapterProcessingJob(baseUrl, user, pass);

    console.log(`[Queue] Job started in background for ...${baseUrl.slice(-40)}`);
    return res.status(202).json({ status: "accepted", message: "Chapter pre-processing job has been started." });
});

// Endpoint to purge the cache
app.post("/purge-cache", (req, res) => {
    const count = ocrCache.size;
    ocrCache.clear();
    saveCacheToFile(); // Persist the empty cache
    console.log(`[Cache] Purged. Removed ${count} items.`);
    res.json({ status: "success", message: `Cache purged. Removed ${count} items.` });
});

app.get('/export-cache', (req, res) => {
    if (fs.existsSync(CACHE_FILE_PATH)) {
        res.download(CACHE_FILE_PATH, 'ocr-cache.json');
    } else {
        res.status(404).json({ error: 'No cache file to export.' });
    }
});

app.post('/import-cache', upload.single('cacheFile'), (req, res) => {
    if (!req.file) {
        return res.status(400).json({ error: 'No file uploaded.' });
    }
    try {
        const uploadedFilePath = req.file.path;
        const fileContent = fs.readFileSync(uploadedFilePath, 'utf-8');
        const importedData = JSON.parse(fileContent);
        let newItemsCount = 0;
        const importedMap = new Map(Object.entries(importedData));
        for (const [key, value] of importedMap.entries()) {
            if (!ocrCache.has(key)) {
                ocrCache.set(key, value);
                newItemsCount++;
            }
        }
        if (newItemsCount > 0) {
            saveCacheToFile();
        }
        fs.unlinkSync(uploadedFilePath); // Clean up uploaded file
        res.json({
            message: `Import successful. Added ${newItemsCount} new items.`,
            total_items_in_cache: ocrCache.size
        });
    } catch (error) {
        if (req.file && fs.existsSync(req.file.path)) {
            fs.unlinkSync(req.file.path);
        }
        res.status(500).json({ error: `Failed to import cache: ${error.message}` });
    }
});

// --- Server Initialization ---

app.listen(port, host, (err) => {
    if (err) {
        console.error('An error has occurred while booting up the server.');
        console.error(err);
    } else {
        loadCacheFromFile();
        console.log(`Local OCR Server V3.2 listening at http://${host}:${port}`);
        console.log(`Cache file path: ${CACHE_FILE_PATH}`);
        console.log('Features: Persistent Caching, Import/Export, Conditional Auth, Chapter Pre-processing');
    }
});