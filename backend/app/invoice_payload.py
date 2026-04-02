"""Map between API shapes (vendor_raw, storage_path, line_items, extraction) and DB columns (vendor_name, file_url, json_data)."""

from __future__ import annotations

from datetime import date
from typing import Any


def _as_dict(v: Any) -> dict[str, Any]:
    return v if isinstance(v, dict) else {}


def pack_invoice_json_data(
    *,
    line_items: list[dict[str, Any]],
    extraction: dict[str, Any],
    duplicate_fingerprint: str | None = None,
    is_duplicate_candidate: bool = False,
    is_duplicate_of: str | None = None,
    confidence: float | None = None,
    format_id: str | None = None,
    vendor_id: str | None = None,
    job_id: str | None = None,
    invoice_number: str | None = None,
    due_date: str | None = None,
    subtotal: float | None = None,
    tax_total: float | None = None,
) -> dict[str, Any]:
    """Single JSONB document for `invoices.json_data`."""
    payload: dict[str, Any] = {
        "line_items": line_items,
        "extraction": extraction,
    }
    if duplicate_fingerprint is not None:
        payload["duplicate_fingerprint"] = duplicate_fingerprint
    payload["is_duplicate_candidate"] = bool(is_duplicate_candidate)
    if is_duplicate_of is not None:
        payload["is_duplicate_of"] = is_duplicate_of
    if confidence is not None:
        payload["confidence"] = confidence
    if format_id is not None:
        payload["format_id"] = format_id
    if vendor_id is not None:
        payload["vendor_id"] = vendor_id
    if job_id is not None:
        payload["job_id"] = job_id
    if invoice_number is not None:
        payload["invoice_number"] = invoice_number
    if due_date is not None:
        payload["due_date"] = due_date
    if subtotal is not None:
        payload["subtotal"] = subtotal
    if tax_total is not None:
        payload["tax_total"] = tax_total
    return payload


def unpack_invoice_json_data(json_data: Any) -> tuple[list[dict[str, Any]], dict[str, Any], dict[str, Any]]:
    """Returns (line_items, extraction, extra_meta including confidence, flags, ids, etc.)."""
    jd = _as_dict(json_data)
    line_items = jd.get("line_items")
    if not isinstance(line_items, list):
        line_items = []
    extraction = jd.get("extraction")
    extraction = _as_dict(extraction)
    meta = {k: v for k, v in jd.items() if k not in ("line_items", "extraction")}
    return line_items, extraction, meta


def vendor_display_from_row(row: dict[str, Any]) -> str | None:
    return row.get("vendor_name") if row.get("vendor_name") is not None else row.get("vendor_raw")


def normalize_invoice_row_for_api(row: dict[str, Any]) -> dict[str, Any]:
    """Add API aliases and unpacked json_data onto a raw Supabase row (non-destructive copy)."""
    out = dict(row)
    line_items, extraction, meta = unpack_invoice_json_data(row.get("json_data"))
    out["vendor_raw"] = vendor_display_from_row(row)
    out["line_items"] = line_items
    out["extraction"] = extraction
    out["_json_meta"] = meta
    out["confidence"] = meta.get("confidence")
    out["is_duplicate_candidate"] = bool(meta.get("is_duplicate_candidate", False))
    out["is_duplicate_of"] = meta.get("is_duplicate_of")
    out["format_id"] = meta.get("format_id")
    out["invoice_number"] = row.get("invoice_number") if row.get("invoice_number") is not None else meta.get("invoice_number")
    out["due_date"] = row.get("due_date") if row.get("due_date") is not None else meta.get("due_date")
    out["subtotal"] = row.get("subtotal") if row.get("subtotal") is not None else meta.get("subtotal")
    out["tax_total"] = row.get("tax_total") if row.get("tax_total") is not None else meta.get("tax_total")
    return out


def merge_json_data_for_patch(
    current_json_data: Any,
    *,
    line_items: list[dict[str, Any]] | None = None,
    extraction: dict[str, Any] | None = None,
    invoice_number: str | None = None,
    due_date: date | None = None,
) -> dict[str, Any]:
    """Merge PATCH fields that live inside `json_data`. Caller updates scalar columns separately."""
    jd = dict(_as_dict(current_json_data))
    li = jd.get("line_items")
    if not isinstance(li, list):
        li = []
    ext = _as_dict(jd.get("extraction"))
    jd["line_items"] = line_items if line_items is not None else li
    if extraction is not None:
        ext = dict(ext)
        ext.update(extraction)
        ext["_human_corrected"] = True
        jd["extraction"] = ext
    else:
        jd["extraction"] = ext
    if invoice_number is not None:
        jd["invoice_number"] = invoice_number
    if due_date is not None:
        jd["due_date"] = due_date.isoformat() if due_date else None
    return jd


def duplicate_fingerprint_from_json_data(json_data: Any) -> str | None:
    jd = _as_dict(json_data)
    v = jd.get("duplicate_fingerprint")
    return str(v) if v else None


def infer_mime_type(filename: str) -> str:
    lower = (filename or "").lower()
    if lower.endswith(".pdf"):
        return "application/pdf"
    if lower.endswith(".png"):
        return "image/png"
    if lower.endswith(".jpg") or lower.endswith(".jpeg"):
        return "image/jpeg"
    if lower.endswith(".webp"):
        return "image/webp"
    return "application/octet-stream"
