// server.js - V2.1 with Persistent Caching and Import/Export
import express from 'express';
import Lens from 'chrome-lens-ocr';
import fs from 'fs';
import path from 'path';
import multer from 'multer';

const app = express();
const port = 3000;
const lens = new Lens();

// ---- NEW: Persistent Cache and File Upload Setup ----
const CACHE_FILE_PATH = path.join(process.cwd(), 'ocr-cache.json');
const upload = multer({ dest: 'uploads/' }); // Temporary folder for uploads
let ocrCache = new Map();
let ocrRequestsProcessed = 0;

/**
 * NEW: Loads the cache from the JSON file on disk.
 */
function loadCacheFromFile() {
    try {
        if (fs.existsSync(CACHE_FILE_PATH)) {
            const fileContent = fs.readFileSync(CACHE_FILE_PATH, 'utf-8');
            const data = JSON.parse(fileContent);
            ocrCache = new Map(Object.entries(data));
            console.log(`[Cache] Loaded ${ocrCache.size} items from ${CACHE_FILE_PATH}`);
        } else {
            console.log(`[Cache] No cache file found at ${CACHE_FILE_PATH}. Starting with an empty cache.`);
        }
    } catch (error) {
        console.error('[Cache] Error loading cache from file:', error);
    }
}

/**
 * NEW: Saves the in-memory cache to the JSON file on disk.
 */
function saveCacheToFile() {
    try {
        const data = Object.fromEntries(ocrCache);
        // Using null, 2 for pretty-printing the JSON file
        fs.writeFileSync(CACHE_FILE_PATH, JSON.stringify(data, null, 2));
    } catch (error) {
        console.error('[Cache] Error saving cache to file:', error);
    }
}


// Middleware to allow requests from any webpage (CORS)
app.use((req, res, next) => {
    res.header('Access-Control-Allow-Origin', '*');
    res.header('Access-Control-Allow-Headers', 'Origin, X-Requested-With, Content-Type, Accept');
    next();
});

// Status Endpoint
app.get('/', (req, res) => {
    res.json({
        status: 'running',
        message: 'Local OCR server is active.',
        requests_processed: ocrRequestsProcessed,
        items_in_cache: ocrCache.size,
    });
});

// The main OCR endpoint
app.get('/ocr', async (req, res) => {
    const imageUrl = req.query.url;

    if (!imageUrl) {
        return res.status(400).json({ error: 'Image URL is required' });
    }

    if (ocrCache.has(imageUrl)) {
        console.log(`[Cache HIT] Returning cached result for: ${imageUrl}`);
        return res.json(ocrCache.get(imageUrl));
    }

    console.log(`[Cache MISS] Processing new image: ${imageUrl}`);

    try {
        const result = await lens.scanByURL(imageUrl);
        console.log("OCR successful. Transforming and caching result.");

        ocrRequestsProcessed++;
        const transformedResult = transformOcrData(result);

        ocrCache.set(imageUrl, transformedResult);
        saveCacheToFile(); // ---- MODIFIED: Persist the cache after adding a new item ----

        res.json(transformedResult);

    } catch (error) {
        console.error('OCR failed:', error);
        res.status(500).json({ error: 'Failed to perform OCR on the server.' });
    }
});

// ---- NEW: Export Cache Endpoint ----
app.get('/export-cache', (req, res) => {
    if (fs.existsSync(CACHE_FILE_PATH)) {
        res.download(CACHE_FILE_PATH, 'ocr-cache.json', (err) => {
            if (err) {
                console.error('Error sending cache file:', err);
                res.status(500).json({ error: 'Failed to export cache.' });
            }
        });
    } else {
        res.status(404).json({ error: 'No cache file to export.' });
    }
});

// ---- NEW: Import Cache Endpoint ----
app.post('/import-cache', upload.single('cacheFile'), (req, res) => {
    if (!req.file) {
        return res.status(400).json({ error: 'No file uploaded.' });
    }

    try {
        const uploadedFilePath = req.file.path;
        const fileContent = fs.readFileSync(uploadedFilePath, 'utf-8');
        const importedData = JSON.parse(fileContent);

        let newItemsCount = 0;
        let mergedItemsCount = 0;
        const importedMap = new Map(Object.entries(importedData));

        for (const [key, value] of importedMap.entries()) {
            if (!ocrCache.has(key)) { // Only add if the key doesn't already exist
                ocrCache.set(key, value);
                newItemsCount++;
            }
            mergedItemsCount++;
        }

        if (newItemsCount > 0) {
            saveCacheToFile(); // Save the newly merged cache
        }

        // Clean up the temporary uploaded file
        fs.unlinkSync(uploadedFilePath);

        res.json({
            message: `Import successful. Scanned ${mergedItemsCount} items from the file and added ${newItemsCount} new items to the persistent cache.`,
            total_items_in_cache: ocrCache.size
        });

    } catch (error) {
        console.error('Import failed:', error);
        res.status(500).json({ error: 'Failed to import cache. Make sure the file is a valid JSON.' });
    }
});


/**
 * Transforms chrome-lens-ocr result into the format expected by the userscript.
 * (This function is unchanged)
 */
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

app.listen(port, () => {
    // ---- MODIFIED: Load the cache on server startup ----
    loadCacheFromFile();
    console.log(`Local OCR Server V2.1 listening at http://127.0.0.1:${port}`);
    console.log('Features: Persistent Caching, Import/Export, Status Endpoint');
});
