import json
import os
import asyncio
import io
import math
import threading
import hashlib
import argparse
import sys
import base64  # <-- ADDED: For handling Basic Authentication encoding

# --- Platform-Specific Fix for Windows ---
if sys.platform == "win32":
    from colorama import init

    init(autoreset=True)

from flask import Flask, request, jsonify, send_file
from werkzeug.utils import secure_filename
import aiohttp
from PIL import Image

# Import the OCR library and the stable production server
import oneocr
from waitress import serve

# --- NEW: Configuration for Image Slicing ---
# The height of each chunk to process.
# A value between 1000-2000 is a good starting point.
CHUNK_HEIGHT = 1500
# The pixel overlap between chunks to prevent cutting text in half.
OVERLAP = 150


# --- Engine and App Initialization ---

print("[Engine] Initializing oneocr.OcrEngine()...")
try:
    ocr_engine = oneocr.OcrEngine()
    print("[Engine] Initialization complete.")
except Exception as e:
    print(f"[Engine] CRITICAL: Failed to initialize oneocr.OcrEngine: {e}")
    exit()

app = Flask(__name__)

# --- Configuration and Global Variables ---
CACHE_FILE_PATH = os.path.join(os.getcwd(), "ocr-cache.json")
UPLOAD_FOLDER = "uploads"
IMAGE_CACHE_FOLDER = "image_cache"
app.config["UPLOAD_FOLDER"] = UPLOAD_FOLDER

os.makedirs(UPLOAD_FOLDER, exist_ok=True)
os.makedirs(IMAGE_CACHE_FOLDER, exist_ok=True)

ocr_cache = {}
ocr_requests_processed = 0
cache_lock = threading.Lock()
is_debug_mode = False

# --- Utility Functions ---


def load_cache():
    global ocr_cache
    if os.path.exists(CACHE_FILE_PATH):
        try:
            with open(CACHE_FILE_PATH, "r", encoding="utf-8") as f:
                ocr_cache = json.load(f)
            print(f"[Cache] Loaded {len(ocr_cache)} items from {CACHE_FILE_PATH}")
        except json.JSONDecodeError:
            print(f"[Cache] Warning: Could not decode JSON. Starting fresh.")
    else:
        print("[Cache] No cache file found. Starting fresh.")


def save_cache():
    if is_debug_mode:
        print(f"[DEBUG] Acquiring lock to save OCR cache...")
    with open(CACHE_FILE_PATH, "w", encoding="utf-8") as f:
        json.dump(ocr_cache, f, indent=2, ensure_ascii=False)
    if is_debug_mode:
        print(f"[DEBUG] OCR cache saved successfully.")


def transform_ocr_data(oneocr_result, image_size):
    if not oneocr_result or not oneocr_result.get("lines"):
        return []
    image_width, image_height = image_size
    if image_width == 0 or image_height == 0:
        return []
    output_json = []
    for line in oneocr_result.get("lines", []):
        text = line.get("text", "").strip()
        rect = line.get("bounding_rect")
        if not rect or not text or not line.get("words"):
            continue
        x_coords = [rect["x1"], rect["x2"], rect["x3"], rect["x4"]]
        y_coords = [rect["y1"], rect["y2"], rect["y3"], rect["y4"]]
        x_min = min(x_coords)
        y_min = min(y_coords)
        x_max = max(x_coords)
        y_max = max(y_coords)
        width = x_max - x_min
        height = y_max - y_min
        snapped_angle = 90.0 if height > width else 0.0
        word_count = len(line.get("words", []))
        avg_confidence = (
            sum(word.get("confidence", 0.95) for word in line.get("words", []))
            / word_count
            if word_count > 0
            else 0.95
        )
        output_json.append(
            {
                "text": text,
                "tightBoundingBox": {
                    "x": x_min / image_width,
                    "y": y_min / image_height,
                    "width": width / image_width,
                    "height": height / image_height,
                },
                "orientation": snapped_angle,
                "fontSize": 0.04,
                "confidence": avg_confidence,
            }
        )
    return output_json


# --- API Endpoints ---
@app.route("/")
def status_endpoint():
    if is_debug_mode:
        print(f"[DEBUG] /status endpoint hit.")
    with cache_lock:
        num_requests = ocr_requests_processed
        num_cache_items = len(ocr_cache)
    return jsonify(
        {
            "status": "running",
            "message": "Python OCR server is active.",
            "mode": "Debug" if is_debug_mode else "Production",
            "requests_processed": num_requests,
            "items_in_cache": num_cache_items,
        }
    )


@app.route("/ocr")
async def ocr_endpoint():
    global ocr_requests_processed
    image_url = request.args.get("url")
    if not image_url:
        return jsonify({"error": "Image URL is required"}), 400

    if is_debug_mode:
        print(f"[DEBUG] /ocr request for URL: {image_url}")

    with cache_lock:
        if image_url in ocr_cache:
            if is_debug_mode:
                print(f"[DEBUG] Returning cached result for URL: ...{image_url[-40:]}")
            return jsonify(ocr_cache[image_url])

    print(f"[Processing] for: ...{image_url[-40:]}")
    try:
        # --- NEW: Read credentials and prepare auth headers ---
        auth_user = request.args.get("user")
        auth_pass = request.args.get("pass")
        auth_headers = {}

        if auth_user:
            print(f"[Auth] Using credentials for user: '{auth_user}' to fetch image.")
            # Create the value for the 'Authorization: Basic ...' header
            auth_string = f"{auth_user}:{auth_pass}"
            auth_base64 = base64.b64encode(auth_string.encode("utf-8")).decode("utf-8")
            auth_headers["Authorization"] = f"Basic {auth_base64}"
        # --- END OF NEW CODE ---

        url_hash = hashlib.sha256(image_url.encode("utf-8")).hexdigest()
        local_image_path = os.path.join(IMAGE_CACHE_FOLDER, f"{url_hash}.jpg")

        # --- MODIFIED: Pass the 'auth_headers' to the get request ---
        async with aiohttp.ClientSession() as session:
            async with session.get(image_url, headers=auth_headers) as response:
                response.raise_for_status()  # This will now check for 401 errors
                image_bytes = await response.read()
        # --- END OF MODIFICATION ---

        # Disable Pillow's decompression bomb check to handle large images,
        # since we are controlling the processing flow.
        Image.MAX_IMAGE_PIXELS = None
        pil_image = Image.open(io.BytesIO(image_bytes))
        rgb_image = pil_image.convert("RGB")

        if is_debug_mode:
            print(f"[DEBUG] Image downloaded. Size: {rgb_image.size}")

        # --- SLICING AND PROCESSING LOGIC ---

        full_width, full_height = rgb_image.size
        y_offset = 0
        all_transformed_results = []

        while y_offset < full_height:
            # Define the crop box for the current chunk
            box = (0, y_offset, full_width, min(y_offset + CHUNK_HEIGHT, full_height))

            if is_debug_mode:
                print(f"[DEBUG] Processing chunk at y-offset: {y_offset}")

            # Crop the image to get the current chunk
            chunk_image = rgb_image.crop(box)
            chunk_width, chunk_height = chunk_image.size

            # Run OCR on the smaller chunk
            result = await asyncio.to_thread(ocr_engine.recognize_pil, chunk_image)
            transformed_chunk = transform_ocr_data(result, chunk_image.size)

            # Remap the coordinates of the detected text to be relative to the FULL image
            for item in transformed_chunk:
                bbox = item["tightBoundingBox"]
                # Adjust y and height based on the chunk's position and size
                bbox["y"] = (bbox["y"] * chunk_height + y_offset) / full_height
                bbox["height"] = (bbox["height"] * chunk_height) / full_height
                all_transformed_results.append(item)

            # Move to the next chunk position
            y_offset += CHUNK_HEIGHT - OVERLAP

        # --- END OF SLICING LOGIC ---

        if is_debug_mode:
            print(
                f"[DEBUG] OCR recognition finished. Found {len(all_transformed_results)} text blocks."
            )

        # The final result is the list of all text blocks from all chunks
        transformed_result = all_transformed_results

        with cache_lock:
            if is_debug_mode:
                print(f"[DEBUG] Caching transformed result for URL.")
            ocr_cache[image_url] = transformed_result
            ocr_requests_processed += 1
            save_cache()

        print(f"OCR successful for: ...{image_url[-40:]}")
        return jsonify(transformed_result)

    except aiohttp.ClientResponseError as e:
        error_message = (
            f"Failed to fetch image from URL: {image_url}, status: {e.status}"
        )
        print(f"ERROR: {error_message}")
        return jsonify({"error": error_message}), 500
    except Exception as e:
        error_message = f"An unexpected error occurred: {e}"
        print(f"ERROR on {image_url[-40:]}: {error_message}")
        if is_debug_mode:
            import traceback

            traceback.print_exc()
        return jsonify({"error": error_message}), 500


@app.route("/export-cache")
def export_cache_endpoint():
    if not os.path.exists(CACHE_FILE_PATH):
        return jsonify({"error": "No cache file to export."}), 404
    return send_file(
        CACHE_FILE_PATH, as_attachment=True, download_name="ocr-cache.json"
    )


@app.route("/import-cache", methods=["POST"])
def import_cache_endpoint():
    if "cacheFile" not in request.files:
        return jsonify({"error": "No file part."}), 400
    file = request.files["cacheFile"]
    if file.filename == "" or not file.filename.endswith(".json"):
        return jsonify({"error": "Invalid file."}), 400
    try:
        imported_data = json.load(file)
        if not isinstance(imported_data, dict):
            return jsonify({"error": "Invalid cache format."}), 400
        with cache_lock:
            new_items_count = 0
            for key, value in imported_data.items():
                if key not in ocr_cache:
                    ocr_cache[key] = value
                    new_items_count += 1
            if new_items_count > 0:
                save_cache()
            total_items = len(ocr_cache)
        return jsonify(
            {
                "message": f"Import successful. Scanned {len(imported_data)} items, added {new_items_count} new items.",
                "total_items_in_cache": total_items,
            }
        )
    except Exception as e:
        return jsonify({"error": f"Import failed: {e}"}), 500


# --- Main Execution Block ---
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run the Python OCR Server.")
    parser.add_argument(
        "-D",
        "--debug",
        action="store_true",
        help="Enable debug mode with Flask development server.",
    )
    args = parser.parse_args()
    is_debug_mode = args.debug
    load_cache()

    if is_debug_mode:
        print("--- Starting Flask Development Server in DEBUG MODE ---")
        print("WARNING: This server is for development only. Do not use in production.")
        print("Auto-reloader is disabled to prevent console errors on Windows.")
        print(f"URL: http://127.0.0.1:3000")
        app.run(host="127.0.0.1", port=3000, debug=True, use_reloader=False)
    else:
        print("--- Starting Waitress Production Server ---")
        print("Your OCR server is now running and ready for requests.")
        print(f"Main cache file: {CACHE_FILE_PATH}")
        print(f"Image cache folder: {IMAGE_CACHE_FOLDER}")
        print("URL: http://127.0.0.1:3000")
        print("Press CTRL+C to quit.")
        serve(app, host="127.0.0.1", port=3000)
