import io
from typing import Any

import fitz  # PyMuPDF
from PIL import Image
import pytesseract

from app.utils.logging import get_logger

log = get_logger(__name__)


def extract_text_from_pdf(data: bytes) -> str:
    doc = fitz.open(stream=data, filetype="pdf")
    parts: list[str] = []
    try:
        for page in doc:
            text = page.get_text("text") or ""
            if len(text.strip()) < 40:
                pix = page.get_pixmap(matrix=fitz.Matrix(2, 2))
                img = Image.open(io.BytesIO(pix.tobytes("png")))
                text = pytesseract.image_to_string(img) or ""
            parts.append(text)
    finally:
        doc.close()
    return "\n\n".join(parts)


def extract_text_from_image(data: bytes) -> str:
    img = Image.open(io.BytesIO(data))
    return pytesseract.image_to_string(img) or ""


def run_ocr(filename: str, mime_type: str, data: bytes) -> tuple[str, dict[str, Any]]:
    meta: dict[str, Any] = {"engine": "tesseract", "mime_type": mime_type}
    lower = filename.lower()
    if mime_type == "application/pdf" or lower.endswith(".pdf"):
        text = extract_text_from_pdf(data)
        meta["source"] = "pdf"
    elif mime_type.startswith("image/") or lower.endswith((".png", ".jpg", ".jpeg", ".webp")):
        text = extract_text_from_image(data)
        meta["source"] = "image"
    else:
        log.warning("Unknown mime for OCR, trying image path: %s", mime_type)
        text = extract_text_from_image(data)
        meta["source"] = "fallback_image"
    text = text.strip()
    meta["char_count"] = len(text)
    return text, meta
