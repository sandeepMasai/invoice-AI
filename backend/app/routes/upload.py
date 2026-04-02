from typing import Annotated

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile, status
from postgrest.exceptions import APIError
from supabase import Client

from app.config import Settings, get_settings
from app.database import insert_file_row
from app.dependencies import get_current_user_id, supabase_client
from app.schemas.invoice import FileUploadResponse
from app.services.storage_service import build_storage_path
from app.database import supabase_rest_schema_error
from app.utils.hashing import sha256_bytes

router = APIRouter(prefix="/upload", tags=["upload"])

ALLOWED = {
    "application/pdf",
    "image/png",
    "image/jpeg",
    "image/jpg",
    "image/webp",
}


async def _persist_upload(
    file: UploadFile,
    user_id: str,
    sb: Client,
    settings: Settings,
) -> FileUploadResponse:
    content_type = file.content_type or "application/octet-stream"
    if content_type not in ALLOWED:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Unsupported file type")

    data = await file.read()
    max_b = settings.max_upload_mb * 1024 * 1024
    if len(data) > max_b:
        raise HTTPException(status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, detail="File too large")

    path = build_storage_path(user_id, file.filename or "upload")
    digest = sha256_bytes(data)

    # Fast duplicate detection: if the exact same bytes were already uploaded by this user,
    # return the existing file row instead of re-uploading.
    try:
        existing = (
            sb.table("files")
            .select("*")
            .eq("user_id", user_id)
            .eq("sha256", digest)
            .order("created_at", desc=True)
            .limit(1)
            .execute()
        )
        if existing.data:
            row = existing.data[0]
            storage_path = row.get("file_url") or row.get("storage_path") or ""
            return FileUploadResponse(
                id=row["id"],
                storage_path=storage_path,
                mime_type=row.get("mime_type") or content_type,
                original_filename=row.get("original_filename") or (file.filename or "upload"),
                byte_size=int(row.get("byte_size") or len(data)),
            )
    except APIError as e:
        # Older schemas may not have sha256; ignore and continue.
        if not supabase_rest_schema_error(e):
            raise

    try:
        sb.storage.from_(settings.storage_bucket).upload(
            path,
            data,
            file_options={"content-type": content_type},
        )
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Storage upload failed: {e}") from e

    row = insert_file_row(
        sb,
        user_id=user_id,
        file_url=path,
        mime_type=content_type,
        original_filename=file.filename or "upload",
        byte_size=len(data),
        sha256=digest,
    )

    storage_path = row.get("file_url") or row.get("storage_path") or path
    return FileUploadResponse(
        id=row["id"],
        storage_path=storage_path,
        mime_type=row.get("mime_type") or content_type,
        original_filename=row.get("original_filename") or (file.filename or "upload"),
        byte_size=int(row.get("byte_size") or len(data)),
    )


@router.post("", response_model=FileUploadResponse)
async def upload_file(
    file: UploadFile = File(...),
    user_id: str = Depends(get_current_user_id),
    sb: Client = Depends(supabase_client),
    settings: Settings = Depends(get_settings),
) -> FileUploadResponse:
    return await _persist_upload(file, user_id, sb, settings)


@router.post("/batch", response_model=list[FileUploadResponse])
async def upload_batch(
    files: Annotated[list[UploadFile], File(...)],
    user_id: str = Depends(get_current_user_id),
    sb: Client = Depends(supabase_client),
    settings: Settings = Depends(get_settings),
) -> list[FileUploadResponse]:
    if not settings.enable_batch:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Batch upload disabled")
    if len(files) > 20:
        raise HTTPException(status_code=400, detail="Maximum 20 files per batch")
    out: list[FileUploadResponse] = []
    for f in files:
        out.append(await _persist_upload(f, user_id, sb, settings))
    return out
