from abc import ABC, abstractmethod
from typing import TypedDict, Any

import chrome_lens_py
import oneocr
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
        result = await self.engine.process_image(img, "ja")
        return self.transform(result)

    def transform(self, result: dict[str, Any]) -> list[Bubble]:
        if result["ocr_text"] == "":
            return []

        output_json = []
        word_data = result["word_data"]

        for data in word_data:
            word: str = data["word"]
            # separator: str = data["separator"]
            geometry: dict[str, Any] = data["geometry"]
            center_x: float = geometry["center_x"]
            center_y: float = geometry["center_y"]
            width: float = geometry["width"]
            height: float = geometry["height"]
            angle_deg: float = geometry["angle_deg"]
            # coordinate_type: str = geometry["coordinate_type"]

            bubble = Bubble(
                text=word,
                tightBoundingBox=BoundingBox(
                    x=center_x - width / 2,
                    y=center_y - height / 2,
                    width=width,
                    height=height,
                ),
                orientation=round(angle_deg, 1),
                font_size=0.04,
                confidence=0.98,
            )
            output_json.append(bubble)

        return output_json
