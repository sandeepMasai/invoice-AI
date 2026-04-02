# Test Data (Validation Fixtures)

This folder contains **repo-friendly fixtures** for validating extraction and analytics flows **without committing PDFs**.

## Files

- `sample_invoices.json`: canonical structured expectations for a few representative invoices.
- `ocr_text/`: raw OCR text inputs used in prompts and unit-style validation.

## How to use

- Use `ocr_text/*.txt` as the `{OCR_TEXT}` input to the extractor prompt.
- Compare the model output to the matching object in `sample_invoices.json`.

## Notes

- These fixtures are intentionally small and human-readable.
- Amounts are normalized to numbers; currency uses ISO codes (e.g. `INR`, `USD`).

