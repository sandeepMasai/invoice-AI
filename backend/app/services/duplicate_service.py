import hashlib
import re
from datetime import date
from decimal import Decimal

from postgrest.exceptions import APIError
from supabase import Client

from app.database import supabase_rest_schema_error
from app.invoice_payload import duplicate_fingerprint_from_json_data


def normalize_vendor_key(name: str | None) -> str:
    if not name:
        return ""
    return re.sub(r"\s+", " ", name.strip().lower())


def normalized_name_from_raw(raw: str | None) -> str:
    if not raw:
        return "unknown"
    s = re.sub(r"[^\w\s-]", "", raw.lower())
    s = re.sub(r"\s+", "-", s.strip())
    return s[:120] or "unknown"


def build_duplicate_fingerprint(
    vendor: str | None,
    invoice_number: str | None,
    invoice_date: date | None,
    total: Decimal | None,
    currency: str | None,
) -> str:
    parts = [
        normalize_vendor_key(vendor),
        (invoice_number or "").strip().lower(),
        invoice_date.isoformat() if invoice_date else "",
        str(total) if total is not None else "",
        (currency or "").upper(),
    ]
    raw = "|".join(parts)
    return hashlib.sha256(raw.encode()).hexdigest()


def find_duplicate_invoice(
    sb: Client,
    user_id: str,
    fingerprint: str,
    exclude_invoice_id: str | None = None,
) -> str | None:
    if not fingerprint:
        return None
    try:
        res = (
            sb.table("invoices")
            .select("id")
            .eq("user_id", user_id)
            .eq("duplicate_fingerprint", fingerprint)
            .limit(5)
            .execute()
        )
        for row in res.data or []:
            rid = row["id"]
            if exclude_invoice_id and rid == exclude_invoice_id:
                continue
            return rid
        return None
    except APIError as e:
        if not supabase_rest_schema_error(e):
            raise
    res = sb.table("invoices").select("id,json_data").eq("user_id", user_id).execute()
    for row in res.data or []:
        rid = row["id"]
        if exclude_invoice_id and rid == exclude_invoice_id:
            continue
        if duplicate_fingerprint_from_json_data(row.get("json_data")) == fingerprint:
            return rid
    return None


def duplicate_flags(
    sb: Client,
    user_id: str,
    fingerprint: str,
) -> tuple[bool, str | None]:
    dup_id = find_duplicate_invoice(sb, user_id, fingerprint)
    return (dup_id is not None, dup_id)
