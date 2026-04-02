import re

from supabase import Client
from postgrest.exceptions import APIError

from app.services.duplicate_service import normalized_name_from_raw
from app.database import supabase_rest_schema_error


def resolve_vendor(
    sb: Client,
    user_id: str,
    vendor_raw: str | None,
) -> tuple[str | None, str | None]:
    if not vendor_raw or not vendor_raw.strip():
        return None, None

    stripped = vendor_raw.strip()
    try:
        ra = sb.table("vendor_aliases").select("vendor_id").eq("alias_text", stripped).execute()
    except APIError as e:
        # Vendor normalization is optional; don't crash processing if tables are missing.
        if supabase_rest_schema_error(e):
            return None, vendor_raw
        raise
    for row in ra.data or []:
        vid = row.get("vendor_id")
        if not vid:
            continue
        v = (
            sb.table("vendors")
            .select("id")
            .eq("id", str(vid))
            .eq("user_id", user_id)
            .limit(1)
            .execute()
        )
        if v.data:
            return str(vid), vendor_raw

    norm = normalized_name_from_raw(vendor_raw)
    try:
        existing = (
            sb.table("vendors")
            .select("id")
            .eq("user_id", user_id)
            .eq("normalized_name", norm)
            .limit(1)
            .execute()
        )
    except APIError as e:
        if supabase_rest_schema_error(e):
            return None, vendor_raw
        raise
    if existing.data:
        vid = str(existing.data[0]["id"])
        try:
            sb.table("vendor_aliases").upsert(
                {"vendor_id": vid, "alias_text": stripped, "source": "rule"},
                on_conflict="vendor_id,alias_text",
            ).execute()
        except APIError as e:
            if not supabase_rest_schema_error(e):
                raise
        return vid, vendor_raw

    display = stripped[:200]
    try:
        ins = (
            sb.table("vendors")
            .insert(
                {
                    "user_id": user_id,
                    "normalized_name": norm,
                    "display_name": display,
                    "metadata": {},
                }
            )
            .execute()
        )
    except APIError as e:
        if supabase_rest_schema_error(e):
            return None, vendor_raw
        raise
    vid = str(ins.data[0]["id"])
    try:
        sb.table("vendor_aliases").insert(
            {"vendor_id": vid, "alias_text": stripped, "source": "llm"}
        ).execute()
    except Exception:
        pass
    return vid, vendor_raw
