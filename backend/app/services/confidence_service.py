from decimal import Decimal

from app.schemas.invoice import InvoiceExtraction


def score_confidence(
    model: InvoiceExtraction,
    validation_errors: list[str],
    ocr_char_count: int,
    template_matched: bool,
) -> float:
    score = 0.65
    if model.vendor_name:
        score += 0.08
    if model.invoice_number:
        score += 0.06
    if model.invoice_date:
        score += 0.06
    if model.total_amount is not None:
        score += 0.07
    if model.line_items:
        score += min(0.05, 0.01 * len(model.line_items))
    if template_matched:
        score += 0.05
    if ocr_char_count > 200:
        score += 0.03
    score -= 0.06 * min(len(validation_errors), 4)
    return max(0.0, min(1.0, round(score, 4)))
