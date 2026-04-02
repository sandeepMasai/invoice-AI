"""Supabase auth: validate access tokens via GET /auth/v1/user (no local JWT secret)."""

from typing import Annotated

import httpx
from fastapi import Depends, HTTPException, Request, status
from supabase import Client

from app.config import Settings, get_settings
from app.database import get_supabase
from app.schemas.auth_user import SupabaseUser
from app.utils.logging import get_logger

log = get_logger(__name__)

AUTH_USER_PATH = "/auth/v1/user"


def _extract_access_token(request: Request) -> str | None:
    """Bearer token from Authorization, or X-Supabase-Access-Token (dev-proxy fallback)."""
    auth = request.headers.get("Authorization") or request.headers.get("authorization")
    if auth:
        s = auth.strip()
        low = s.lower()
        if low.startswith("bearer "):
            t = s[7:].strip().strip('"').strip("'")
            if t:
                return t
        parts = s.split(None, 1)
        if len(parts) == 2 and parts[0].lower() == "bearer":
            t = parts[1].strip().strip('"').strip("'")
            if t:
                return t
    x = request.headers.get("X-Supabase-Access-Token") or request.headers.get(
        "x-supabase-access-token"
    )
    if x:
        return x.strip()
    return None


def _anon_api_key(settings: Settings) -> str:
    """Public anon key for apikey header (same as browser)."""
    key = settings.supabase_anon_key or settings.supabase_publishable_key
    if not key:
        log.error("SUPABASE_ANON_KEY (or SUPABASE_PUBLISHABLE_KEY) is required for token validation")
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Server authentication is not configured",
        )
    return key


async def get_current_user(
    request: Request,
    settings: Annotated[Settings, Depends(get_settings)],
) -> SupabaseUser:
    """
    Validate the Supabase access token by calling Auth API.
    Docs: Authorization: Bearer <access_token>, apikey: <anon key>
    """
    token = _extract_access_token(request)
    if not token:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing bearer token")

    url = f"{settings.supabase_url}{AUTH_USER_PATH}"

    apikey_candidates: list[str] = []
    # Prefer the public/browser key for normal operation.
    apikey_candidates.append(_anon_api_key(settings))
    # Fallback to service role if Supabase rejects the public apikey (can happen in some setups).
    apikey_candidates.append(settings.supabase_service_role_key)

    last_exc: Exception | None = None
    last_status: int | None = None
    last_body: str | None = None

    for i, apikey in enumerate(apikey_candidates):
        try:
            # Prevent accidental use of HTTP(S)_PROXY env vars in dev environments.
            # This avoids CONNECT/403 failures that can surface as "Could not reach authentication service".
            async with httpx.AsyncClient(timeout=20.0, trust_env=False) as client:
                response = await client.get(
                    url,
                    headers={
                        "Authorization": f"Bearer {token}",
                        "apikey": apikey,
                        "Accept": "application/json",
                    },
                )
        except httpx.HTTPError as exc:
            last_exc = exc
            last_status = None
            last_body = None
            log.warning(
                "Supabase auth/v1/user request failed (attempt %s/%s): %s (%s)",
                i + 1,
                len(apikey_candidates),
                exc,
                type(exc).__name__,
            )
            continue

        last_status = response.status_code
        last_body = (response.text or "")[:400]

        if response.status_code == status.HTTP_200_OK:
            try:
                payload = response.json()
            except ValueError:
                log.warning("auth/v1/user returned non-JSON body")
                raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token")

            try:
                return SupabaseUser.from_auth_response(payload)
            except ValueError:
                log.warning("auth/v1/user JSON missing id: keys=%s", list(payload.keys())[:10])
                raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token")

        # If the only problem is apikey rejection, retry with the next apikey.
        if response.status_code == status.HTTP_403_FORBIDDEN and i + 1 < len(apikey_candidates):
            log.warning("auth/v1/user apikey rejected (403); retrying with fallback apikey")
            continue

        # Anything else means the token is invalid or not authorized.
        log.debug("auth/v1/user rejected token: status=%s body=%s", response.status_code, last_body)
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token")

    # All attempts failed due to HTTP errors.
    if last_exc is not None:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Could not reach authentication service",
        ) from last_exc

    # Should be unreachable, but keep a safe fallback response.
    raise HTTPException(
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        detail=f"Could not reach authentication service (last_status={last_status})",
    )


async def get_current_user_id(
    user: Annotated[SupabaseUser, Depends(get_current_user)],
) -> str:
    """Backward-compatible dependency: same routes, only the Supabase user id string."""
    return user.id


def supabase_client(settings: Annotated[Settings, Depends(get_settings)]) -> Client:
    return get_supabase(settings)
