from typing import Annotated, Any
from uuid import UUID

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query, status
from postgrest.exceptions import APIError
from supabase import Client

from app.config import Settings, get_settings
from app.database import (
    get_file,
    get_invoice,
    insert_job,
    list_invoices,
    schema_mismatch_http_exception,
    supabase_rest_schema_error,
    update_invoice,
)
from app.dependencies import get_current_user_id, supabase_client
from app.invoice_payload import merge_json_data_for_patch, normalize_invoice_row_for_api
from app.schemas.invoice import (
    InvoiceDetail,
    InvoicePatchBody,
    InvoiceSummary,
    ProcessInvoiceResponse,
)
from app.workers.process_invoice import process_invoice_pipeline

router = APIRouter(prefix="/invoices", tags=["invoices"])


def _uuid_or_none(v: Any) -> UUID | None:
    if v is None:
        return None
    try:
        return UUID(str(v))
    except ValueError:
        return None


def _maybe_raise_schema_mismatch(e: APIError) -> None:
    if supabase_rest_schema_error(e):
        raise schema_mismatch_http_exception(e) from e


@router.post("/{file_id}/process", response_model=ProcessInvoiceResponse)
def trigger_process(
    file_id: UUID,
    background_tasks: BackgroundTasks,
    user_id: str = Depends(get_current_user_id),
    sb: Client = Depends(supabase_client),
    settings: Settings = Depends(get_settings),
) -> ProcessInvoiceResponse:
    try:
        f = get_file(sb, str(file_id), user_id)
    except APIError as e:
        _maybe_raise_schema_mismatch(e)
        raise
    if not f:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="File not found")

    try:
        job = insert_job(sb, user_id=user_id, file_id=str(file_id))
    except APIError as e:
        _maybe_raise_schema_mismatch(e)
        raise
    jid = job["id"]

    background_tasks.add_task(
        process_invoice_pipeline,
        user_id,
        str(file_id),
        str(jid),
        settings,
    )
    return ProcessInvoiceResponse(job_id=UUID(jid), status="queued")


@router.get("", response_model=list[InvoiceSummary])
def list_user_invoices(
    user_id: str = Depends(get_current_user_id),
    sb: Client = Depends(supabase_client),
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
    offset: Annotated[int, Query(ge=0)] = 0,
    vendor: str | None = None,
    date_from: str | None = None,
    date_to: str | None = None,
) -> list[InvoiceSummary]:
    try:
        rows = list_invoices(
            sb,
            user_id,
            limit=limit,
            offset=offset,
            vendor=vendor,
            date_from=date_from,
            date_to=date_to,
        )
    except APIError as e:
        # If Supabase schema is temporarily missing relations, don't crash the whole UI.
        if supabase_rest_schema_error(e):
            return []
        _maybe_raise_schema_mismatch(e)
        raise
    out: list[InvoiceSummary] = []
    for r in rows:
        n = normalize_invoice_row_for_api(r)
        # Response models require UUID fields; older/legacy rows can have NULLs.
        # Skip those rows instead of returning 500.
        if not n.get("file_id"):
            continue
        out.append(
            InvoiceSummary(
                id=n["id"],
                file_id=n["file_id"],
                vendor_raw=n.get("vendor_raw"),
                invoice_number=n.get("invoice_number"),
                invoice_date=n.get("invoice_date"),
                currency=n.get("currency"),
                total_amount=n.get("total_amount"),
                confidence=float(n["confidence"]) if n.get("confidence") is not None else None,
                is_duplicate_candidate=bool(n.get("is_duplicate_candidate")),
                created_at=str(n["created_at"]),
            )
        )
    return out


@router.get("/{invoice_id}", response_model=InvoiceDetail)
def get_one_invoice(
    invoice_id: UUID,
    user_id: str = Depends(get_current_user_id),
    sb: Client = Depends(supabase_client),
) -> InvoiceDetail:
    try:
        r = get_invoice(sb, str(invoice_id), user_id)
    except APIError as e:
        if supabase_rest_schema_error(e):
            # When the `public.invoices` relation is missing, treat as not found.
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Invoice not found")
        _maybe_raise_schema_mismatch(e)
        raise
    if not r:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Invoice not found")

    n = normalize_invoice_row_for_api(r)
    if not n.get("file_id"):
        # Can't render a detail page without the referenced file UUID.
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Invoice file missing")
    ext = n.get("extraction") or {}
    ocr_text = None
    if isinstance(ext, dict):
        ocr_meta = ext.get("_ocr_meta") or {}
        if isinstance(ocr_meta, dict):
            raw_preview = ocr_meta.get("preview")
            if raw_preview is not None:
                ocr_text = str(raw_preview)
            elif ocr_meta.get("text") is not None:
                ocr_text = str(ocr_meta["text"])
            if ocr_text is not None and not ocr_text.strip():
                ocr_text = None
    return InvoiceDetail(
        id=n["id"],
        file_id=n["file_id"],
        vendor_raw=n.get("vendor_raw"),
        invoice_number=n.get("invoice_number"),
        invoice_date=n.get("invoice_date"),
        currency=n.get("currency"),
        total_amount=n.get("total_amount"),
        confidence=float(n["confidence"]) if n.get("confidence") is not None else None,
        is_duplicate_candidate=bool(n.get("is_duplicate_candidate")),
        created_at=str(n["created_at"]),
        due_date=n.get("due_date"),
        subtotal=n.get("subtotal"),
        tax_total=n.get("tax_total"),
        line_items=n.get("line_items") or [],
        extraction=ext if isinstance(ext, dict) else {},
        format_id=_uuid_or_none(n.get("format_id")),
        is_duplicate_of=_uuid_or_none(n.get("is_duplicate_of")),
        ocr_text=ocr_text,
    )


@router.patch("/{invoice_id}", response_model=InvoiceDetail)
def patch_invoice(
    invoice_id: UUID,
    body: InvoicePatchBody,
    user_id: str = Depends(get_current_user_id),
    sb: Client = Depends(supabase_client),
) -> InvoiceDetail:
    try:
        r = get_invoice(sb, str(invoice_id), user_id)
    except APIError as e:
        _maybe_raise_schema_mismatch(e)
        raise
    if not r:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Invoice not found")

    payload_modern: dict[str, Any] = {}
    if body.vendor_raw is not None:
        payload_modern["vendor_name"] = body.vendor_raw
    if body.invoice_date is not None:
        payload_modern["invoice_date"] = body.invoice_date.isoformat() if body.invoice_date else None
    if body.currency is not None:
        payload_modern["currency"] = body.currency
    if body.total_amount is not None:
        payload_modern["total_amount"] = float(body.total_amount) if body.total_amount is not None else None
    if any(
        x is not None
        for x in (body.line_items, body.extraction, body.invoice_number, body.due_date)
    ):
        payload_modern["json_data"] = merge_json_data_for_patch(
            r.get("json_data"),
            line_items=body.line_items,
            extraction=body.extraction,
            invoice_number=body.invoice_number,
            due_date=body.due_date,
        )

    payload_legacy: dict[str, Any] = {}
    if body.vendor_raw is not None:
        payload_legacy["vendor_raw"] = body.vendor_raw
    if body.invoice_number is not None:
        payload_legacy["invoice_number"] = body.invoice_number
    if body.invoice_date is not None:
        payload_legacy["invoice_date"] = body.invoice_date.isoformat() if body.invoice_date else None
    if body.due_date is not None:
        payload_legacy["due_date"] = body.due_date.isoformat() if body.due_date else None
    if body.currency is not None:
        payload_legacy["currency"] = body.currency
    if body.total_amount is not None:
        payload_legacy["total_amount"] = float(body.total_amount) if body.total_amount is not None else None
    if body.line_items is not None:
        payload_legacy["line_items"] = body.line_items
    if body.extraction is not None:
        ext = dict(r.get("extraction") or {})
        if not ext and isinstance(r.get("json_data"), dict):
            ext = dict((r.get("json_data") or {}).get("extraction") or {})
        ext.update(body.extraction)
        ext["_human_corrected"] = True
        payload_legacy["extraction"] = ext

    if payload_modern:
        try:
            update_invoice(sb, str(invoice_id), user_id, payload_modern)
        except APIError as e:
            if supabase_rest_schema_error(e) and payload_legacy:
                update_invoice(sb, str(invoice_id), user_id, payload_legacy)
            else:
                _maybe_raise_schema_mismatch(e)
                raise
    elif payload_legacy:
        try:
            update_invoice(sb, str(invoice_id), user_id, payload_legacy)
        except APIError as e:
            _maybe_raise_schema_mismatch(e)
            raise

    return get_one_invoice(invoice_id, user_id, sb)
