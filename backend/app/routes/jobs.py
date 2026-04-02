from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status
from supabase import Client

from app.database import get_job
from app.dependencies import get_current_user_id, supabase_client
from app.schemas.invoice import JobStatusResponse

router = APIRouter(prefix="/jobs", tags=["jobs"])


@router.get("/{job_id}", response_model=JobStatusResponse)
def job_status(
    job_id: UUID,
    user_id: str = Depends(get_current_user_id),
    sb: Client = Depends(supabase_client),
) -> JobStatusResponse:
    row = get_job(sb, str(job_id), user_id)
    if not row:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Job not found")
    return JobStatusResponse(
        id=row["id"],
        file_id=row["file_id"],
        status=str(row["status"]),
        attempt_count=int(row.get("attempt_count") or 0),
        error_message=row.get("error_message"),
        started_at=str(row["started_at"]) if row.get("started_at") else None,
        finished_at=str(row["finished_at"]) if row.get("finished_at") else None,
    )
