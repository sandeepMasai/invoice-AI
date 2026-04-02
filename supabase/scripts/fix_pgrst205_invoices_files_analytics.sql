-- =============================================================================
-- Fix PGRST205 (table/view not found) for analytics
-- =============================================================================
-- Run in Supabase SQL Editor against your target project.
--
-- What this script does (idempotent):
-- 1. Ensures `public.files` exists with columns used by the backend/worker.
-- 2. Ensures `public.invoices` exists with columns required by analytics views.
-- 3. Creates/replaces:
--    - public.analytics_monthly_spend
--    - public.analytics_vendor_totals
--    - public.analytics_currency_totals
-- 4. Creates/replaces RPC functions that use those views.
-- 5. Grants SELECT/EXECUTE to `authenticated` and `service_role`.
-- 6. Reloads PostgREST schema cache via `NOTIFY pgrst, 'reload schema'`.
--
-- NOTE: If you have an existing `public.invoices` table with incompatible column
--       types/PK, you may need a clean reset. This script focuses on the common
--       "table exists but columns missing" case.
-- =============================================================================

-- Ensure UUID generator exists
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- -----------------------------------------------------------------------------
-- public.files
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.files (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  file_url TEXT,
  storage_path TEXT,
  mime_type TEXT,
  original_filename TEXT,
  byte_size BIGINT,
  sha256 TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Add missing columns if `files` already exists with partial schema
ALTER TABLE public.files ADD COLUMN IF NOT EXISTS file_url TEXT;
ALTER TABLE public.files ADD COLUMN IF NOT EXISTS storage_path TEXT;
ALTER TABLE public.files ADD COLUMN IF NOT EXISTS mime_type TEXT;
ALTER TABLE public.files ADD COLUMN IF NOT EXISTS original_filename TEXT;
ALTER TABLE public.files ADD COLUMN IF NOT EXISTS byte_size BIGINT;
ALTER TABLE public.files ADD COLUMN IF NOT EXISTS sha256 TEXT;
ALTER TABLE public.files ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now();

-- Indexes
CREATE INDEX IF NOT EXISTS idx_files_user_id ON public.files (user_id);
CREATE INDEX IF NOT EXISTS idx_files_created_at ON public.files (user_id, created_at DESC);

-- RLS
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

  -- Vendor fields (needed by analytics views; backend also supports legacy vendor_raw)
  vendor_name TEXT,
  vendor_raw TEXT,
  vendor_id UUID,

  -- Invoice fields (needed by analytics views)
  invoice_number TEXT,
  invoice_date DATE,
  due_date DATE,
  currency TEXT,
  total_amount NUMERIC(18, 4),
  subtotal NUMERIC(18, 4),
  tax_total NUMERIC(18, 4),

  -- Structured payload (backend supports json_data OR legacy `line_items`/`extraction`)
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

-- Add missing columns if `invoices` already exists with partial schema
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS user_id UUID;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS file_id UUID;

ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS vendor_name TEXT;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS vendor_raw TEXT;
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

-- Indexes (match common initial migration intent)
CREATE INDEX IF NOT EXISTS idx_invoices_user_date ON public.invoices (user_id, invoice_date DESC);
CREATE INDEX IF NOT EXISTS idx_invoices_user_vendor ON public.invoices (user_id, vendor_id);
CREATE INDEX IF NOT EXISTS idx_invoices_duplicate_fp ON public.invoices (user_id, duplicate_fingerprint)
  WHERE duplicate_fingerprint IS NOT NULL;

-- RLS
ALTER TABLE public.invoices ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "invoices_all_own" ON public.invoices;
CREATE POLICY "invoices_all_own"
  ON public.invoices FOR ALL
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

GRANT ALL ON TABLE public.invoices TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Analytics views + RPC functions (no JOIN on public.vendors)
-- This avoids the earlier 42P01 "vendors" relation missing problem.
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

-- RPC functions
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

-- Grants
GRANT SELECT ON public.analytics_monthly_spend TO authenticated, service_role;
GRANT SELECT ON public.analytics_vendor_totals TO authenticated, service_role;
GRANT SELECT ON public.analytics_currency_totals TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.rpc_analytics_monthly() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_analytics_vendors(int) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_analytics_currencies() TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Verify + reload PostgREST schema cache
-- -----------------------------------------------------------------------------
NOTIFY pgrst, 'reload schema';

-- Lightweight verification output (optional)
-- SELECT to_regclass('public.invoices') AS invoices_table;
-- SELECT to_regclass('public.files') AS files_table;
-- SELECT to_regclass('public.analytics_monthly_spend') AS analytics_monthly_spend_view;

