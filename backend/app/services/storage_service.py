import re
import uuid


def sanitize_filename(name: str) -> str:
    base = name.split("/")[-1] or "file"
    return re.sub(r"[^a-zA-Z0-9._-]", "_", base)[:200]


def build_storage_path(user_id: str, original_filename: str) -> str:
    return f"{user_id}/{uuid.uuid4().hex}_{sanitize_filename(original_filename)}"
