-- Repair: legacy or third-party `public.invoices` tables often lack `user_id` and other
-- columns expected by Invoice AI (PostgREST 42703). This migration adds missing columns
-- and constraints idempotently.
--
-- Prereq: `public.invoices` must already exist (from an older app or a partial deploy).
-- Greenfield: run 20250401000001_initial.sql only — it creates `invoices` with the full shape.
-- Hybrid: run 01 first (creates files, jobs, …), then this file if `invoices` predates 01 or is wrong.

DO $$
BEGIN
  IF to_regclass('public.invoices') IS NULL THEN
    RAISE EXCEPTION
      'public.invoices does not exist. Apply supabase/migrations/20250401000001_initial.sql first, then re-run this migration if you still need column repairs.';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- Add missing columns (nullable where legacy rows may exist; app enforces on new rows)
-- -----------------------------------------------------------------------------
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS user_id UUID;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS file_id UUID;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS job_id UUID;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS vendor_raw TEXT;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS vendor_id UUID;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS invoice_number TEXT;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS invoice_date DATE;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS due_date DATE;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS currency TEXT;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS total_amount NUMERIC(18, 4);
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS subtotal NUMERIC(18, 4);
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS tax_total NUMERIC(18, 4);
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS line_items JSONB NOT NULL DEFAULT '[]';
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS extraction JSONB NOT NULL DEFAULT '{}';
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS confidence NUMERIC(5, 4);
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS format_id UUID;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS duplicate_fingerprint TEXT;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS is_duplicate_candidate BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS is_duplicate_of UUID;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now();

-- Self-FK for is_duplicate_of
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    WHERE t.relname = 'invoices' AND c.conname = 'invoices_is_duplicate_of_fkey'
  ) THEN
    ALTER TABLE public.invoices
      ADD CONSTRAINT invoices_is_duplicate_of_fkey
      FOREIGN KEY (is_duplicate_of) REFERENCES public.invoices (id) ON DELETE SET NULL NOT VALID;
  END IF;
END $$;

-- FK to auth.users (NOT VALID so existing NULL user_id rows do not block migration)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    WHERE t.relname = 'invoices' AND c.conname = 'invoices_user_id_fkey'
  ) THEN
    ALTER TABLE public.invoices
      ADD CONSTRAINT invoices_user_id_fkey
      FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT VALID;
  END IF;
END $$;

-- FK to files
DO $$
BEGIN
  IF to_regclass('public.files') IS NOT NULL
     AND NOT EXISTS (
       SELECT 1 FROM pg_constraint c
       JOIN pg_class t ON t.oid = c.conrelid
       WHERE t.relname = 'invoices' AND c.conname = 'invoices_file_id_fkey'
     ) THEN
    ALTER TABLE public.invoices
      ADD CONSTRAINT invoices_file_id_fkey
      FOREIGN KEY (file_id) REFERENCES public.files (id) ON DELETE CASCADE NOT VALID;
  END IF;
END $$;

-- FK to processing_jobs
DO $$
BEGIN
  IF to_regclass('public.processing_jobs') IS NOT NULL
     AND NOT EXISTS (
       SELECT 1 FROM pg_constraint c
       JOIN pg_class t ON t.oid = c.conrelid
       WHERE t.relname = 'invoices' AND c.conname = 'invoices_job_id_fkey'
     ) THEN
    ALTER TABLE public.invoices
      ADD CONSTRAINT invoices_job_id_fkey
      FOREIGN KEY (job_id) REFERENCES public.processing_jobs (id) ON DELETE SET NULL NOT VALID;
  END IF;
END $$;

-- FK to vendors
DO $$
BEGIN
  IF to_regclass('public.vendors') IS NOT NULL
     AND NOT EXISTS (
       SELECT 1 FROM pg_constraint c
       JOIN pg_class t ON t.oid = c.conrelid
       WHERE t.relname = 'invoices' AND c.conname = 'invoices_vendor_id_fkey'
     ) THEN
    ALTER TABLE public.invoices
      ADD CONSTRAINT invoices_vendor_id_fkey
      FOREIGN KEY (vendor_id) REFERENCES public.vendors (id) ON DELETE SET NULL NOT VALID;
  END IF;
END $$;

-- FK to invoice_formats
DO $$
BEGIN
  IF to_regclass('public.invoice_formats') IS NOT NULL
     AND NOT EXISTS (
       SELECT 1 FROM pg_constraint c
       JOIN pg_class t ON t.oid = c.conrelid
       WHERE t.relname = 'invoices' AND c.conname = 'invoices_format_id_fkey'
     ) THEN
    ALTER TABLE public.invoices
      ADD CONSTRAINT invoices_format_id_fkey
      FOREIGN KEY (format_id) REFERENCES public.invoice_formats (id) ON DELETE SET NULL NOT VALID;
  END IF;
END $$;

-- Indexes (match initial migration)
CREATE INDEX IF NOT EXISTS idx_invoices_user_date ON public.invoices (user_id, invoice_date DESC);
CREATE INDEX IF NOT EXISTS idx_invoices_user_vendor ON public.invoices (user_id, vendor_id);
CREATE INDEX IF NOT EXISTS idx_invoices_duplicate_fp ON public.invoices (user_id, duplicate_fingerprint)
  WHERE duplicate_fingerprint IS NOT NULL;

-- RLS + policy (idempotent)
ALTER TABLE public.invoices ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "invoices_all_own" ON public.invoices;
CREATE POLICY "invoices_all_own"
  ON public.invoices FOR ALL
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- Analytics views (same as 20250401000002; OR REPLACE if invoices now has user_id)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.analytics_monthly_spend AS
SELECT
  i.user_id,
  date_trunc('month', i.invoice_date AT TIME ZONE 'UTC')::date AS month,
  COALESCE(i.currency, 'UNKNOWN') AS currency,
  SUM(COALESCE(i.total_amount, 0)) AS total_spend,
  COUNT(*)::bigint AS invoice_count
FROM public.invoices i
WHERE i.invoice_date IS NOT NULL
GROUP BY i.user_id, 2, 3;

CREATE OR REPLACE VIEW public.analytics_vendor_totals AS
SELECT
  i.user_id,
  COALESCE(i.vendor_id::text, 'raw:' || COALESCE(i.vendor_name, i.vendor_raw, '')) AS vendor_key,
  i.vendor_id,
  COALESCE(i.vendor_name, i.vendor_raw) AS vendor_raw,
  COALESCE(
    NULLIF(btrim(COALESCE(i.vendor_name, i.vendor_raw, '')), ''),
    'Unknown'
  ) AS vendor_display,
  COALESCE(i.currency, 'UNKNOWN') AS currency,
  SUM(COALESCE(i.total_amount, 0)) AS total_spend,
  COUNT(*)::bigint AS invoice_count
FROM public.invoices i
GROUP BY
  i.user_id,
  i.vendor_id,
  COALESCE(i.vendor_name, i.vendor_raw),
  i.currency;

CREATE OR REPLACE VIEW public.analytics_currency_totals AS
SELECT
  i.user_id,
  COALESCE(i.currency, 'UNKNOWN') AS currency,
  SUM(COALESCE(i.total_amount, 0)) AS total_spend,
  COUNT(*)::bigint AS invoice_count
FROM public.invoices i
GROUP BY i.user_id, 2;

GRANT SELECT ON public.analytics_monthly_spend TO authenticated, service_role;
GRANT SELECT ON public.analytics_vendor_totals TO authenticated, service_role;
GRANT SELECT ON public.analytics_currency_totals TO authenticated, service_role;

-- RPC helpers (same as 20250401000002_analytics.sql)
CREATE OR REPLACE FUNCTION public.rpc_analytics_monthly()
RETURNS TABLE (
  month date,
  currency text,
  total_spend numeric,
  invoice_count bigint
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT
    a.month,
    a.currency,
    a.total_spend,
    a.invoice_count
  FROM public.analytics_monthly_spend a
  WHERE a.user_id = auth.uid()
  ORDER BY a.month DESC, a.currency;
$$;

CREATE OR REPLACE FUNCTION public.rpc_analytics_vendors(p_limit int DEFAULT 50)
RETURNS TABLE (
  vendor_key text,
  vendor_display text,
  currency text,
  total_spend numeric,
  invoice_count bigint
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT
    a.vendor_key,
    a.vendor_display,
    a.currency,
    a.total_spend,
    a.invoice_count
  FROM public.analytics_vendor_totals a
  WHERE a.user_id = auth.uid()
  ORDER BY a.total_spend DESC NULLS LAST
  LIMIT COALESCE(p_limit, 50);
$$;

CREATE OR REPLACE FUNCTION public.rpc_analytics_currencies()
RETURNS TABLE (
  currency text,
  total_spend numeric,
  invoice_count bigint
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT
    a.currency,
    a.total_spend,
    a.invoice_count
  FROM public.analytics_currency_totals a
  WHERE a.user_id = auth.uid()
  ORDER BY a.total_spend DESC NULLS LAST;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_analytics_monthly() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_analytics_vendors(int) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_analytics_currencies() TO authenticated, service_role;

-- Refresh PostgREST schema cache (Supabase)
NOTIFY pgrst, 'reload schema';
