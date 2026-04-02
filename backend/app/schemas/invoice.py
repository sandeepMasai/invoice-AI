from datetime import date
from decimal import Decimal
from typing import Any
from uuid import UUID

from pydantic import BaseModel, Field, field_validator

from app.utils.dates_money import parse_decimal, parse_iso_date


class LineItem(BaseModel):
    description: str | None = None
    quantity: Decimal | None = None
    unit_price: Decimal | None = None
    amount: Decimal | None = None
    sku: str | None = None

    @field_validator("quantity", "unit_price", "amount", mode="before")
    @classmethod
    def coerce_decimal(cls, v: Any) -> Decimal | None:
        return parse_decimal(v)


class InvoiceExtraction(BaseModel):
    vendor_name: str | None = None
    invoice_number: str | None = None
    invoice_date: date | None = None
    due_date: date | None = None
    currency: str | None = "USD"
    subtotal: Decimal | None = None
    tax_total: Decimal | None = None
    total_amount: Decimal | None = None
    line_items: list[LineItem] = Field(default_factory=list)

    @field_validator("invoice_date", "due_date", mode="before")
    @classmethod
    def coerce_dates(cls, v: Any) -> date | None:
        return parse_iso_date(v)

    @field_validator("subtotal", "tax_total", "total_amount", mode="before")
    @classmethod
    def coerce_money(cls, v: Any) -> Decimal | None:
        return parse_decimal(v)


class FileUploadResponse(BaseModel):
    id: UUID
    storage_path: str
    mime_type: str
    original_filename: str
    byte_size: int


class ProcessInvoiceResponse(BaseModel):
    job_id: UUID
    status: str


class InvoiceSummary(BaseModel):
    id: UUID
    file_id: UUID
    vendor_raw: str | None
    invoice_number: str | None
    invoice_date: date | None
    currency: str | None
    total_amount: Decimal | None
    confidence: float | None
    is_duplicate_candidate: bool
    created_at: str


class InvoiceDetail(InvoiceSummary):
    due_date: date | None
    subtotal: Decimal | None
    tax_total: Decimal | None
    line_items: list[dict[str, Any]]
    extraction: dict[str, Any]
    format_id: UUID | None
    is_duplicate_of: UUID | None
    ocr_text: str | None = None


class InvoicePatchBody(BaseModel):
    extraction: dict[str, Any] | None = None
    vendor_raw: str | None = None
    invoice_number: str | None = None
    invoice_date: date | None = None
    due_date: date | None = None
    currency: str | None = None
    total_amount: Decimal | None = None
    line_items: list[dict[str, Any]] | None = None


class JobStatusResponse(BaseModel):
    id: UUID
    file_id: UUID
    status: str
    attempt_count: int
    error_message: str | None
    started_at: str | None
    finished_at: str | None
