import json
from typing import Any

from openai import OpenAI

from app.config import Settings
from app.utils.logging import get_logger

log = get_logger(__name__)

SYSTEM_PROMPT = """You extract structured invoice data from OCR text. Return ONLY valid JSON matching this shape:
{
  "vendor_name": string|null,
  "invoice_number": string|null,
  "invoice_date": string|null (ISO date YYYY-MM-DD if known),
  "due_date": string|null,
  "currency": string|null (ISO 4217 if known, else null),
  "subtotal": number|null,
  "tax_total": number|null,
  "total_amount": number|null,
  "line_items": [{"description": string|null, "quantity": number|null, "unit_price": number|null, "amount": number|null, "sku": string|null}]
}
Use null for unknown fields. Do not invent totals; if unclear, leave numbers null."""


def extract_invoice_json(
    settings: Settings,
    ocr_text: str,
    template_hints: dict[str, Any] | None = None,
) -> dict[str, Any]:
    if not settings.openai_api_key:
        log.warning("OPENAI_API_KEY missing; returning stub extraction")
        return {
            "vendor_name": None,
            "invoice_number": None,
            "invoice_date": None,
            "due_date": None,
            "currency": None,
            "subtotal": None,
            "tax_total": None,
            "total_amount": None,
            "line_items": [],
            "_stub": True,
        }

    client = OpenAI(api_key=settings.openai_api_key)
    hint_block = ""
    if template_hints:
        hint_block = "\nKnown layout hints (may help):\n" + json.dumps(template_hints, indent=2)[:4000]

    user_content = f"OCR text:\n{ocr_text[:12000]}\n{hint_block}"

    def call(messages: list[dict[str, str]]) -> str:
        resp = client.chat.completions.create(
            model=settings.openai_model,
            messages=messages,
            response_format={"type": "json_object"},
            temperature=0.1,
        )
        return resp.choices[0].message.content or "{}"

    raw = call(
        [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": user_content},
        ]
    )
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        log.warning("LLM JSON parse failed, retrying repair")
        repair = call(
            [
                {"role": "system", "content": "Return only fixed valid JSON object. No markdown."},
                {"role": "user", "content": f"Fix this to valid JSON only:\n{raw[:8000]}"},
            ]
        )
        return json.loads(repair)
