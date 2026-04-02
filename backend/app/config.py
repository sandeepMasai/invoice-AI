from functools import lru_cache
from pathlib import Path

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

# Load backend/.env first, then repo-root .env (later wins) so one file can configure the whole stack.
_BACKEND_ROOT = Path(__file__).resolve().parent.parent
_REPO_ROOT = _BACKEND_ROOT.parent


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=(_BACKEND_ROOT / ".env", _REPO_ROOT / ".env"),
        env_file_encoding="utf-8",
        extra="ignore",
    )

    supabase_url: str = Field(..., alias="SUPABASE_URL")
    supabase_service_role_key: str = Field(..., alias="SUPABASE_SERVICE_ROLE_KEY")
    # Legacy anon JWT (or put the new publishable key here — same header the browser sends).
    supabase_anon_key: str | None = Field(default=None, alias="SUPABASE_ANON_KEY")
    # New Supabase keys (sb_publishable_… / sb_secret_…) — used for GET /auth/v1/user if set.
    supabase_publishable_key: str | None = Field(default=None, alias="SUPABASE_PUBLISHABLE_KEY")
    supabase_secret_key: str | None = Field(default=None, alias="SUPABASE_SECRET_KEY")
    # Optional legacy field; token auth uses GET /auth/v1/user + anon key only (not used for jwt.decode).
    supabase_jwt_secret: str | None = Field(default=None, alias="SUPABASE_JWT_SECRET")

    @field_validator(
        "supabase_jwt_secret",
        "supabase_anon_key",
        "supabase_publishable_key",
        "supabase_secret_key",
        mode="before",
    )
    @classmethod
    def empty_optional_secrets(cls, v: object) -> str | None:
        if v is None:
            return None
        if isinstance(v, str) and not v.strip():
            return None
        return str(v).strip() if isinstance(v, str) else None

    @field_validator("supabase_url", mode="after")
    @classmethod
    def normalize_supabase_url(cls, v: str) -> str:
        return v.rstrip("/")

    openai_api_key: str | None = Field(None, alias="OPENAI_API_KEY")
    openai_model: str = Field("gpt-4o-mini", alias="OPENAI_MODEL")

    frontend_url: str = Field("http://localhost:5173", alias="FRONTEND_URL")
    backend_url: str = Field("http://localhost:8000", alias="BACKEND_URL")

    use_vision_ocr: bool = Field(False, alias="USE_VISION_OCR")
    enable_batch: bool = Field(True, alias="ENABLE_BATCH")

    max_upload_mb: int = 50
    storage_bucket: str = "invoices"


@lru_cache
def get_settings() -> Settings:
    return Settings()


def clear_settings_cache() -> None:
    get_settings.cache_clear()
