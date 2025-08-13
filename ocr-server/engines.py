from abc import ABC, abstractmethod
from math import pi
from typing import TypedDict
from platform import system

import chrome_lens_py
from chrome_lens_py.utils.lens_betterproto import LensOverlayObjectsResponse
from PIL.Image import Image

if system() == "Windows":
    try:
        import oneocr

        ONEOCR_AVAILABLE = True
    except ImportError as e:
        print(f"[Warning] OneOCR import failed: {e}")
        ONEOCR_AVAILABLE = False
    except Exception as e:
        print(f"[Warning] If you get this error please spam the Mangatan thread: {e}")
        ONEOCR_AVAILABLE = False
else:
    print(f"[Warning] OneOCR is not available on platform: {system()}")
    ONEOCR_AVAILABLE = False


class BoundingBox(TypedDict):
    x: float
    y: float
    width: float
    height: float


class Bubble(TypedDict):
    text: str
    tightBoundingBox: BoundingBox
    orientation: float
    font_size: float
    confidence: float


class Engine(ABC):
    """Base class for OCR engines. Each engine should implement the `ocr` method
    which processes an image and returns a list of Bubble objects.
    """

    @abstractmethod
    async def ocr(self, img: Image) -> list[Bubble]:
        pass


class OneOCR(Engine):
    def __init__(self):
        self.engine = oneocr.OcrEngine()  # pyright: ignore[reportPossiblyUnboundVariable]
        # The height of each chunk to process.
        # A value between 1000-2000 is a good starting point.
        self.CHUNK_HEIGHT = 1500
        # The pixel overlap between chunks to prevent cutting text in half.
        self.OVERLAP = 150

    async def ocr(self, img):
        chunk_image = self.process_image(img)
        return chunk_image

    def process_image(self, img: Image) -> list[Bubble]:
        full_width, full_height = img.size
        y_offset = 0
        all_transformed_results: list[Bubble] = []

        while y_offset < full_height:
            # Define the crop box for the current chunk
            box = (
                0,
                y_offset,
                full_width,
                min(y_offset + self.CHUNK_HEIGHT, full_height),
            )

            # Crop the image to get the current chunk
            chunk_image = img.crop(box)
            chunk_width, chunk_height = chunk_image.size

            # Run OCR on the smaller chunk
            results = self.engine.recognize_pil(chunk_image)
            data = self.transform(results, chunk_image.size)

            # Remap the coordinates of the detected text to be relative to the FULL image
            for item in data:
                bbox = item["tightBoundingBox"]
                # Adjust y and height based on the chunk's position and size
                bbox["y"] = (bbox["y"] * chunk_height + y_offset) / full_height
                bbox["height"] = (bbox["height"] * chunk_height) / full_height
                all_transformed_results.append(item)

            # Move to the next chunk position
            y_offset += self.CHUNK_HEIGHT - self.OVERLAP
        return all_transformed_results

    def transform(self, result, image_size) -> list[Bubble]:
        if not result or not result.get("lines"):
            return []

        image_width, image_height = image_size
        if image_width == 0 or image_height == 0:
            return []

        output_json = []

        for line in result.get("lines", []):
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

            bubble = Bubble(
                text=text,
                tightBoundingBox=BoundingBox(
                    x=x_min / image_width,
                    y=y_min / image_height,
                    width=width / image_width,
                    height=height / image_height,
                ),
                orientation=snapped_angle,
                font_size=0.04,
                confidence=avg_confidence,
            )
            output_json.append(bubble)

        return output_json


class GoogleLens(Engine):
    def __init__(self):
        self.engine = chrome_lens_py.LensAPI()

    async def ocr(self, img):
        result = await self.engine.process_image(
            image_path=img, ocr_language="ja", output_format="lines"
        )
        return self.transform(result)

    def transform(self, result: dict) -> list[Bubble]:
        if not result.get("word_data"):
            return []

        output_json: list[Bubble] = []
        lines: list[dict] = result["line_blocks"]

        for line in lines:
            text: str = line["text"]
            geometry: dict[str, float] = line["geometry"]
            center_x = geometry["center_x"]
            center_y = geometry["center_y"]
            width = geometry["width"]
            height = geometry["height"]
            angle_deg = geometry["angle_deg"]

            bubble = Bubble(
                text=text.replace("･･･", "…"),
                tightBoundingBox=BoundingBox(
                    x=center_x - width / 2,
                    y=center_y - height / 2,
                    width=width,
                    height=height,
                ),
                orientation=round(angle_deg, 1),
                font_size=0.04,
                confidence=0.98,  # Assuming a default confidence value
            )
            output_json.append(bubble)

        return output_json

    # just in case we want to parse it ourselves
    def raw_transform(self, result: dict) -> list[Bubble]:
        output_json: list[Bubble] = []
        response: LensOverlayObjectsResponse = result["raw_response_objects"]

        for paragraph in response.text.text_layout.paragraphs:
            for line in paragraph.lines:
                line_text = (
                    "".join(
                        word.plain_text + (word.text_separator or "")
                        for word in line.words
                    )
                    .strip()
                    .replace("･･･", "…")
                )
                geometry = line.geometry

                bounding_box = geometry.bounding_box
                center_x = bounding_box.center_x
                center_y = bounding_box.center_y
                width = bounding_box.width
                height = bounding_box.height
                rotation_z = bounding_box.rotation_z

                bubble = Bubble(
                    text=line_text,
                    tightBoundingBox=BoundingBox(
                        x=center_x - width / 2,
                        y=center_y - height / 2,
                        width=width,
                        height=height,
                    ),
                    orientation=round(rotation_z * (180 / pi), 1),
                    font_size=0.04,
                    confidence=0.98,
                )
                output_json.append(bubble)

        return output_json


# TODO: get a mac
class AppleVision(Engine):
    def __init__(self):
        print("AppleVision is not implemented yet")
        self.engine = object()

    async def ocr(self, img: Image) -> list[Bubble]:
        print("AppleVision is not implemented yet")
        return []


def initialize_engine(engine_name: str) -> Engine:
    engine_name = engine_name.strip().lower()
    if engine_name == "lens":
        return GoogleLens()
    elif engine_name == "oneocr":
        if ONEOCR_AVAILABLE:
            return OneOCR()
        else:
            raise RuntimeError("OneOCR is not available.")
    else:
        raise ValueError(f"Invalid engine: {engine_name}")
