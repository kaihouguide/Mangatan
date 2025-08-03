from abc import ABC, abstractmethod
from typing import Any, TypedDict
from math import pi

import chrome_lens_py
import oneocr
from chrome_lens_py.utils.lens_betterproto import LensOverlayObjectsResponse
from PIL.Image import Image


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
    @abstractmethod
    async def ocr(self, img: Image) -> list[Bubble]:
        pass


class OneOCR(Engine):
    def __init__(self):
        self.engine = oneocr.OcrEngine()

    async def ocr(self, img):
        result = self.engine.recognize_pil(img)
        return self.transform(result, img.size)

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
        result = await self.engine.process_image(image_path=img, ocr_language="ja")
        return self.transform(result)

    # TODO: Refactor when chrome_lens_py supports lines output_format
    def transform(self, result: dict[str, Any]) -> list[Bubble]:
        if result["ocr_text"] == "":
            return []

        output_json: list[Bubble] = []
        response: LensOverlayObjectsResponse = result["raw_response_objects"]

        # The library has parsed fields for us, but we'll have to manually parse
        # the raw response for individual line geometry
        for paragraph in response.text.text_layout.paragraphs:
            for line in paragraph.lines:
                line_text = "".join(
                    word.plain_text + (word.text_separator or "") for word in line.words
                ).strip()
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
