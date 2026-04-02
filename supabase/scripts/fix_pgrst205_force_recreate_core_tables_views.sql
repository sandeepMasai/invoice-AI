-- =============================================================================
-- Force recreate core tables + analytics views to fix PGRST205.
--
-- This is a destructive fix (drops public.invoices + public.files).
-- Use it when schema cache keeps claiming the relations are missing.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- -----------------------------------------------------------------------------
-- Storage bucket: backend uses bucket_id = 'invoices'
-- -----------------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'invoices',
  'invoices',
  false,
  52428800,
  ARRAY['application/pdf', 'image/png', 'image/jpeg', 'image/jpg', 'image/webp']::text[]
)
ON CONFLICT (id) DO UPDATE SET
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types,
  public = EXCLUDED.public,
  name = EXCLUDED.name;

ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "invoices_storage_select_own" ON storage.objects;
DROP POLICY IF EXISTS "invoices_storage_insert_own" ON storage.objects;
DROP POLICY IF EXISTS "invoices_storage_update_own" ON storage.objects;
DROP POLICY IF EXISTS "invoices_storage_delete_own" ON storage.objects;

CREATE POLICY "invoices_storage_select_own"
  ON storage.objects FOR SELECT
  USING (
    bucket_id = 'invoices'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

CREATE POLICY "invoices_storage_insert_own"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'invoices'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

CREATE POLICY "invoices_storage_update_own"
  ON storage.objects FOR UPDATE
  USING (
    bucket_id = 'invoices'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

CREATE POLICY "invoices_storage_delete_own"
  ON storage.objects FOR DELETE
  USING (
    bucket_id = 'invoices'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- -----------------------------------------------------------------------------
-- Drop dependent analytics views first
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS public.analytics_monthly_spend CASCADE;
DROP VIEW IF EXISTS public.analytics_vendor_totals CASCADE;
DROP VIEW IF EXISTS public.analytics_currency_totals CASCADE;

-- Drop core tables (data loss for these tables)
DROP TABLE IF EXISTS public.invoices CASCADE;
DROP TABLE IF EXISTS public.files CASCADE;

-- -----------------------------------------------------------------------------
-- public.files
-- -----------------------------------------------------------------------------
CREATE TABLE public.files (
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

CREATE INDEX idx_files_user_id ON public.files (user_id);
CREATE INDEX idx_files_created_at ON public.files (user_id, created_at DESC);

ALTER TABLE public.files ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "files_all_own" ON public.files;
CREATE POLICY "files_all_own"
  ON public.files FOR ALL
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());
GRANT ALL ON public.files TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- public.invoices
-- -----------------------------------------------------------------------------
CREATE TABLE public.invoices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  file_id UUID REFERENCES public.files (id) ON DELETE CASCADE,
  job_id UUID,

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

CREATE INDEX idx_invoices_user_date ON public.invoices (user_id, invoice_date DESC);
CREATE INDEX idx_invoices_user_vendor ON public.invoices (user_id, vendor_id);
CREATE INDEX idx_invoices_duplicate_fp ON public.invoices (user_id, duplicate_fingerprint)
  WHERE duplicate_fingerprint IS NOT NULL;

ALTER TABLE public.invoices ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "invoices_all_own" ON public.invoices;
CREATE POLICY "invoices_all_own"
  ON public.invoices FOR ALL
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());
GRANT ALL ON public.invoices TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Analytics views (no vendors JOIN)
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
  COALESCE(NULLIF(btrim(COALESCE(i.vendor_name, i.vendor_raw, '')), ''), 'Unknown') AS vendor_display,
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

-- RPC functions (optional for backend, but keeps RPC working)
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
-- Final verification + reload PostgREST
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  missing TEXT := '';
BEGIN
  IF to_regclass('public.invoices') IS NULL THEN missing := missing || ' public.invoices'; END IF;
  IF to_regclass('public.files') IS NULL THEN missing := missing || ' public.files'; END IF;
  IF to_regclass('public.analytics_monthly_spend') IS NULL THEN missing := missing || ' public.analytics_monthly_spend'; END IF;
  IF to_regclass('public.analytics_vendor_totals') IS NULL THEN missing := missing || ' public.analytics_vendor_totals'; END IF;
  IF to_regclass('public.analytics_currency_totals') IS NULL THEN missing := missing || ' public.analytics_currency_totals'; END IF;
  IF missing <> '' THEN
    RAISE EXCEPTION 'PGRST205 force recreate incomplete. Missing:%s', missing;
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
SELECT pg_notify('pgrst', 'reload schema');

