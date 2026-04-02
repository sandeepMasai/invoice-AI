"""User payload from Supabase GET /auth/v1/user."""

from pydantic import BaseModel, ConfigDict, Field


class SupabaseUser(BaseModel):
    """Subset of Supabase Auth User JSON (extend as needed)."""

    model_config = ConfigDict(extra="ignore")

    id: str
    email: str | None = None
    phone: str | None = None
    role: str | None = None
    app_metadata: dict = Field(default_factory=dict)
    user_metadata: dict = Field(default_factory=dict)

    @classmethod
    def from_auth_response(cls, data: dict) -> "SupabaseUser":
        uid = data.get("id")
        if uid is None:
            raise ValueError("missing user id")
        return cls.model_validate({**data, "id": str(uid)})
