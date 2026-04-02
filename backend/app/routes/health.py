from fastapi import APIRouter, Depends
from supabase import Client

from app.dependencies import get_current_user, supabase_client
from app.schemas.auth_user import SupabaseUser

router = APIRouter(tags=["health"])


@router.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@router.get("/me", summary="Example protected route (current Supabase user)")
async def whoami(user: SupabaseUser = Depends(get_current_user)) -> dict[str, str | None]:
    return {"id": user.id, "email": user.email}


@router.get("/ready")
def ready(sb: Client = Depends(supabase_client)) -> dict[str, str]:
    try:
        sb.table("profiles").select("id").limit(1).execute()
        return {"status": "ready"}
    except Exception:
        return {"status": "not_ready"}
