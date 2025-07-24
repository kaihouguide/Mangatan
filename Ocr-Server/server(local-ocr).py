
import json
import os
import asyncio
import io
import math # Import the math library for angle calculations

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

# --- Final, Advanced Grouping and Orientation Logic ---

def transform_ocr_data(oneocr_result, image_size):
    """
    Transforms OCR data using a multi-stage process with statistical gap analysis
    to handle complex manga layouts with high accuracy.
    """
    if not oneocr_result or 'lines' not in oneocr_result:
        return []

    image_width, image_height = image_size
    if image_width == 0 or image_height == 0: return []

    # Helper function to get the center of a 4-point bounding box.
    def get_center(rect):
        return ((rect['x1'] + rect['x3']) / 2, (rect['y1'] + rect['y3']) / 2)

    # 1. Pre-process all lines into a standard format.
    lines = []
    for line in oneocr_result.get('lines', []):
        text = line.get('text', '').strip()
        rect = line.get('bounding_rect')
        if not rect or not text or not line.get('words'): continue
        
        x_coords = [rect['x1'], rect['x2'], rect['x3'], rect['x4']]
        y_coords = [rect['y1'], rect['y2'], rect['y3'], rect['y4']]
        box = {'x_min': min(x_coords), 'y_min': min(y_coords), 'x_max': max(x_coords), 'y_max': max(y_coords)}
        
        lines.append({
            'text': text, 'box': box, 'words': line['words'],
            'width': box['x_max'] - box['x_min'], 'height': box['y_max'] - box['y_min'],
        })

    if not lines: return []

    # 2. Stage 1: Group lines into distinct vertical columns.
    columns = []
    lines.sort(key=lambda l: l['box']['x_min'])
    for line in lines:
        if not columns or abs(line['box']['x_min'] - (sum(l['box']['x_min'] for l in columns[-1]) / len(columns[-1]))) > line['width'] * 1.5:
            columns.append([line])
        else:
            columns[-1].append(line)

    # 3. Stage 2: Within each column, perform statistical analysis to group into bubbles.
    final_bubbles = []
    for column in columns:
        column.sort(key=lambda l: l['box']['y_min'])
        if not column: continue

        gaps = [column[i]['box']['y_min'] - column[i-1]['box']['y_max'] for i in range(1, len(column))]
        
        break_threshold = float('inf')
        if len(gaps) > 1:
            avg_gap = sum(gaps) / len(gaps)
            std_dev = (sum([(g - avg_gap) ** 2 for g in gaps]) / len(gaps)) ** 0.5
            break_threshold = avg_gap + (std_dev * 1.2)
        elif gaps:
            break_threshold = gaps[0] * 2.0

        current_bubble = [column[0]]
        for i in range(1, len(column)):
            vertical_gap = column[i]['box']['y_min'] - column[i-1]['box']['y_max']
            if vertical_gap < break_threshold and vertical_gap < column[i-1]['height'] * 2.0:
                current_bubble.append(column[i])
            else:
                final_bubbles.append(current_bubble)
                current_bubble = [column[i]]
        final_bubbles.append(current_bubble)

    # 4. Final Formatting with True Angle Calculation and Snapping.
    output_json = []
    snap_angles = [0, 30, 45, 60, 90, 120, 135, 150, 180, -30, -45, -60, -90, -120, -135, -150, -180]

    for bubble in final_bubbles:
        if not bubble: continue
        
        all_words = [word for line in bubble for word in line['words']]
        if not all_words: continue

        all_words.sort(key=lambda w: (get_center(w['bounding_rect'])[1], get_center(w['bounding_rect'])[0]))
        
        angle = 0.0
        if len(all_words) > 1:
            start_center = get_center(all_words[0]['bounding_rect'])
            end_center = get_center(all_words[-1]['bounding_rect'])
            dx, dy = end_center[0] - start_center[0], end_center[1] - start_center[1]
            if dx != 0 or dy != 0: angle = math.degrees(math.atan2(dy, dx))
        else:
            if bubble[0]['height'] > bubble[0]['width']: angle = 90.0
        
        snapped_angle = min(snap_angles, key=lambda x: abs(x - angle))
        
        if abs(snapped_angle) > 45 and abs(snapped_angle) < 135:
            bubble.sort(key=lambda l: l['box']['y_min'])
        else:
            bubble.sort(key=lambda l: l['box']['x_min'])

        full_text = " ".join([l['text'] for l in bubble])
        
        x_min = min(l['box']['x_min'] for l in bubble)
        y_min = min(l['box']['y_min'] for l in bubble)
        x_max = max(l['box']['x_max'] for l in bubble)
        y_max = max(l['box']['y_max'] for l in bubble)
        avg_confidence = sum(line['words'][0].get('confidence', 0.98) for line in bubble) / len(bubble)

        output_json.append({
            'text': full_text,
            'tightBoundingBox': {
                'x': x_min / image_width, 'y': y_min / image_height,
                'width': (x_max - x_min) / image_width, 'height': (y_max - y_min) / image_height,
            },
            'orientation': snapped_angle,
            'fontSize': 0.04,
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
    if image_url in ocr_cache:
        print(f"[Cache HIT] for: ...{image_url[-40:]}")
        return jsonify(ocr_cache[image_url])
    print(f"[Cache MISS] for: ...{image_url[-40:]}")
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(image_url) as response:
                response.raise_for_status()
                image_bytes = await response.read()
        pil_image = Image.open(io.BytesIO(image_bytes))
        result = await asyncio.to_thread(ocr_engine.recognize_pil, pil_image)
        
        # Raw JSON saving has been removed.
        
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
