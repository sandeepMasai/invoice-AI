# Invoice AI

Upload invoices (PDF/images), run OCR + extraction, store structured results in Supabase, and view analytics in a React dashboard.

## System architecture

- **Frontend** (`frontend/`)
  - React + Vite
  - Uses Supabase Auth in-browser for login/session
  - Calls backend through Vite proxy (`/api`) in dev
- **Backend** (`backend/`)
  - FastAPI
  - Validates Supabase access tokens via `GET /auth/v1/user`
  - Upload endpoint stores files in Supabase Storage + metadata in `public.files`
  - Processing pipeline runs OCR + LLM extraction and inserts into `public.invoices`
  - Analytics endpoints read from Supabase views (with fallbacks to table scans when views/columns are missing)
- **Database** (`supabase/`)
  - Postgres + PostgREST (Supabase)
  - Core tables: `files`, `invoices`, `processing_jobs`, `vendors`, `vendor_aliases`
  - Optional tables for template reuse: `invoice_formats`, `invoice_format_matches`

## Key design decisions

- **Auth validation via Supabase**: backend does not decode JWT locally; it validates sessions by calling Supabase Auth (`/auth/v1/user`).
- **Schema drift tolerance**: backend catches common PostgREST errors (`PGRST205`, `42703`) and either:
  - returns a helpful 503 with migration guidance, or
  - falls back to safer/empty aggregations where possible (dashboard still renders).
- **PDF OCR strategy**: for PDFs, try text extraction first; if text is sparse, render pages to images and run Tesseract.
- **Duplicate detection**:
  - exact-file duplicate check via `files.sha256` (upload-time),
  - invoice-level fingerprint via vendor/number/date/total/currency (process-time).
- **Template reuse**: for repeat invoice layouts, match by header similarity and inject a reference snippet into the LLM context.

## Assumptions & limitations

- **LLM extraction requires a key**: without `OPENAI_API_KEY`, extraction returns a stub (null fields).
- **OCR quality varies**: low-resolution scans or complex layouts may produce incomplete OCR.
- **Supabase schema must match**: missing columns/tables can prevent full processing. Use the repair SQL below.
- **No committed PDFs**: the repo includes text-based fixtures only (see `testdata/`).

## Potential improvements

- Use embeddings (pgvector + OpenAI embeddings) for more robust format similarity.
- Add a job status UI that polls `/jobs/:id` and updates the dashboard only when processing completes.
- Add better currency/date normalization (locale-aware).
- Add a deterministic parser for common invoice templates to reduce LLM calls.

## Setup

### 1) Environment

Copy `.env.example` to `.env` and fill:

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY` (backend only)
- `OPENAI_API_KEY` (required for non-null extraction)

### 2) Supabase schema

Run the repair script in Supabase SQL Editor:

- `supabase/scripts/fix_pgrst205_everything_needed_by_backend.sql`

This creates/aligns:
- Storage bucket `invoices`
- `public.files`, `public.invoices`, `public.processing_jobs`, `public.vendors`, `public.vendor_aliases`
- Analytics views + RPC
- Optional template tables: `public.invoice_formats`, `public.invoice_format_matches`
- Reloads PostgREST schema cache

### 3) Run backend

```bash
cd backend
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
./start-backend.sh 8003
```

### 4) Run frontend

```bash
cd frontend
npm install
npm run dev
```

Open `http://localhost:5173`.

## Test data (sample invoices)

See `testdata/` for OCR text fixtures + expected JSON outputs used for validation.
