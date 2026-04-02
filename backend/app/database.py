from collections import defaultdict
from typing import Any

from postgrest.exceptions import APIError
from supabase import Client, create_client

from app.config import Settings, get_settings
from app.invoice_payload import unpack_invoice_json_data, vendor_display_from_row
from app.utils.logging import get_logger

log = get_logger(__name__)


def get_supabase(settings: Settings | None = None) -> Client:
    s = settings or get_settings()
    return create_client(s.supabase_url, s.supabase_service_role_key)


def insert_file_row(
    sb: Client,
    *,
    user_id: str,
    file_url: str,
    mime_type: str | None = None,
    original_filename: str | None = None,
    byte_size: int | None = None,
    sha256: str | None = None,
) -> dict[str, Any]:
    """Persist file row. DB column is `file_url` (storage object path). Extra fields optional if columns exist."""
    row: dict[str, Any] = {"user_id": user_id, "file_url": file_url}
    if mime_type is not None:
        row["mime_type"] = mime_type
    if original_filename is not None:
        row["original_filename"] = original_filename
    if byte_size is not None:
        row["byte_size"] = byte_size
    if sha256 is not None:
        row["sha256"] = sha256
    try:
        res = sb.table("files").insert(row).execute()
    except APIError as e:
        if supabase_rest_schema_error(e) and len(row) > 2:
            res = sb.table("files").insert({"user_id": user_id, "file_url": file_url}).execute()
        else:
            raise
    return res.data[0]


def insert_job(sb: Client, *, user_id: str, file_id: str) -> dict[str, Any]:
    res = (
        sb.table("processing_jobs")
        .insert({"user_id": user_id, "file_id": file_id, "status": "queued"})
        .execute()
    )
    return res.data[0]


def update_job(
    sb: Client,
    job_id: str,
    *,
    status: str | None = None,
    error_message: str | None = None,
    attempt_delta: int = 0,
    started_at: str | None = None,
    finished_at: str | None = None,
) -> None:
    # Job updates must never crash invoice processing; older Supabase schemas can be missing
    # one or more job columns. Best effort: try, then drop missing keys and retry, else ignore.
    payload: dict[str, Any] = {}
    if status is not None:
        payload["status"] = status
    if error_message is not None:
        payload["error_message"] = error_message
    if started_at is not None:
        payload["started_at"] = started_at
    if finished_at is not None:
        payload["finished_at"] = finished_at

    if attempt_delta:
        try:
            cur = (
                sb.table("processing_jobs")
                .select("attempt_count")
                .eq("id", job_id)
                .single()
                .execute()
            )
            ac = (cur.data or {}).get("attempt_count") or 0
            payload["attempt_count"] = int(ac) + attempt_delta
        except APIError as e:
            if supabase_rest_schema_error(e):
                log.warning("processing_jobs attempt_count unavailable; skipping increment")
            else:
                # Non-schema errors should still surface.
                raise

    if not payload:
        return

    try:
        sb.table("processing_jobs").update(payload).eq("id", job_id).execute()
        return
    except APIError as e:
        if not supabase_rest_schema_error(e):
            raise

        msg = (e.message or "")
        for k in list(payload.keys()):
            if f"'{k}'" in msg:
                payload.pop(k, None)

        if not payload:
            return

        try:
            sb.table("processing_jobs").update(payload).eq("id", job_id).execute()
        except APIError:
            # Still drifting; ignore.
            return


def get_file(sb: Client, file_id: str, user_id: str) -> dict[str, Any] | None:
    res = sb.table("files").select("*").eq("id", file_id).eq("user_id", user_id).single().execute()
    return res.data


def get_job(sb: Client, job_id: str, user_id: str) -> dict[str, Any] | None:
    res = (
        sb.table("processing_jobs")
        .select("*")
        .eq("id", job_id)
        .eq("user_id", user_id)
        .single()
        .execute()
    )
    return res.data


def list_invoices(
    sb: Client,
    user_id: str,
    *,
    limit: int = 50,
    offset: int = 0,
    vendor: str | None = None,
    date_from: str | None = None,
    date_to: str | None = None,
) -> list[dict[str, Any]]:
    q = sb.table("invoices").select("*").eq("user_id", user_id)
    if vendor:
        safe = "".join(c for c in vendor if c not in ",%")[:200] or vendor[:200]
        q = q.ilike("vendor_name", f"%{safe}%")
    if date_from:
        q = q.gte("invoice_date", date_from)
    if date_to:
        q = q.lte("invoice_date", date_to)
    res = q.order("created_at", desc=True).range(offset, offset + limit - 1).execute()
    return res.data or []


def get_invoice(sb: Client, invoice_id: str, user_id: str) -> dict[str, Any] | None:
    res = (
        sb.table("invoices")
        .select("*")
        .eq("id", invoice_id)
        .eq("user_id", user_id)
        .single()
        .execute()
    )
    return res.data


def update_invoice(sb: Client, invoice_id: str, user_id: str, payload: dict[str, Any]) -> None:
    sb.table("invoices").update(payload).eq("id", invoice_id).eq("user_id", user_id).execute()


def insert_invoice(sb: Client, row: dict[str, Any]) -> dict[str, Any]:
    res = sb.table("invoices").insert(row).execute()
    return res.data[0]


def count_duplicate_candidates(sb: Client, user_id: str) -> int:
    """Count duplicate-flagged invoices using server-side filters only (no full-table json_data scan)."""
    try:
        r = (
            sb.table("invoices")
            .select("id", count="exact")
            .eq("user_id", user_id)
            .eq("is_duplicate_candidate", True)
            .execute()
        )
        return r.count or 0
    except APIError as e:
        if not supabase_rest_schema_error(e):
            log.warning(
                "duplicate count column query failed (%s); returning 0: %s",
                e.code,
                e.message,
            )
            return 0

    try:
        r = (
            sb.table("invoices")
            .select("id", count="exact")
            .eq("user_id", user_id)
            .contains("json_data", {"is_duplicate_candidate": True})
            .execute()
        )
        return r.count or 0
    except APIError as e:
        log.warning(
            "duplicate count json_data contains fallback failed (%s); returning 0: %s",
            e.code,
            e.message,
        )
        return 0


def supabase_rest_schema_error(exc: BaseException) -> bool:
    """True when PostgREST/Postgres indicates missing table, view, or column (common migration drift)."""
    if not isinstance(exc, APIError):
        return False
    code = exc.code or ""
    if code in ("PGRST205", "42703", "42P01"):
        return True
    msg = (exc.message or "").lower()
    return (
        "schema cache" in msg
        or "could not find the table" in msg
        or "does not exist" in msg
    )


def schema_mismatch_http_exception(exc: APIError):
    """HTTP 503 with an actionable message; use from API routes."""
    from fastapi import HTTPException

    code = exc.code or ""
    if code == "42703":
        detail = (
            "Database schema does not match this app (Postgres 42703). "
            "Often `public.invoices` is missing `user_id` or other columns. "
            "Run SQL from supabase/migrations/20250401000003_align_invoices_schema.sql in the Supabase SQL Editor "
            "(after 20250401000001_initial.sql so `files` and related tables exist), or run `supabase db push`. "
            "Alternatively rename/drop the conflicting `invoices` table and apply the full migration chain."
        )
    elif code == "PGRST205":
        detail = (
            "Supabase PostgREST could not find a table or view (PGRST205). "
            "Apply supabase/migrations (initial, analytics, and 20250401000003_align_invoices_schema.sql if needed) "
            "or run `supabase db push`."
        )
    else:
        detail = (
            f"Supabase schema or query error (code={code!r}, message={exc.message!r}). "
            "Apply supabase/migrations to this project."
        )
    return HTTPException(status_code=503, detail=detail)


def _fetch_invoices_paginated(sb: Client, user_id: str, columns: str) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    offset = 0
    page = 1000
    while True:
        res = sb.table("invoices").select(columns).eq("user_id", user_id).range(offset, offset + page - 1).execute()
        batch = res.data or []
        out.extend(batch)
        if len(batch) < page:
            break
        offset += page
    return out


def _parse_month_key(invoice_date: object) -> str | None:
    if invoice_date is None:
        return None
    s = str(invoice_date).strip()
    if not s:
        return None
    if "T" in s:
        s = s.split("T", 1)[0]
    elif " " in s:
        s = s.split(" ", 1)[0]
    if len(s) < 10:
        return None
    s = s[:10]
    try:
        y, m, _d = int(s[0:4]), int(s[5:7]), int(s[8:10])
        return f"{y:04d}-{m:02d}-01"
    except (ValueError, IndexError):
        return None


def _float_amount(v: object) -> float:
    if v is None:
        return 0.0
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


def _analytics_monthly_from_invoices(sb: Client, user_id: str) -> list[dict[str, Any]]:
    rows = _fetch_invoices_paginated(sb, user_id, "invoice_date,currency,total_amount")
    agg: dict[tuple[str, str], list[float | int]] = defaultdict(lambda: [0.0, 0])
    for r in rows:
        mk = _parse_month_key(r.get("invoice_date"))
        if not mk:
            continue
        cur = (r.get("currency") or "UNKNOWN") or "UNKNOWN"
        k = (mk, cur)
        agg[k][0] = float(agg[k][0]) + _float_amount(r.get("total_amount"))
        agg[k][1] = int(agg[k][1]) + 1
    keys = sorted(agg.keys(), key=lambda x: x[0], reverse=True)
    return [
        {"month": mk, "currency": cur, "total_spend": float(agg[(mk, cur)][0]), "invoice_count": int(agg[(mk, cur)][1])}
        for mk, cur in keys
    ]


def _invoice_row_total_amount(r: dict[str, Any]) -> float:
    v = r.get("total_amount")
    if v is not None:
        return _float_amount(v)
    _li, ext, meta = unpack_invoice_json_data(r.get("json_data"))
    if isinstance(ext, dict):
        t = ext.get("total_amount") if ext.get("total_amount") is not None else ext.get("total")
        if t is not None:
            return _float_amount(t)
    if isinstance(meta, dict) and meta.get("total_amount") is not None:
        return _float_amount(meta.get("total_amount"))
    return 0.0


def _invoice_row_vendor_display(r: dict[str, Any]) -> str:
    v = vendor_display_from_row(r)
    if v is not None and str(v).strip():
        return str(v).strip()
    _li, ext, _meta = unpack_invoice_json_data(r.get("json_data"))
    if isinstance(ext, dict):
        for k in ("vendor_name", "vendor", "supplier_name"):
            x = ext.get(k)
            if x is not None and str(x).strip():
                return str(x).strip()
    return "Unknown"


_VENDOR_SELECT_TRIES = (
    "vendor_id,vendor_name,vendor_raw,currency,total_amount,json_data",
    "vendor_id,vendor_name,vendor_raw,currency,total_amount",
    "vendor_name,vendor_raw,currency,total_amount,json_data",
    "vendor_name,vendor_raw,currency,total_amount",
    "vendor_raw,currency,total_amount,json_data",
    "vendor_raw,currency,total_amount",
    "currency,total_amount,json_data",
    "currency,total_amount",
)


def _analytics_vendors_from_invoices(sb: Client, user_id: str, limit: int) -> list[dict[str, Any]]:
    """Aggregate vendors from invoice rows; supports json_data-only vendor/totals (SQL views often miss these)."""
    rows: list[dict[str, Any]] = []
    last_err: APIError | None = None
    for cols in _VENDOR_SELECT_TRIES:
        try:
            rows = _fetch_invoices_paginated(sb, user_id, cols)
            break
        except APIError as e:
            last_err = e
            if not supabase_rest_schema_error(e):
                raise
            continue
    else:
        log.warning("vendor analytics: no invoice column set worked (%s)", last_err)
        return []

    agg: dict[tuple[str, str], list[float | int]] = defaultdict(lambda: [0.0, 0])
    display: dict[tuple[str, str], str] = {}
    for r in rows:
        vid = r.get("vendor_id")
        vlabel = _invoice_row_vendor_display(r)
        key = str(vid) if vid else f"raw:{vlabel.lower()}"
        cur = (r.get("currency") or "UNKNOWN") or "UNKNOWN"
        if cur == "UNKNOWN":
            _li, ext, _m = unpack_invoice_json_data(r.get("json_data"))
            if isinstance(ext, dict) and ext.get("currency") is not None:
                c = str(ext.get("currency")).strip()
                if c:
                    cur = c
        kc = (key, cur)
        agg[kc][0] = float(agg[kc][0]) + _invoice_row_total_amount(r)
        agg[kc][1] = int(agg[kc][1]) + 1
        if kc not in display:
            display[kc] = vlabel if vlabel != "Unknown" else (str(vid) if vid else "Unknown")
    ranked = sorted(agg.keys(), key=lambda k: float(agg[k][0]), reverse=True)[:limit]
    return [
        {
            "vendor_key": key,
            "vendor_display": display.get((key, cur), "Unknown"),
            "currency": cur,
            "total_spend": float(agg[(key, cur)][0]),
            "invoice_count": int(agg[(key, cur)][1]),
        }
        for key, cur in ranked
    ]


def _analytics_currencies_from_invoices(sb: Client, user_id: str) -> list[dict[str, Any]]:
    rows = _fetch_invoices_paginated(sb, user_id, "currency,total_amount")
    agg: dict[str, list[float | int]] = defaultdict(lambda: [0.0, 0])
    for r in rows:
        cur = (r.get("currency") or "UNKNOWN") or "UNKNOWN"
        agg[cur][0] = float(agg[cur][0]) + _float_amount(r.get("total_amount"))
        agg[cur][1] = int(agg[cur][1]) + 1
    keys = sorted(agg.keys(), key=lambda c: float(agg[c][0]), reverse=True)
    return [
        {"currency": c, "total_spend": float(agg[c][0]), "invoice_count": int(agg[c][1])}
        for c in keys
    ]


def analytics_monthly_spend(sb: Client, user_id: str) -> list[dict[str, Any]]:
    try:
        res = (
            sb.table("analytics_monthly_spend")
            .select("month,currency,total_spend,invoice_count")
            .eq("user_id", user_id)
            .order("month", desc=True)
            .execute()
        )
        return res.data or []
    except APIError as e:
        if not supabase_rest_schema_error(e):
            raise
        log.warning("analytics_monthly_spend view unavailable (%s); aggregating from invoices", e.code)
        try:
            return _analytics_monthly_from_invoices(sb, user_id)
        except APIError as e2:
            if supabase_rest_schema_error(e2):
                log.warning("monthly invoice fallback failed: %s %s", e2.code, e2.message)
                return []
            raise


def analytics_vendor_totals(sb: Client, user_id: str, limit: int = 50) -> list[dict[str, Any]]:
    try:
        res = (
            sb.table("analytics_vendor_totals")
            .select("vendor_key,vendor_display,currency,total_spend,invoice_count")
            .eq("user_id", user_id)
            .order("total_spend", desc=True)
            .limit(limit)
            .execute()
        )
        data = res.data or []
        # SQL view only reads scalar columns; if vendor/total live in json_data only, the view is empty.
        if not data:
            try:
                alt = _analytics_vendors_from_invoices(sb, user_id, limit)
                if alt:
                    log.debug("analytics_vendor_totals: using invoice-row aggregation (view empty)")
                    return alt
            except APIError as e2:
                log.warning("vendor totals empty view + fallback failed: %s", e2.message)
        return data
    except APIError as e:
        if not supabase_rest_schema_error(e):
            raise
        log.warning("analytics_vendor_totals view unavailable (%s); aggregating from invoices", e.code)
        try:
            return _analytics_vendors_from_invoices(sb, user_id, limit)
        except APIError as e2:
            if supabase_rest_schema_error(e2):
                log.warning("vendor invoice fallback failed: %s %s", e2.code, e2.message)
                return []
            raise


def analytics_currency_totals(sb: Client, user_id: str) -> list[dict[str, Any]]:
    try:
        res = (
            sb.table("analytics_currency_totals")
            .select("currency,total_spend,invoice_count")
            .eq("user_id", user_id)
            .order("total_spend", desc=True)
            .execute()
        )
        return res.data or []
    except APIError as e:
        if not supabase_rest_schema_error(e):
            raise
        log.warning("analytics_currency_totals view unavailable (%s); aggregating from invoices", e.code)
        try:
            return _analytics_currencies_from_invoices(sb, user_id)
        except APIError as e2:
            if supabase_rest_schema_error(e2):
                log.warning("currency invoice fallback failed: %s %s", e2.code, e2.message)
                return []
            raise
