from difflib import SequenceMatcher
from typing import Any

from supabase import Client

from app.services.parsing_service import header_fingerprint
from app.utils.logging import get_logger

log = get_logger(__name__)

SIM_THRESHOLD = 0.35


def find_best_format(
    sb: Client,
    user_id: str,
    ocr_text: str,
) -> tuple[str | None, float, dict[str, Any] | None, str | None]:
    fp = header_fingerprint(ocr_text)
    if not fp:
        return None, 0.0, None, None

    res = (
        sb.table("invoice_formats")
        .select("id,template_json,sample_snippet,name,embedding")
        .or_(f"user_id.eq.{user_id},user_id.is.null")
        .limit(80)
        .execute()
    )
    rows = res.data or []
    best_id: str | None = None
    best_score = 0.0
    best_template: dict[str, Any] | None = None
    best_snippet: str | None = None

    for row in rows:
        snippet = (row.get("sample_snippet") or "")[:800].lower()
        if not snippet:
            tmpl = row.get("template_json") or {}
            snippet = str(tmpl.get("header_sample", ""))[:800].lower()
        score = SequenceMatcher(None, fp, snippet).ratio() if snippet else 0.0
        if score > best_score:
            best_score = score
            best_id = row["id"]
            best_template = row.get("template_json") or {}
            best_snippet = row.get("sample_snippet")

    if best_score < SIM_THRESHOLD:
        return None, best_score, None, None
    return best_id, best_score, best_template, best_snippet
