import json
import os
import asyncio
import io
import math

from flask import Flask, request, jsonify, send_file
from werkzeug.utils import secure_filename
import aiohttp
from PIL import Image

# Import the OCR library and the stable production server
import oneocr
from waitress import serve

# --- Engine and App Initialization ---

print("[Engine] Initializing oneocr.OcrEngine()...")
try:
    ocr_engine = oneocr.OcrEngine()
    print("[Engine] Initialization complete.")
except Exception as e:
    print(f"[Engine] CRITICAL: Failed to initialize oneocr.OcrEngine: {e}")
    exit()

app = Flask(__name__)

# --- Cache and Configuration ---
CACHE_FILE_PATH = os.path.join(os.getcwd(), 'ocr-cache.json')
UPLOAD_FOLDER = 'uploads'
app.config['UPLOAD_FOLDER'] = UPLOAD_FOLDER

ocr_cache = {}
ocr_requests_processed = 0

# --- Utility Functions ---

def load_cache():
    global ocr_cache
    if os.path.exists(CACHE_FILE_PATH):
        try:
            with open(CACHE_FILE_PATH, 'r', encoding='utf-8') as f:
                ocr_cache = json.load(f)
            print(f"[Cache] Loaded {len(ocr_cache)} items from {CACHE_FILE_PATH}")
        except json.JSONDecodeError:
            print(f"[Cache] Warning: Could not decode JSON. Starting fresh.")
    else:
        print("[Cache] No cache file found. Starting fresh.")

def save_cache():
    with open(CACHE_FILE_PATH, 'w', encoding='utf-8') as f:
        json.dump(ocr_cache, f, indent=2, ensure_ascii=False)

# --- NEW: Simplified Transformation without Grouping ---

def transform_ocr_data(oneocr_result, image_size):
    """
    Transforms OCR data by treating every detected line as a separate text block.
    All grouping logic has been removed for maximum reliability.
    """
    if not oneocr_result or not oneocr_result.get('lines'):
        return []

    image_width, image_height = image_size
    if image_width == 0 or image_height == 0:
        return []

    output_json = []
    
    # Process each line from the OCR result independently.
    for line in oneocr_result.get('lines', []):
        text = line.get('text', '').strip()
        rect = line.get('bounding_rect')
        
        if not rect or not text or not line.get('words'):
            continue

        x_coords = [rect['x1'], rect['x2'], rect['x3'], rect['x4']]
        y_coords = [rect['y1'], rect['y2'], rect['y3'], rect['y4']]
        
        x_min = min(x_coords)
        y_min = min(y_coords)
        x_max = max(x_coords)
        y_max = max(y_coords)

        width = x_max - x_min
        height = y_max - y_min

        # Determine orientation based on the line's aspect ratio.
        snapped_angle = 90.0 if height > width else 0.0

        # Calculate average confidence for the line.
        word_count = len(line.get('words', []))
        avg_confidence = sum(word.get('confidence', 0.95) for word in line.get('words', [])) / word_count if word_count > 0 else 0.95

        output_json.append({
            'text': text,
            'tightBoundingBox': {
                'x': x_min / image_width, 'y': y_min / image_height,
                'width': width / image_width, 'height': height / image_height,
            },
            'orientation': snapped_angle,
            'fontSize': 0.04,  # Placeholder value
            'confidence': avg_confidence
        })

    return output_json


# --- API Endpoints ---
@app.route('/')
def status_endpoint():
    return jsonify({
        'status': 'running', 'message': 'Python OCR server with Waitress is active.',
        'requests_processed': ocr_requests_processed, 'items_in_cache': len(ocr_cache),
    })

@app.route('/ocr')
async def ocr_endpoint():
    global ocr_requests_processed
    image_url = request.args.get('url')
    if not image_url: return jsonify({'error': 'Image URL is required'}), 400
    
    # Always re-process to ensure no old, grouped results are served.
    if image_url in ocr_cache:
        del ocr_cache[image_url]
        print(f"[Cache PURGED] for: ...{image_url[-40:]}")
        
    print(f"[Processing] for: ...{image_url[-40:]}")
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(image_url) as response:
                response.raise_for_status()
                image_bytes = await response.read()
        pil_image = Image.open(io.BytesIO(image_bytes))
        result = await asyncio.to_thread(ocr_engine.recognize_pil, pil_image)
        
        # Use the new, simplified transformation logic.
        transformed_result = transform_ocr_data(result, pil_image.size)
        
        ocr_cache[image_url] = transformed_result
        save_cache()
        ocr_requests_processed += 1
        print(f"OCR successful for: ...{image_url[-40:]}")
        return jsonify(transformed_result)
    except Exception as e:
        error_message = f"An unexpected error occurred: {e}"
        print(f"ERROR on {image_url[-40:]}: {error_message}")
        return jsonify({'error': error_message}), 500

@app.route('/export-cache')
def export_cache_endpoint():
    if not os.path.exists(CACHE_FILE_PATH):
        return jsonify({'error': 'No cache file to export.'}), 404
    return send_file(CACHE_FILE_PATH, as_attachment=True, download_name='ocr-cache.json')

@app.route('/import-cache', methods=['POST'])
def import_cache_endpoint():
    if 'cacheFile' not in request.files: return jsonify({'error': 'No file part.'}), 400
    file = request.files['cacheFile']
    if file.filename == '' or not file.filename.endswith('.json'): return jsonify({'error': 'Invalid file.'}), 400
    try:
        imported_data = json.load(file)
        if not isinstance(imported_data, dict): return jsonify({'error': 'Invalid cache format.'}), 400
        new_items_count = 0
        for key, value in imported_data.items():
            if key not in ocr_cache:
                ocr_cache[key] = value
                new_items_count += 1
        if new_items_count > 0: save_cache()
        return jsonify({
            'message': f"Import successful. Scanned {len(imported_data)} items, added {new_items_count} new items.",
            'total_items_in_cache': len(ocr_cache)
        })
    except Exception as e: return jsonify({'error': f'Import failed: {e}'}), 500

# --- Main Execution Block ---
if __name__ == '__main__':
    load_cache()
    print("--- Starting Waitress Server ---")
    print("Your OCR server is now running and ready for requests.")
    print(f"Main cache file: {CACHE_FILE_PATH}")
    print("URL: http://127.0.0.1:3000")
    print("Press CTRL+C to quit.")
    serve(app, host='127.0.0.1', port=3000)
