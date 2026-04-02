-- =============================================================================
-- Fix PGRST205: missing table/view in PostgREST schema cache (analytics)
-- =============================================================================
-- Paste/run in Supabase SQL Editor (against the same project your backend uses).
--
-- Goals:
-- - Ensure tables exist: public.files, public.invoices
-- - Ensure analytics views exist:
--     public.analytics_monthly_spend
--     public.analytics_vendor_totals
--     public.analytics_currency_totals
-- - Ensure RPC functions exist and are granted
-- - Reload PostgREST schema cache
--
-- Idempotent: uses IF NOT EXISTS / CREATE OR REPLACE and ALTER ... ADD COLUMN IF NOT EXISTS.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- -----------------------------------------------------------------------------
-- public.files
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.files (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  storage_path TEXT,
  file_url TEXT,
  mime_type TEXT,
  original_filename TEXT,
  byte_size BIGINT,
  sha256 TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.files ADD COLUMN IF NOT EXISTS user_id UUID;
ALTER TABLE public.files ADD COLUMN IF NOT EXISTS storage_path TEXT;
ALTER TABLE public.files ADD COLUMN IF NOT EXISTS file_url TEXT;
ALTER TABLE public.files ADD COLUMN IF NOT EXISTS mime_type TEXT;
ALTER TABLE public.files ADD COLUMN IF NOT EXISTS original_filename TEXT;
ALTER TABLE public.files ADD COLUMN IF NOT EXISTS byte_size BIGINT;
ALTER TABLE public.files ADD COLUMN IF NOT EXISTS sha256 TEXT;
ALTER TABLE public.files ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now();

CREATE INDEX IF NOT EXISTS idx_files_user_id ON public.files (user_id);
CREATE INDEX IF NOT EXISTS idx_files_created_at ON public.files (user_id, created_at DESC);

ALTER TABLE public.files ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "files_all_own" ON public.files;
CREATE POLICY "files_all_own"
  ON public.files FOR ALL
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

GRANT ALL ON TABLE public.files TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- public.invoices
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.invoices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  file_id UUID REFERENCES public.files (id) ON DELETE CASCADE,
  job_id UUID,

  -- Vendor (app supports vendor_raw; some schemas use vendor_name)
  vendor_raw TEXT,
  vendor_name TEXT,
  vendor_id UUID,

  invoice_number TEXT,
  invoice_date DATE,
  due_date DATE,
  currency TEXT,
  total_amount NUMERIC(18, 4),
  subtotal NUMERIC(18, 4),
  tax_total NUMERIC(18, 4),

  -- App supports json_data (modern) plus legacy columns line_items/extraction (or both).
  json_data JSONB NOT NULL DEFAULT '{}'::jsonb,
  line_items JSONB NOT NULL DEFAULT '[]'::jsonb,
  extraction JSONB NOT NULL DEFAULT '{}'::jsonb,

  confidence NUMERIC(5, 4),
  format_id UUID,
  duplicate_fingerprint TEXT,
  is_duplicate_candidate BOOLEAN NOT NULL DEFAULT false,
  is_duplicate_of UUID REFERENCES public.invoices (id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS user_id UUID;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS file_id UUID;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS job_id UUID;

ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS vendor_raw TEXT;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS vendor_name TEXT;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS vendor_id UUID;

ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS invoice_number TEXT;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS invoice_date DATE;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS due_date DATE;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS currency TEXT;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS total_amount NUMERIC(18, 4);
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS subtotal NUMERIC(18, 4);
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS tax_total NUMERIC(18, 4);

ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS json_data JSONB NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS line_items JSONB NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS extraction JSONB NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS confidence NUMERIC(5, 4);
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS format_id UUID;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS duplicate_fingerprint TEXT;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS is_duplicate_candidate BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS is_duplicate_of UUID;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now();

CREATE INDEX IF NOT EXISTS idx_invoices_user_date ON public.invoices (user_id, invoice_date DESC);
CREATE INDEX IF NOT EXISTS idx_invoices_user_vendor ON public.invoices (user_id, vendor_id);
CREATE INDEX IF NOT EXISTS idx_invoices_duplicate_fp ON public.invoices (user_id, duplicate_fingerprint)
  WHERE duplicate_fingerprint IS NOT NULL;

ALTER TABLE public.invoices ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "invoices_all_own" ON public.invoices;
CREATE POLICY "invoices_all_own"
  ON public.invoices FOR ALL
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

GRANT ALL ON TABLE public.invoices TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Analytics views (no JOIN on public.vendors to avoid 42P01)
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

-- Ensure previous (possibly broken) definitions are removed first
DROP VIEW IF EXISTS public.analytics_vendor_totals CASCADE;
DROP VIEW IF EXISTS public.analytics_currency_totals CASCADE;

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

-- -----------------------------------------------------------------------------
-- RPC functions
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- Verify (uncomment if you want quick checks)
-- -----------------------------------------------------------------------------
-- SELECT to_regclass('public.files') AS files_tbl;
-- SELECT to_regclass('public.invoices') AS invoices_tbl;
-- SELECT to_regclass('public.analytics_monthly_spend') AS analytics_monthly_spend_view;
-- SELECT to_regclass('public.analytics_vendor_totals') AS analytics_vendor_totals_view;
-- SELECT to_regclass('public.analytics_currency_totals') AS analytics_currency_totals_view;

-- Reload PostgREST schema cache (pg_notify is the most reliable)
SELECT pg_notify('pgrst', 'reload schema');

