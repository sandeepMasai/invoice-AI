from datetime import datetime, timezone
from typing import Any

from supabase import Client


def bump_format_success(sb: Client, format_id: str, snippet: str | None) -> None:
    row = sb.table("invoice_formats").select("success_count").eq("id", format_id).single().execute()
    cur = (row.data or {}).get("success_count") or 0
    update: dict[str, Any] = {
        "success_count": int(cur) + 1,
        "last_used_at": datetime.now(timezone.utc).isoformat(),
    }
    if snippet:
        update["sample_snippet"] = snippet[:2000]
    sb.table("invoice_formats").update(update).eq("id", format_id).execute()


def ensure_format_from_correction(
    sb: Client,
    user_id: str,
    name: str,
    template_json: dict[str, Any],
    sample_snippet: str | None,
) -> str:
    row = {
        "user_id": user_id,
        "name": name,
        "template_json": template_json,
        "sample_snippet": sample_snippet,
    }
    res = sb.table("invoice_formats").insert(row).execute()
    return res.data[0]["id"]


def record_format_match(sb: Client, invoice_id: str, format_id: str, score: float) -> None:
    sb.table("invoice_format_matches").upsert(
        {"invoice_id": invoice_id, "format_id": format_id, "score": score},
        on_conflict="invoice_id,format_id",
    ).execute()
