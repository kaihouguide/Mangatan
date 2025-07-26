// server.js - V2.5 with Conditional Authentication
import express from 'express';
import Lens from 'chrome-lens-ocr';
import fs from 'fs';
import path from 'path';
import multer from 'multer';
import fetch from 'node-fetch'; // Required for the auth path

const app = express();
const port = 3000;
const lens = new Lens();

const CACHE_FILE_PATH = path.join(process.cwd(), 'ocr-cache.json');
const upload = multer({ dest: 'uploads/' });
let ocrCache = new Map();
let ocrRequestsProcessed = 0;

function loadCacheFromFile() {
    try {
        if (fs.existsSync(CACHE_FILE_PATH)) {
            const fileContent = fs.readFileSync(CACHE_FILE_PATH, 'utf-8');
            const data = JSON.parse(fileContent);
            ocrCache = new Map(Object.entries(data));
            console.log(`[Cache] Loaded ${ocrCache.size} items from ${CACHE_FILE_PATH}`);
        } else {
            console.log(`[Cache] No cache file found. Starting fresh.`);
        }
    } catch (error) {
        console.error('[Cache] Error loading cache from file:', error);
    }
}

function saveCacheToFile() {
    try {
        const data = Object.fromEntries(ocrCache);
        fs.writeFileSync(CACHE_FILE_PATH, JSON.stringify(data, null, 2));
    } catch (error) {
        console.error('[Cache] Error saving cache to file:', error);
    }
}

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
    });
});

// The main OCR endpoint
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
        let ocrResult; // This will hold the result from either path

        // --- NEW: Conditional Logic ---
        if (authUser) {
            // --- AUTHENTICATION PATH ---
            console.log(`[Auth] Credentials detected for user '${authUser}'. Using manual fetch method.`);
            
            const fetchOptions = {
                headers: {
                    'Authorization': 'Basic ' + Buffer.from(authUser + ":" + authPass).toString('base64')
                }
            };

            const response = await fetch(imageUrl, fetchOptions);
            if (!response.ok) {
                throw new Error(`Failed to download image. Status: ${response.status} ${response.statusText}`);
            }

            const imageArrayBuffer = await response.arrayBuffer();
            const imageBuffer = Buffer.from(imageArrayBuffer);
            const mimeType = response.headers.get('content-type');
            
            if (!mimeType || !mimeType.startsWith('image/')) {
                throw new Error(`Invalid content type received: ${mimeType || 'None'}`);
            }
            
            const base64String = imageBuffer.toString('base64');
            const dataUrl = `data:${mimeType};base64,${base64String}`;
            
            console.log(`Image downloaded (${(imageBuffer.length / 1024).toFixed(2)} KB). Performing OCR via Data URL.`);
            ocrResult = await lens.scanByURL(dataUrl);

        } else {
            // --- ORIGINAL NON-AUTHENTICATION PATH ---
            console.log("[Auth] No credentials detected. Using direct URL method.");
            ocrResult = await lens.scanByURL(imageUrl);
        }

        // --- Common processing for both paths ---
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
        fs.unlinkSync(uploadedFilePath);
        res.json({
            message: `Import successful. Added ${newItemsCount} new items.`,
            total_items_in_cache: ocrCache.size
        });
    } catch (error) {
        res.status(500).json({ error: 'Failed to import cache.' });
    }
});

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
    loadCacheFromFile();
    console.log(`Local OCR Server V2.5 listening at http://127.0.0.1:${port}`);
    console.log('Features: Persistent Caching, Import/Export, Conditional Auth Forwarding');
});
