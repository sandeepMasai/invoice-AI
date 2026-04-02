from concurrent.futures import ThreadPoolExecutor
from typing import Any

from fastapi import APIRouter, Depends, Query
from postgrest.exceptions import APIError
from supabase import Client

from app.config import Settings, get_settings
from app.database import (
    analytics_currency_totals,
    analytics_monthly_spend,
    analytics_vendor_totals,
    count_duplicate_candidates,
    get_supabase,
    schema_mismatch_http_exception,
    supabase_rest_schema_error,
)
from app.dependencies import get_current_user_id, supabase_client
from app.utils.logging import get_logger

log = get_logger(__name__)

router = APIRouter(prefix="/analytics", tags=["analytics"])


def _raise_if_schema_mismatch(exc: BaseException) -> None:
    if isinstance(exc, APIError) and supabase_rest_schema_error(exc):
        raise schema_mismatch_http_exception(exc) from exc


def _serialize_monthly(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        {
            "month": str(r["month"]) if r.get("month") is not None else "",
            "currency": r.get("currency"),
            "total_spend": float(r["total_spend"]) if r.get("total_spend") is not None else 0.0,
            "invoice_count": int(r.get("invoice_count") or 0),
        }
        for r in rows
    ]


def _serialize_vendors(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        {
            "vendor_key": r.get("vendor_key"),
            "vendor_display": r.get("vendor_display"),
            "currency": r.get("currency"),
            "total_spend": float(r["total_spend"]) if r.get("total_spend") is not None else 0.0,
            "invoice_count": int(r.get("invoice_count") or 0),
        }
        for r in rows
    ]


def _serialize_currencies(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        {
            "currency": r.get("currency"),
            "total_spend": float(r["total_spend"]) if r.get("total_spend") is not None else 0.0,
            "invoice_count": int(r.get("invoice_count") or 0),
        }
        for r in rows
    ]


def _summary_fetch_monthly(settings: Settings, user_id: str) -> list[dict[str, Any]]:
    sb = get_supabase(settings)
    try:
        return analytics_monthly_spend(sb, user_id)
    except APIError as e:
        if supabase_rest_schema_error(e):
            log.warning("analytics_monthly_spend schema mismatch; returning empty monthly")
            return []
        raise


def _summary_fetch_vendors(settings: Settings, user_id: str) -> list[dict[str, Any]]:
    sb = get_supabase(settings)
    try:
        return analytics_vendor_totals(sb, user_id, limit=40)
    except APIError as e:
        if supabase_rest_schema_error(e):
            log.warning("analytics_vendor_totals schema mismatch; returning empty vendors")
            return []
        raise


def _summary_fetch_currencies(settings: Settings, user_id: str) -> list[dict[str, Any]]:
    sb = get_supabase(settings)
    try:
        return analytics_currency_totals(sb, user_id)
    except APIError as e:
        if supabase_rest_schema_error(e):
            log.warning("analytics_currency_totals schema mismatch; returning empty currencies")
            return []
        raise


def _summary_fetch_invoice_count(settings: Settings, user_id: str) -> int:
    sb = get_supabase(settings)
    try:
        inv = sb.table("invoices").select("id", count="exact").eq("user_id", user_id).execute()
        return inv.count or 0
    except APIError as e:
        log.warning(
            "invoice count for summary failed (%s); returning 0: %s",
            e.code,
            e.message,
        )
        return 0


def _summary_fetch_dup_count(settings: Settings, user_id: str) -> int:
    sb = get_supabase(settings)
    try:
        return count_duplicate_candidates(sb, user_id)
    except APIError as e:
        log.warning(
            "duplicate candidates count failed (%s); returning 0: %s",
            e.code,
            e.message,
        )
        return 0


@router.get("/monthly")
def monthly(
    user_id: str = Depends(get_current_user_id),
    sb: Client = Depends(supabase_client),
) -> list[dict[str, Any]]:
    try:
        rows = analytics_monthly_spend(sb, user_id)
        return _serialize_monthly(rows)
    except APIError as e:
        _raise_if_schema_mismatch(e)
        raise


@router.get("/vendors")
def vendors(
    user_id: str = Depends(get_current_user_id),
    sb: Client = Depends(supabase_client),
    limit: int = Query(50, ge=1, le=200),
) -> list[dict[str, Any]]:
    try:
        rows = analytics_vendor_totals(sb, user_id, limit=limit)
        return _serialize_vendors(rows)
    except APIError as e:
        _raise_if_schema_mismatch(e)
        raise


@router.get("/currencies")
def currencies(
    user_id: str = Depends(get_current_user_id),
    sb: Client = Depends(supabase_client),
) -> list[dict[str, Any]]:
    try:
        rows = analytics_currency_totals(sb, user_id)
        return _serialize_currencies(rows)
    except APIError as e:
        _raise_if_schema_mismatch(e)
        raise


@router.get("/summary")
def summary(
    user_id: str = Depends(get_current_user_id),
    settings: Settings = Depends(get_settings),
) -> dict[str, Any]:
    # Run independent Supabase queries concurrently (each thread uses its own client).
    # The dashboard should still render if analytics relations are missing (empty stats).
    try:
        with ThreadPoolExecutor(max_workers=5) as pool:
            f_m = pool.submit(_summary_fetch_monthly, settings, user_id)
            f_v = pool.submit(_summary_fetch_vendors, settings, user_id)
            f_c = pool.submit(_summary_fetch_currencies, settings, user_id)
            f_i = pool.submit(_summary_fetch_invoice_count, settings, user_id)
            f_d = pool.submit(_summary_fetch_dup_count, settings, user_id)
            monthly_rows = f_m.result()
            vendor_rows = f_v.result()
            cur_rows = f_c.result()
            total_invoices = f_i.result()
            dup_count = f_d.result()

        return {
            "total_invoices": total_invoices,
            "duplicate_candidates": dup_count,
            "monthly": _serialize_monthly(monthly_rows[:24]),
            "top_vendors": _serialize_vendors(vendor_rows[:25]),
            "currencies": _serialize_currencies(cur_rows),
        }
    except APIError as e:
        _raise_if_schema_mismatch(e)
        raise
