# --- START OF FILE server.py ---

# TODO: cache purge <-- DONE
# TODO: auto-merge logic <-- UPGRADED WITH ROBUST SORTING
# TODO: Add context logging <-- DONE
# TODO: Save context to cache file <-- DONE

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
from collections import defaultdict

import aiohttp
from engines import Engine, initialize_engine
from flask import Flask, jsonify, request, send_file
from PIL import Image
from waitress import serve

# region Config
IP_ADDRESS = "0.0.0.0"
PORT = 3000
CACHE_FILE_PATH = os.path.join(os.getcwd(), "ocr-cache.json")
UPLOAD_FOLDER = "uploads"
IMAGE_CACHE_FOLDER = "image_cache"
AUTO_MERGE_CONFIG = {
    "enabled": True,
    "dist_k": 1.2,
    "font_ratio": 1.3,
    "perp_tol": 0.5,
    "overlap_min": 0.1,
    "min_line_ratio": 0.5,
    "font_ratio_for_mixed": 1.1,
    "mixed_min_overlap_ratio": 0.5,
    "add_space_on_merge": False,
}
# endregion

# region Setup
app = Flask(__name__)
app.config["UPLOAD_FOLDER"] = UPLOAD_FOLDER

Image.MAX_IMAGE_PIXELS = None

is_debug_mode = False
ocr_cache = {}
ocr_requests_processed = 0
cache_lock = threading.Lock()
active_job_count = 0
active_job_lock = threading.Lock()
ocr_engine: Engine
# endregion


# region Auto-Merge Logic (Ported from UserScript)


class UnionFind:
    def __init__(self, size):
        self.parent = list(range(size))
        self.rank = [0] * size

    def find(self, i):
        if self.parent[i] == i:
            return i
        self.parent[i] = self.find(self.parent[i])
        return self.parent[i]

    def union(self, i, j):
        root_i = self.find(i)
        root_j = self.find(j)
        if root_i != root_j:
            if self.rank[root_i] > self.rank[root_j]:
                self.parent[root_j] = root_i
            elif self.rank[root_i] < self.rank[root_j]:
                self.parent[root_i] = root_j
            else:
                self.parent[root_j] = root_i
                self.rank[root_i] += 1
            return True
        return False


def _median(data):
    if not data:
        return 0
    sorted_data = sorted(data)
    mid = len(sorted_data) // 2
    if len(sorted_data) % 2 == 0:
        return (sorted_data[mid - 1] + sorted_data[mid]) / 2.0
    return sorted_data[mid]


def _group_ocr_data(lines, natural_width, natural_height, config):
    if not lines or len(lines) < 2 or not natural_width or not natural_height:
        return [[line] for line in lines]

    CHUNK_MAX_HEIGHT = 3000
    processed_lines = []
    for index, line in enumerate(lines):
        bbox = line["tightBoundingBox"]
        pixel_top = bbox["y"] * natural_height
        pixel_bottom = (bbox["y"] + bbox["height"]) * natural_height
        norm_scale = 1000 / natural_width

        normalized_bbox = {
            "x": (bbox["x"] * natural_width) * norm_scale,
            "y": (bbox["y"] * natural_height) * norm_scale,
            "width": (bbox["width"] * natural_width) * norm_scale,
            "height": (bbox["height"] * natural_height) * norm_scale,
        }
        normalized_bbox["right"] = normalized_bbox["x"] + normalized_bbox["width"]
        normalized_bbox["bottom"] = normalized_bbox["y"] + normalized_bbox["height"]

        is_vertical = normalized_bbox["width"] <= normalized_bbox["height"]
        font_size = normalized_bbox["width"] if is_vertical else normalized_bbox["height"]

        processed_lines.append({
            "original_index": index,
            "is_vertical": is_vertical,
            "font_size": font_size,
            "bbox": normalized_bbox,
            "pixel_top": pixel_top,
            "pixel_bottom": pixel_bottom,
        })

    processed_lines.sort(key=lambda p: p["pixel_top"])

    all_groups = []
    current_line_index = 0
    chunks_processed = 0

    while current_line_index < len(processed_lines):
        chunks_processed += 1
        chunk_start_index = current_line_index
        chunk_end_index = len(processed_lines) - 1

        if natural_height > CHUNK_MAX_HEIGHT:
            chunk_top_y = processed_lines[chunk_start_index]["pixel_top"]
            for i in range(chunk_start_index + 1, len(processed_lines)):
                if (processed_lines[i]["pixel_bottom"] - chunk_top_y) <= CHUNK_MAX_HEIGHT:
                    chunk_end_index = i
                else:
                    break

        chunk_lines = processed_lines[chunk_start_index : chunk_end_index + 1]
        uf = UnionFind(len(chunk_lines))

        horizontal_lines = [l for l in chunk_lines if not l["is_vertical"]]
        vertical_lines = [l for l in chunk_lines if l["is_vertical"]]

        initial_median_h = _median([l["bbox"]["height"] for l in horizontal_lines])
        initial_median_w = _median([l["bbox"]["width"] for l in vertical_lines])

        primary_h = [l for l in horizontal_lines if l["bbox"]["height"] >= initial_median_h * config["min_line_ratio"]]
        primary_v = [l for l in vertical_lines if l["bbox"]["width"] >= initial_median_w * config["min_line_ratio"]]
        
        robust_median_h = _median([l["bbox"]["height"] for l in primary_h]) or initial_median_h or 20
        robust_median_w = _median([l["bbox"]["width"] for l in primary_v]) or initial_median_w or 20

        for i in range(len(chunk_lines)):
            for j in range(i + 1, len(chunk_lines)):
                line_a, line_b = chunk_lines[i], chunk_lines[j]
                if line_a["is_vertical"] != line_b["is_vertical"]:
                    continue

                is_a_primary = line_a["font_size"] >= (robust_median_w if line_a["is_vertical"] else robust_median_h) * config["min_line_ratio"]
                is_b_primary = line_b["font_size"] >= (robust_median_w if line_b["is_vertical"] else robust_median_h) * config["min_line_ratio"]
                
                font_ratio_threshold = config["font_ratio"]
                if is_a_primary != is_b_primary:
                    font_ratio_threshold = config["font_ratio_for_mixed"]
                
                font_ratio = max(line_a["font_size"] / line_b["font_size"], line_b["font_size"] / line_a["font_size"])
                if font_ratio > font_ratio_threshold:
                    continue

                dist_threshold = (robust_median_w if line_a["is_vertical"] else robust_median_h) * config["dist_k"]
                
                if line_a["is_vertical"]:
                    reading_gap = max(0, max(line_a["bbox"]["x"], line_b["bbox"]["x"]) - min(line_a["bbox"]["right"], line_b["bbox"]["right"]))
                    perp_overlap = max(0, min(line_a["bbox"]["bottom"], line_b["bbox"]["bottom"]) - max(line_a["bbox"]["y"], line_b["bbox"]["y"]))
                else:
                    reading_gap = max(0, max(line_a["bbox"]["y"], line_b["bbox"]["y"]) - min(line_a["bbox"]["bottom"], line_b["bbox"]["bottom"]))
                    perp_overlap = max(0, min(line_a["bbox"]["right"], line_b["bbox"]["right"]) - max(line_a["bbox"]["x"], line_b["bbox"]["x"]))

                smaller_perp_size = min(line_a["bbox"]["height"] if line_a["is_vertical"] else line_a["bbox"]["width"],
                                        line_b["bbox"]["height"] if line_b["is_vertical"] else line_b["bbox"]["width"])

                if reading_gap > dist_threshold:
                    continue
                if smaller_perp_size > 0 and perp_overlap / smaller_perp_size < config["overlap_min"]:
                    continue
                if is_a_primary != is_b_primary and smaller_perp_size > 0 and (perp_overlap / smaller_perp_size < config["mixed_min_overlap_ratio"]):
                    continue
                
                uf.union(i, j)

        temp_groups = defaultdict(list)
        for i in range(len(chunk_lines)):
            root = uf.find(i)
            temp_groups[root].append(chunk_lines[i])

        chunk_final_groups = [
            [lines[p_line["original_index"]] for p_line in group]
            for group in temp_groups.values()
        ]
        all_groups.extend(chunk_final_groups)
        current_line_index = chunk_end_index + 1

    if is_debug_mode:
        print(f"[AutoMerge] Grouping finished. Initial: {len(lines)}, Final groups: {len(all_groups)} (in {chunks_processed} chunk(s))")
    return all_groups


def auto_merge_ocr_data(lines, natural_width, natural_height, config):
    groups = _group_ocr_data(lines, natural_width, natural_height, config)
    final_merged_data = []

    for group in groups:
        if len(group) == 1:
            final_merged_data.append(group[0])
            continue

        # --- ROBUST ORIENTATION DETECTION (THE FIX) ---
        # Determine group orientation by a "majority vote" of the lines inside it.
        vertical_lines_count = sum(1 for line in group if line["tightBoundingBox"]['height'] > line["tightBoundingBox"]['width'])
        horizontal_lines_count = len(group) - vertical_lines_count
        is_vertical_group = vertical_lines_count > horizontal_lines_count

        # --- STABLE SORTING LOGIC ---
        if is_vertical_group:
            # Sort by the horizontal center of the box (descending for right-to-left)
            # then by the vertical center (ascending for top-to-bottom).
            group.sort(key=lambda line: (
                -(line["tightBoundingBox"]["x"] + line["tightBoundingBox"]["width"] / 2), 
                line["tightBoundingBox"]["y"] + line["tightBoundingBox"]["height"] / 2
            ))
        else:
            # Sort by the vertical center, then by the horizontal center.
            group.sort(key=lambda line: (
                line["tightBoundingBox"]["y"] + line["tightBoundingBox"]["height"] / 2, 
                line["tightBoundingBox"]["x"] + line["tightBoundingBox"]["width"] / 2
            ))
        
        join_char = " " if config["add_space_on_merge"] else "\u200b"
        combined_text = join_char.join([line["text"] for line in group])

        # Calculate final bounding box for the merged group
        group_bboxes = [line["tightBoundingBox"] for line in group]
        min_x = min(b["x"] for b in group_bboxes)
        min_y = min(b["y"] for b in group_bboxes)
        max_r = max(b["x"] + b["width"] for b in group_bboxes)
        max_b = max(b["y"] + b["height"] for b in group_bboxes)

        final_merged_data.append({
            "text": combined_text,
            "isMerged": True,
            "forcedOrientation": "vertical" if is_vertical_group else "horizontal",
            "tightBoundingBox": {
                "x": min_x,
                "y": min_y,
                "width": max_r - min_x,
                "height": max_b - min_y,
            },
        })

    if len(final_merged_data) < len(lines):
        print(f"[AutoMerge] Finished. Initial lines: {len(lines)}, Final merged lines: {len(final_merged_data)}")

    return final_merged_data

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


def run_chapter_processing_job(base_url, auth_user, auth_pass, context):
    global active_job_count
    with active_job_lock:
        active_job_count += 1

    print(f"[JobRunner] [{context}] Started job for ...{base_url[-40:]}. Active jobs: {active_job_count}")

    page_index, consecutive_errors = 0, 0
    CONSECUTIVE_ERROR_THRESHOLD = 3
    SERVER_URL_BASE = "http://127.0.0.1:3000"

    while consecutive_errors < CONSECUTIVE_ERROR_THRESHOLD:
        image_url = f"{base_url}{page_index}"
        with cache_lock:
            if image_url in ocr_cache:
                print(f"[JobRunner] [{context}] Skip (in cache): {image_url}")
                page_index += 1
                consecutive_errors = 0
                continue

        encoded_url = quote(image_url, safe="")
        encoded_context = quote(context, safe="")
        target_url = (f"{SERVER_URL_BASE}/ocr?url={encoded_url}&context={encoded_context}")
        if auth_user:
            target_url += f"&user={auth_user}&pass={auth_pass}"

        try:
            print(f"[JobRunner] [{context}] Requesting: {image_url}")
            response = requests.get(target_url, timeout=45)
            if response.status_code == 200:
                consecutive_errors = 0
            else:
                consecutive_errors += 1
                print(f"[JobRunner] [{context}] Got non-200 status ({response.status_code}) for {image_url}. Errors: {consecutive_errors}")
                if response.status_code == 404:
                    print("[JobRunner] (Page not found, likely end of chapter)")
        except requests.exceptions.RequestException as e:
            consecutive_errors += 1
            print(f"[JobRunner] [{context}] Request failed for {image_url}. Errors: {consecutive_errors}. Details: {e}")

        page_index += 1
        time.sleep(0.1)

    print(f"[JobRunner] [{context}] Finished job for ...{base_url[-40:]}. Reached {consecutive_errors} errors.")
    with active_job_lock:
        active_job_count -= 1


# endregion

# region Endpoints


@app.route("/")
def status_endpoint():
    with cache_lock:
        num_requests, num_cache_items = ocr_requests_processed, len(ocr_cache)
    with active_job_lock:
        active_jobs = active_job_count
    return jsonify({
        "status": "running",
        "message": "Python OCR server is active.",
        "requests_processed": num_requests,
        "items_in_cache": num_cache_items,
        "active_preprocess_jobs": active_jobs,
    })


@app.route("/ocr")
async def ocr_endpoint():
    global ocr_requests_processed
    image_url = request.args.get("url")
    context = request.args.get("context", "No Context")

    if not image_url:
        return jsonify({"error": "Image URL is required"}), 400

    with cache_lock:
        if image_url in ocr_cache:
            cached_entry = ocr_cache[image_url]
            return jsonify(cached_entry.get("data", cached_entry))

    print(f"[OCR] [{context}] Processing: {image_url}")
    try:
        auth_headers = {}
        if auth_user := request.args.get("user"):
            auth_pass = request.args.get("pass", "")
            auth_base64 = base64.b64encode(f"{auth_user}:{auth_pass}".encode("utf-8")).decode("utf-8")
            auth_headers["Authorization"] = f"Basic {auth_base64}"

        async with aiohttp.ClientSession() as session:
            async with session.get(image_url, headers=auth_headers) as response:
                response.raise_for_status()
                image_bytes = await response.read()

        pil_image = Image.open(io.BytesIO(image_bytes))
        rgb_image = pil_image.convert("RGB")
        
        full_width, full_height = rgb_image.size
        all_final_results = []
        MAX_CHUNK_HEIGHT = 3000

        if full_height > MAX_CHUNK_HEIGHT:
            print(f"[OCR] [{context}] Image is tall ({full_height}px). Processing in chunks.")
            y_offset = 0
            while y_offset < full_height:
                box = (0, y_offset, full_width, min(y_offset + MAX_CHUNK_HEIGHT, full_height))
                chunk_image = rgb_image.crop(box)
                chunk_width, chunk_height = chunk_image.size
                print(f"[OCR] [{context}] Processing chunk at y={y_offset} (size: {chunk_width}x{chunk_height})")

                raw_chunk_results = await ocr_engine.ocr(chunk_image)
                
                merged_chunk_results = raw_chunk_results
                if AUTO_MERGE_CONFIG["enabled"] and raw_chunk_results:
                    merged_chunk_results = auto_merge_ocr_data(raw_chunk_results, chunk_width, chunk_height, AUTO_MERGE_CONFIG)

                for result in merged_chunk_results:
                    bbox = result['tightBoundingBox']
                    x_local_px = bbox['x'] * chunk_width
                    y_local_px = bbox['y'] * chunk_height
                    width_px = bbox['width'] * chunk_width
                    height_px = bbox['height'] * chunk_height

                    y_global_px = y_local_px + y_offset
                    result['tightBoundingBox'] = {
                        'x': x_local_px / full_width,
                        'y': y_global_px / full_height,
                        'width': width_px / full_width,
                        'height': height_px / full_height
                    }
                    all_final_results.append(result)
                
                y_offset += MAX_CHUNK_HEIGHT
        else:
            raw_results = await ocr_engine.ocr(rgb_image)
            all_final_results = raw_results
            if AUTO_MERGE_CONFIG["enabled"] and raw_results:
                all_final_results = auto_merge_ocr_data(raw_results, full_width, full_height, AUTO_MERGE_CONFIG)
        
        with cache_lock:
            ocr_cache[image_url] = {"context": context, "data": all_final_results}
            ocr_requests_processed += 1
            save_cache()

        print(f"[OCR] [{context}] Successful for: {image_url}")
        return jsonify(all_final_results)

    except aiohttp.ClientResponseError as e:
        print(f"[OCR] [{context}] ERROR fetching {image_url}: Status {e.status}")
        return jsonify({"error": f"Failed to fetch image from URL, status: {e.status}"}), e.status
    except Exception as e:
        print(f"[OCR] [{context}] ERROR on {image_url}: {e}")
        if is_debug_mode:
            traceback.print_exc()
        return jsonify({"error": f"An unexpected error occurred: {e}"}), 500


@app.route("/preprocess-chapter", methods=["POST"])
def preprocess_chapter_endpoint():
    data = request.json
    if data is None:
        return jsonify({"error": "Invalid JSON payload"}), 400

    base_url = data.get("baseUrl")
    context = data.get("context", "No Context")

    if not base_url:
        return jsonify({"error": "baseUrl is required"}), 400

    job_thread = threading.Thread(
        target=run_chapter_processing_job,
        args=(base_url, data.get("user"), data.get("pass"), context),
        daemon=True,
    )
    job_thread.start()

    print(f"[Queue] [{context}] Job started in new thread for ...{base_url[-40:]}")
    return jsonify({
        "status": "accepted",
        "message": "Chapter pre-processing job has been started.",
    }), 202


@app.route("/purge-cache", methods=["POST"])
def purge_cache_endpoint():
    with cache_lock:
        count = len(ocr_cache)
        ocr_cache.clear()
        save_cache()
        print(f"[Cache] Purged. Removed {count} items.")
    return jsonify({"status": "success", "message": f"Cache purged. Removed {count} items."})


@app.route("/export-cache")
def export_cache_endpoint():
    if not os.path.exists(CACHE_FILE_PATH):
        return jsonify({"error": "No cache file to export."}), 404
    return send_file(CACHE_FILE_PATH, as_attachment=True, download_name="ocr-cache.json")


@app.route("/import-cache", methods=["POST"])
def import_cache_endpoint():
    if "cacheFile" not in request.files:
        return jsonify({"error": "No file part."}), 400
    file = request.files["cacheFile"]
    if not (file.filename and file.filename.endswith(".json")):
        return jsonify({"error": "Invalid file."}), 400
    try:
        imported_data = json.loads(file.read().decode("utf-8"))
        if not isinstance(imported_data, dict):
            return jsonify({"error": "Invalid cache format."}), 400
        with cache_lock:
            new_items = 0
            for key, value in imported_data.items():
                if key not in ocr_cache:
                    if isinstance(value, list):
                        ocr_cache[key] = {"context": "Imported Data", "data": value}
                    elif isinstance(value, dict) and "data" in value:
                        ocr_cache[key] = value
                    else:
                        continue 
                    new_items += 1
            if new_items > 0:
                save_cache()
            total_items = len(ocr_cache)
        return jsonify({
            "message": f"Import successful. Added {new_items} new items.",
            "total_items_in_cache": total_items,
        })
    except Exception as e:
        return jsonify({"error": f"Import failed: {e}"}), 500


# endregion

# region Main


def main():
    global ocr_engine, is_debug_mode
    parser = argparse.ArgumentParser(description="Run the Python OCR Server.")
    parser.add_argument("-d", "--debug", action="store_true", help="enable debug mode")
    parser.add_argument("-e", "--engine", type=str, default="lens", help="OCR engine to use: 'lens', 'oneocr'")
    args = parser.parse_args()
    is_debug_mode = args.debug

    os.makedirs(UPLOAD_FOLDER, exist_ok=True)
    os.makedirs(IMAGE_CACHE_FOLDER, exist_ok=True)

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
