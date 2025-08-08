# TODO: cache purge

import argparse
import base64  # <-- ADDED: For handling Basic Authentication encoding
import io
import json
import os
import threading
import traceback

import aiohttp
from engines import Engine, initialize_engine
from flask import Flask, jsonify, request, send_file
from PIL import Image
from waitress import serve

# region Config

CACHE_FILE_PATH = os.path.join(os.getcwd(), "ocr-cache.json")
UPLOAD_FOLDER = "uploads"
IMAGE_CACHE_FOLDER = "image_cache"

app = Flask(__name__)
app.config["UPLOAD_FOLDER"] = UPLOAD_FOLDER

os.makedirs(UPLOAD_FOLDER, exist_ok=True)
os.makedirs(IMAGE_CACHE_FOLDER, exist_ok=True)

# Disable Pillow's decompression bomb check to handle large images,
# since we are controlling the processing flow.
Image.MAX_IMAGE_PIXELS = None

ocr_cache = {}
ocr_requests_processed = 0
cache_lock = threading.Lock()
is_debug_mode = False
ocr_engine: Engine

# endregion


# region Utility


def load_cache():
    global ocr_cache
    if os.path.exists(CACHE_FILE_PATH):
        try:
            with open(CACHE_FILE_PATH, "r", encoding="utf-8") as f:
                ocr_cache = json.load(f)
            print(f"[Cache] Loaded {len(ocr_cache)} items from {CACHE_FILE_PATH}")
        except json.JSONDecodeError:
            print("[Cache] Warning: Could not decode JSON. Starting fresh.")
    else:
        print("[Cache] No cache file found. Starting fresh.")


def save_cache():
    if is_debug_mode:
        print("[DEBUG] Acquiring lock to save OCR cache...")
    with open(CACHE_FILE_PATH, "w", encoding="utf-8") as f:
        json.dump(ocr_cache, f, indent=2, ensure_ascii=False)
    if is_debug_mode:
        print("[DEBUG] OCR cache saved successfully.")


# endregion

# region Endpoints


@app.route("/")
def status_endpoint():
    if is_debug_mode:
        print("[DEBUG] /status endpoint hit.")
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
        auth_user = request.args.get("user")
        auth_pass = request.args.get("pass")
        auth_headers = {}

        if auth_user:
            print(f"[Auth] Using credentials for user: '{auth_user}' to fetch image.")
            # Create the value for the 'Authorization: Basic ...' header
            auth_string = f"{auth_user}:{auth_pass}"
            auth_base64 = base64.b64encode(auth_string.encode("utf-8")).decode("utf-8")
            auth_headers["Authorization"] = f"Basic {auth_base64}"

        async with aiohttp.ClientSession() as session:
            async with session.get(image_url, headers=auth_headers) as response:
                response.raise_for_status()  # This will now check for 401 errors
                image_bytes = await response.read()

        pil_image = Image.open(io.BytesIO(image_bytes))
        rgb_image = pil_image.convert("RGB")

        if is_debug_mode:
            print(f"[DEBUG] Image downloaded. Size: {rgb_image.size}")

        results = await ocr_engine.ocr(rgb_image)

        if is_debug_mode:
            print(
                f"[DEBUG] OCR recognition finished. Found {len(results)} text blocks."
            )

        with cache_lock:
            if is_debug_mode:
                print("[DEBUG] Caching transformed result for URL.")
            ocr_cache[image_url] = results
            ocr_requests_processed += 1
            save_cache()

        print(f"OCR successful for: ...{image_url[-40:]}")
        return jsonify(results)

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
    filename = file.filename
    if filename == "" or (filename is not None and filename.endswith(".json") is False):
        return jsonify({"error": "Invalid file."}), 400
    try:
        imported_data = json.loads(file.read().decode("utf-8"))
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


# endregion

# region Main


def main():
    global ocr_engine
    global is_debug_mode

    parser = argparse.ArgumentParser(description="Run the Python OCR Server.")
    parser.add_argument(
        "-d",
        "--debug",
        action="store_true",
        help="enable debug mode with Flask development server",
    )
    parser.add_argument(
        "-e",
        "--engine",
        type=str,
        default="lens",
        help="OCR engine to use. Default is lens. Available: 'lens', 'oneocr'",
    )
    args = parser.parse_args()
    is_debug_mode = args.debug

    print(f"[Engine] Initializing {args.engine}...")
    try:
        ocr_engine = initialize_engine(args.engine)
        print(f"[Engine] {args.engine} initialization complete.")
    except Exception as e:
        print(f"[Engine] Failed to initialize {args.engine}: {e}")
        raise SystemExit(1)

    load_cache()

    if is_debug_mode:
        print("--- Starting Flask Development Server in DEBUG MODE ---")
        print("WARNING: This server is for development only. Do not use in production.")
        print("Auto-reloader is disabled to prevent console errors on Windows.")
        print("URL: http://127.0.0.1:3000")
        app.run(host="127.0.0.1", port=3000, debug=True, use_reloader=False)
    else:
        print("--- Starting Waitress Production Server ---")
        print("Your OCR server is now running and ready for requests.")
        print(f"Main cache file: {CACHE_FILE_PATH}")
        print(f"Image cache folder: {IMAGE_CACHE_FOLDER}")
        print("URL: http://127.0.0.1:3000")
        print("Press CTRL+C to quit.")
        serve(app, host="127.0.0.1", port=3000)


if __name__ == "__main__":
    main()

# endregion
