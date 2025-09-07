# TODO: cache purge <-- DONE

import argparse
import base64
import io
import json
import os
import threading
import traceback
import time
import requests
from urllib.parse import quote

import aiohttp
from engines import Engine, initialize_engine
from flask import Flask, jsonify, request, send_file
from PIL import Image
from waitress import serve

# region Config

IP_ADDRESS = "127.0.0.1"
PORT = 3000

CACHE_FILE_PATH = os.path.join(os.getcwd(), "ocr-cache.json")
UPLOAD_FOLDER = "uploads"
IMAGE_CACHE_FOLDER = "image_cache"

app = Flask(__name__)
app.config["UPLOAD_FOLDER"] = UPLOAD_FOLDER

os.makedirs(UPLOAD_FOLDER, exist_ok=True)
os.makedirs(IMAGE_CACHE_FOLDER, exist_ok=True)

Image.MAX_IMAGE_PIXELS = None

ocr_cache = {}
ocr_requests_processed = 0
cache_lock = threading.Lock()

# --- CORRECTED: Use a simple global integer for the shared counter ---
ACTIVE_JOB_COUNT = 0
active_job_lock = threading.Lock()

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
        print("[DEBUG] Saving OCR cache...")
    with open(CACHE_FILE_PATH, "w", encoding="utf-8") as f:
        json.dump(ocr_cache, f, indent=2, ensure_ascii=False)
    if is_debug_mode:
        print("[DEBUG] OCR cache saved successfully.")


# endregion

# region Background Job


def run_chapter_processing_job(base_url, auth_user, auth_pass):
    """
    This function runs in a separate thread and uses the shared global counter.
    """
    global ACTIVE_JOB_COUNT
    with active_job_lock:
        ACTIVE_JOB_COUNT += 1

    print(
        f"[JobRunner] Started job for ...{base_url[-40:]}. Active jobs: {ACTIVE_JOB_COUNT}"
    )

    page_index = 0
    consecutive_errors = 0
    CONSECUTIVE_ERROR_THRESHOLD = 3
    SERVER_URL_BASE = "http://127.0.0.1:3000"

    while consecutive_errors < CONSECUTIVE_ERROR_THRESHOLD:
        image_url = f"{base_url}{page_index}"

        with cache_lock:
            if image_url in ocr_cache:
                print(f"[JobRunner] Skip (in cache): {image_url}")
                page_index += 1
                consecutive_errors = 0
                continue

        encoded_url = quote(image_url, safe="")
        target_url = f"{SERVER_URL_BASE}/ocr?url={encoded_url}"
        if auth_user:
            target_url += f"&user={auth_user}&pass={auth_pass}"

        try:
            print(f"[JobRunner] Requesting: {image_url}")
            response = requests.get(target_url, timeout=45)

            if response.status_code == 200:
                consecutive_errors = 0
            else:
                consecutive_errors += 1
                print(
                    f"[JobRunner] Got non-200 status ({response.status_code}) for {image_url}. Errors: {consecutive_errors}"
                )
                if response.status_code == 404:
                    print("[JobRunner] (Page not found, likely end of chapter)")

        except requests.exceptions.RequestException as e:
            consecutive_errors += 1
            print(
                f"[JobRunner] Request failed for {image_url}. Errors: {consecutive_errors}. Details: {e}"
            )

        page_index += 1
        time.sleep(0.1)

    print(
        f"[JobRunner] Finished job for ...{base_url[-40:]}. Reached {consecutive_errors} errors."
    )
    with active_job_lock:
        ACTIVE_JOB_COUNT -= 1


# endregion


# region Endpoints


@app.route("/")
def status_endpoint():
    with cache_lock:
        num_requests = ocr_requests_processed
        num_cache_items = len(ocr_cache)
    with active_job_lock:
        active_jobs = ACTIVE_JOB_COUNT
    return jsonify(
        {
            "status": "running",
            "message": "Python OCR server is active.",
            "requests_processed": num_requests,
            "items_in_cache": num_cache_items,
            "active_preprocess_jobs": active_jobs,
        }
    )


@app.route("/ocr")
async def ocr_endpoint():
    global ocr_requests_processed
    image_url = request.args.get("url")
    if not image_url:
        return jsonify({"error": "Image URL is required"}), 400

    with cache_lock:
        if image_url in ocr_cache:
            return jsonify(ocr_cache[image_url])

    print(f"[OCR] Processing: {image_url}")
    try:
        auth_headers = {}
        if auth_user := request.args.get("user"):
            auth_pass = request.args.get("pass", "")
            auth_string = f"{auth_user}:{auth_pass}"
            auth_base64 = base64.b64encode(auth_string.encode("utf-8")).decode("utf-8")
            auth_headers["Authorization"] = f"Basic {auth_base64}"

        async with aiohttp.ClientSession() as session:
            async with session.get(image_url, headers=auth_headers) as response:
                response.raise_for_status()
                image_bytes = await response.read()

        pil_image = Image.open(io.BytesIO(image_bytes))
        rgb_image = pil_image.convert("RGB")

        results = await ocr_engine.ocr(rgb_image)

        with cache_lock:
            ocr_cache[image_url] = results
            ocr_requests_processed += 1
            save_cache()

        print(f"[OCR] Successful for: {image_url}")
        return jsonify(results)

    except aiohttp.ClientResponseError as e:
        print(f"[OCR] ERROR fetching {image_url}: Status {e.status}")
        return jsonify(
            {"error": f"Failed to fetch image from URL, status: {e.status}"}
        ), e.status
    except Exception as e:
        print(f"[OCR] ERROR on {image_url}: {e}")
        if is_debug_mode:
            traceback.print_exc()
        return jsonify({"error": f"An unexpected error occurred: {e}"}), 500


@app.route("/preprocess-chapter", methods=["POST"])
def preprocess_chapter_endpoint():
    data = request.json

    if data is None:
        return jsonify({"error": "Invalid JSON payload"}), 400

    base_url = data.get("baseUrl")
    if not base_url:
        return jsonify({"error": "baseUrl is required"}), 400

    job_thread = threading.Thread(
        target=run_chapter_processing_job,
        args=(base_url, data.get("user"), data.get("pass")),
        daemon=True,
    )
    job_thread.start()

    print(f"[Queue] Job started in new thread for ...{base_url[-40:]}")
    return jsonify(
        {
            "status": "accepted",
            "message": "Chapter pre-processing job has been started.",
        }
    ), 202


@app.route("/purge-cache", methods=["POST"])
def purge_cache_endpoint():
    with cache_lock:
        count = len(ocr_cache)
        ocr_cache.clear()
        save_cache()
        print(f"[Cache] Purged. Removed {count} items.")
    return jsonify(
        {"status": "success", "message": f"Cache purged. Removed {count} items."}
    )


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
    if not (file.filename and file.filename.endswith(".json")):
        return jsonify({"error": "Invalid file."}), 400
    try:
        # read() method exists but might not get recognized by Pylance
        imported_data = json.loads(file.read().decode("utf-8"))

        if not isinstance(imported_data, dict):
            return jsonify({"error": "Invalid cache format."}), 400
        with cache_lock:
            new_items = 0
            for key, value in imported_data.items():
                if key not in ocr_cache:
                    ocr_cache[key] = value
                    new_items += 1
            if new_items > 0:
                save_cache()
            total_items = len(ocr_cache)
        return jsonify(
            {
                "message": f"Import successful. Added {new_items} new items.",
                "total_items_in_cache": total_items,
            }
        )
    except Exception as e:
        return jsonify({"error": f"Import failed: {e}"}), 500


# endregion

# region Main


def main():
    global ocr_engine, is_debug_mode
    parser = argparse.ArgumentParser(description="Run the Python OCR Server.")
    parser.add_argument(
        "-d",
        "--debug",
        action="store_true",
        help="enable debug mode for more verbose output",
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
        app.run(host=IP_ADDRESS, port=PORT, debug=True, use_reloader=False)
    else:
        print("--- Starting Waitress Production Server ---")
        print(f"URL: http://{IP_ADDRESS}:{PORT}")
        serve(app, host=IP_ADDRESS, port=PORT)


if __name__ == "__main__":
    main()

# endregion
