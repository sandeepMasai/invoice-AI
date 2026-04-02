import re
from typing import Any


def header_fingerprint(ocr_text: str, max_chars: int = 800) -> str:
    cleaned = re.sub(r"\s+", " ", ocr_text.strip())
    return cleaned[:max_chars].lower()


def merge_chunks(chunks: list[str]) -> str:
    return "\n\n".join(c.strip() for c in chunks if c and c.strip())


def build_llm_context(ocr_text: str, template_snippet: str | None) -> str:
    if template_snippet:
        return f"{ocr_text}\n\n---\nReference snippet from similar invoice:\n{template_snippet[:2000]}"
    return ocr_text


def post_process_extraction(data: dict[str, Any]) -> dict[str, Any]:
    out = dict(data)
    for k in ("vendor_name", "invoice_number", "currency"):
        v = out.get(k)
        if isinstance(v, str):
            out[k] = v.strip() or None
    return out
