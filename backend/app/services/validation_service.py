from decimal import Decimal
from typing import Any

from pydantic import ValidationError

from app.schemas.invoice import InvoiceExtraction
from app.utils.logging import get_logger

log = get_logger(__name__)


def validate_extraction(raw: dict[str, Any]) -> tuple[InvoiceExtraction, list[str]]:
    errors: list[str] = []
    try:
        model = InvoiceExtraction.model_validate(raw)
    except ValidationError as e:
        for err in e.errors():
            errors.append(f"{err['loc']}: {err['msg']}")
        model = InvoiceExtraction(
            vendor_name=raw.get("vendor_name") if isinstance(raw.get("vendor_name"), str) else None,
            invoice_number=raw.get("invoice_number") if isinstance(raw.get("invoice_number"), str) else None,
            invoice_date=None,
            due_date=None,
            currency=raw.get("currency") if isinstance(raw.get("currency"), str) else None,
            subtotal=None,
            tax_total=None,
            total_amount=None,
            line_items=[],
        )

    if model.total_amount is not None and model.line_items:
        summed = Decimal("0")
        for li in model.line_items:
            if li.amount is not None:
                summed += li.amount
        if summed > 0 and model.total_amount:
            diff = abs(model.total_amount - summed)
            tol = max(Decimal("0.05") * model.total_amount, Decimal("2"))
            if diff > tol:
                errors.append(
                    f"Line items sum {summed} differs from total {model.total_amount} beyond tolerance"
                )

    return model, errors
