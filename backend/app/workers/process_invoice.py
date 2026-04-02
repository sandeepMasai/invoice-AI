from datetime import datetime, timezone
from typing import Any

from postgrest.exceptions import APIError

from app.config import Settings, get_settings
from app.database import get_file, insert_invoice, supabase_rest_schema_error, update_job
from app.invoice_payload import infer_mime_type, pack_invoice_json_data
from app.services.confidence_service import score_confidence
from app.services.duplicate_service import build_duplicate_fingerprint, duplicate_flags
from app.services.llm_service import extract_invoice_json
from app.services.ocr_service import run_ocr
from app.services.parsing_service import build_llm_context, header_fingerprint, post_process_extraction
from app.services.similarity_service import find_best_format
from app.services.template_service import bump_format_success, record_format_match
from app.services.validation_service import validate_extraction
from app.services.vendor_normalization_service import resolve_vendor
from app.utils.logging import get_logger

log = get_logger(__name__)


def process_invoice_pipeline(
    user_id: str,
    file_id: str,
    job_id: str,
    settings: Settings | None = None,
) -> None:
    from app.database import get_supabase

    settings = settings or get_settings()
    sb = get_supabase(settings)
    bucket = settings.storage_bucket
    now = datetime.now(timezone.utc).isoformat()

    try:
        update_job(sb, job_id, status="ocr_running", attempt_delta=1, started_at=now, error_message=None)
        file_row = get_file(sb, file_id, user_id)
        if not file_row:
            raise RuntimeError("File not found")

        storage_key = file_row.get("file_url") or file_row.get("storage_path")
        if not storage_key:
            raise RuntimeError("File row missing file_url/storage_path")
        raw_bytes = sb.storage.from_(bucket).download(storage_key)
        # `public.files` can be missing mime/original_filename in older schemas.
        # Use the storage object key (which contains the original extension) as a fallback
        # so PDFs don't get misclassified as images.
        filename = file_row.get("original_filename") or str(storage_key) or "upload"
        mime = file_row.get("mime_type") or infer_mime_type(str(filename))
        ocr_text, ocr_meta = run_ocr(str(filename), mime, raw_bytes)
        ocr_meta["preview"] = ocr_text[:4000]

        update_job(sb, job_id, status="llm_running")

        # Format matching is optional; skip if related tables are missing.
        try:
            format_id, sim_score, template_hints, format_snippet = find_best_format(sb, user_id, ocr_text)
        except APIError as e:
            if supabase_rest_schema_error(e):
                log.warning("format matching skipped due to schema drift: %s", e.message)
                format_id, sim_score, template_hints, format_snippet = None, 0.0, None, None
            else:
                raise
        context = build_llm_context(ocr_text, format_snippet)
        raw_llm = extract_invoice_json(settings, context, template_hints)
        raw_llm = post_process_extraction(raw_llm)

        model, val_errors = validate_extraction(raw_llm)
        vendor_id, _ = resolve_vendor(sb, user_id, model.vendor_name)

        fp = build_duplicate_fingerprint(
            model.vendor_name,
            model.invoice_number,
            model.invoice_date,
            model.total_amount,
            model.currency,
        )
        is_dup_candidate, dup_of = duplicate_flags(sb, user_id, fp)

        template_matched = format_id is not None
        conf = score_confidence(
            model,
            val_errors,
            int(ocr_meta.get("char_count") or 0),
            template_matched,
        )

        line_items_json: list[dict[str, Any]] = [
            li.model_dump(mode="json") for li in model.line_items
        ]
        extraction_payload = {**raw_llm, "_ocr_meta": ocr_meta, "_validation_errors": val_errors}

        json_data = pack_invoice_json_data(
            line_items=line_items_json,
            extraction=extraction_payload,
            duplicate_fingerprint=fp,
            is_duplicate_candidate=is_dup_candidate,
            is_duplicate_of=dup_of,
            confidence=float(conf),
            format_id=str(format_id) if format_id else None,
            vendor_id=vendor_id,
            job_id=job_id,
            invoice_number=model.invoice_number,
            due_date=model.due_date.isoformat() if model.due_date else None,
            subtotal=float(model.subtotal) if model.subtotal is not None else None,
            tax_total=float(model.tax_total) if model.tax_total is not None else None,
        )
        modern_row: dict[str, Any] = {
            "user_id": user_id,
            "file_id": file_id,
            "vendor_name": model.vendor_name,
            "invoice_date": model.invoice_date.isoformat() if model.invoice_date else None,
            "currency": model.currency,
            "total_amount": float(model.total_amount) if model.total_amount is not None else None,
            "json_data": json_data,
        }
        legacy_row: dict[str, Any] = {
            "user_id": user_id,
            "file_id": file_id,
            "job_id": job_id,
            "vendor_raw": model.vendor_name,
            "vendor_id": vendor_id,
            "invoice_number": model.invoice_number,
            "invoice_date": model.invoice_date.isoformat() if model.invoice_date else None,
            "due_date": model.due_date.isoformat() if model.due_date else None,
            "currency": model.currency,
            "total_amount": float(model.total_amount) if model.total_amount is not None else None,
            "subtotal": float(model.subtotal) if model.subtotal is not None else None,
            "tax_total": float(model.tax_total) if model.tax_total is not None else None,
            "line_items": line_items_json,
            "extraction": extraction_payload,
            "confidence": float(conf),
            "format_id": format_id,
            "duplicate_fingerprint": fp,
            "is_duplicate_candidate": is_dup_candidate,
            "is_duplicate_of": dup_of,
        }
        try:
            inv = insert_invoice(sb, modern_row)
        except APIError as e:
            if supabase_rest_schema_error(e):
                inv = insert_invoice(sb, legacy_row)
            else:
                raise

        try:
            if format_id and sim_score > 0:
                record_format_match(sb, inv["id"], format_id, float(sim_score))
                if not val_errors:
                    bump_format_success(sb, format_id, header_fingerprint(ocr_text))
        except APIError as e:
            if supabase_rest_schema_error(e):
                log.warning("invoice format metadata skipped: %s", e.message)
            else:
                raise

        finished = datetime.now(timezone.utc).isoformat()
        update_job(sb, job_id, status="completed", finished_at=finished)
    except Exception as e:
        log.exception("process_invoice failed: %s", e)
        update_job(
            sb,
            job_id,
            status="failed",
            error_message=str(e)[:2000],
            finished_at=datetime.now(timezone.utc).isoformat(),
        )
