// server.js - V2.0 with Caching and Status Endpoint
import express from 'express';
import Lens from 'chrome-lens-ocr';

const app = express();
const port = 3000;
const lens = new Lens();

// ---- NEW: In-memory cache and stats ----
const ocrCache = new Map();
let ocrRequestsProcessed = 0;

// Middleware to allow requests from any webpage (CORS)
app.use((req, res, next) => {
    res.header('Access-Control-Allow-Origin', '*');
    next();
});

// ---- NEW: Status Endpoint ----
// Visit http://127.0.0.1:3000/ in your browser to see this
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

    // ---- NEW: Check the cache first ----
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

        // ---- NEW: Save the result to the cache ----
        ocrCache.set(imageUrl, transformedResult);

        res.json(transformedResult);

    } catch (error) {
        console.error('OCR failed:', error);
        res.status(500).json({ error: 'Failed to perform OCR on the server.' });
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
    console.log(`Local OCR Server V2 listening at http://127.0.0.1:${port}`);
    console.log('Features: Server-side caching, Status endpoint');
});
