-- =============================================================================
-- One-shot repair for Supabase PGRST205 (analytics) and common schema drift
-- for this Invoice AI backend.
--
-- Paste/run in Supabase SQL Editor.
-- Idempotent: uses IF NOT EXISTS / CREATE OR REPLACE / ALTER ... ADD COLUMN IF NOT EXISTS.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "vector";

-- -----------------------------------------------------------------------------
-- Storage bucket: backend uses settings.storage_bucket = "invoices"
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
-- vendors + vendor_aliases (used by worker/vendor normalization)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.vendors (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  normalized_name TEXT NOT NULL,
  display_name TEXT NOT NULL,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, normalized_name)
);

CREATE INDEX IF NOT EXISTS idx_vendors_user ON public.vendors (user_id);
CREATE INDEX IF NOT EXISTS idx_vendors_display_name_lower ON public.vendors (lower(display_name));

ALTER TABLE public.vendors ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "vendors_all_own" ON public.vendors;
CREATE POLICY "vendors_all_own"
  ON public.vendors FOR ALL
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

CREATE TABLE IF NOT EXISTS public.vendor_aliases (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES public.vendors (id) ON DELETE CASCADE,
  alias_text TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT 'rule' CHECK (source IN ('rule', 'llm', 'manual')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (vendor_id, alias_text)
);

CREATE INDEX IF NOT EXISTS idx_vendor_aliases_text ON public.vendor_aliases (lower(alias_text));

ALTER TABLE public.vendor_aliases ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "vendor_aliases_select" ON public.vendor_aliases;
DROP POLICY IF EXISTS "vendor_aliases_insert" ON public.vendor_aliases;
DROP POLICY IF EXISTS "vendor_aliases_update" ON public.vendor_aliases;
DROP POLICY IF EXISTS "vendor_aliases_delete" ON public.vendor_aliases;

CREATE POLICY "vendor_aliases_select"
  ON public.vendor_aliases FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.vendors v
      WHERE v.id = vendor_aliases.vendor_id AND v.user_id = auth.uid()
    )
  );

CREATE POLICY "vendor_aliases_insert"
  ON public.vendor_aliases FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.vendors v
      WHERE v.id = vendor_aliases.vendor_id AND v.user_id = auth.uid()
    )
  );

CREATE POLICY "vendor_aliases_update"
  ON public.vendor_aliases FOR UPDATE
  USING (
    EXISTS (
      SELECT 1 FROM public.vendors v
      WHERE v.id = vendor_aliases.vendor_id AND v.user_id = auth.uid()
    )
  );

CREATE POLICY "vendor_aliases_delete"
  ON public.vendor_aliases FOR DELETE
  USING (
    EXISTS (
      SELECT 1 FROM public.vendors v
      WHERE v.id = vendor_aliases.vendor_id AND v.user_id = auth.uid()
    )
  );

GRANT ALL ON TABLE public.vendors TO authenticated, service_role;
GRANT ALL ON TABLE public.vendor_aliases TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- public.files (upload/worker)
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

ALTER TABLE public.files ADD COLUMN IF NOT EXISTS storage_path TEXT;
ALTER TABLE public.files ADD COLUMN IF NOT EXISTS file_url TEXT;
ALTER TABLE public.files ADD COLUMN IF NOT EXISTS mime_type TEXT;
ALTER TABLE public.files ADD COLUMN IF NOT EXISTS original_filename TEXT;
ALTER TABLE public.files ADD COLUMN IF NOT EXISTS byte_size BIGINT;
ALTER TABLE public.files ADD COLUMN IF NOT EXISTS sha256 TEXT;

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
-- public.invoices (analytics/views/worker)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.invoices (
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

-- Add columns if an older table exists (id/type mismatches may still require manual reset)
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
-- public.processing_jobs (worker queue)
-- -----------------------------------------------------------------------------
-- `process` endpoint inserts a row here, then background worker updates status.
-- Missing this table makes the route fail with 503.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.processing_jobs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  file_id UUID NOT NULL REFERENCES public.files (id) ON DELETE CASCADE,

  status TEXT NOT NULL DEFAULT 'queued',
  attempt_count INT NOT NULL DEFAULT 0,
  error_message TEXT,
  started_at TIMESTAMPTZ,
  finished_at TIMESTAMPTZ,

  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.processing_jobs ADD COLUMN IF NOT EXISTS user_id UUID;
ALTER TABLE public.processing_jobs ADD COLUMN IF NOT EXISTS file_id UUID;
ALTER TABLE public.processing_jobs ADD COLUMN IF NOT EXISTS status TEXT;
ALTER TABLE public.processing_jobs ADD COLUMN IF NOT EXISTS attempt_count INT;
ALTER TABLE public.processing_jobs ADD COLUMN IF NOT EXISTS error_message TEXT;
ALTER TABLE public.processing_jobs ADD COLUMN IF NOT EXISTS started_at TIMESTAMPTZ;
ALTER TABLE public.processing_jobs ADD COLUMN IF NOT EXISTS finished_at TIMESTAMPTZ;
ALTER TABLE public.processing_jobs ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_processing_jobs_user ON public.processing_jobs (user_id);
CREATE INDEX IF NOT EXISTS idx_processing_jobs_file ON public.processing_jobs (file_id);
CREATE INDEX IF NOT EXISTS idx_processing_jobs_status ON public.processing_jobs (user_id, status);

ALTER TABLE public.processing_jobs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "processing_jobs_all_own" ON public.processing_jobs;
CREATE POLICY "processing_jobs_all_own"
  ON public.processing_jobs FOR ALL
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

GRANT ALL ON TABLE public.processing_jobs TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- invoice_formats + invoice_format_matches (optional; used for template matching)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.invoice_formats (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users (id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  embedding vector(1536),
  template_json JSONB NOT NULL DEFAULT '{}'::jsonb,
  sample_snippet TEXT,
  success_count INT NOT NULL DEFAULT 0,
  last_used_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_invoice_formats_user ON public.invoice_formats (user_id);

ALTER TABLE public.invoice_formats ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "formats_select" ON public.invoice_formats;
DROP POLICY IF EXISTS "formats_insert_own" ON public.invoice_formats;
DROP POLICY IF EXISTS "formats_update_own" ON public.invoice_formats;
DROP POLICY IF EXISTS "formats_delete_own" ON public.invoice_formats;

CREATE POLICY "formats_select"
  ON public.invoice_formats FOR SELECT
  USING (user_id IS NULL OR user_id = auth.uid());

CREATE POLICY "formats_insert_own"
  ON public.invoice_formats FOR INSERT
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "formats_update_own"
  ON public.invoice_formats FOR UPDATE
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "formats_delete_own"
  ON public.invoice_formats FOR DELETE
  USING (user_id = auth.uid());

GRANT ALL ON TABLE public.invoice_formats TO authenticated, service_role;

CREATE TABLE IF NOT EXISTS public.invoice_format_matches (
  invoice_id UUID NOT NULL REFERENCES public.invoices (id) ON DELETE CASCADE,
  format_id UUID NOT NULL REFERENCES public.invoice_formats (id) ON DELETE CASCADE,
  score FLOAT8,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (invoice_id, format_id)
);

ALTER TABLE public.invoice_format_matches ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "invoice_format_matches_all" ON public.invoice_format_matches;
CREATE POLICY "invoice_format_matches_all"
  ON public.invoice_format_matches FOR ALL
  USING (true)
  WITH CHECK (true);

GRANT ALL ON TABLE public.invoice_format_matches TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Analytics views (NO JOIN on vendors to avoid PGRST205/42P01 issues)
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS public.analytics_monthly_spend CASCADE;
DROP VIEW IF EXISTS public.analytics_vendor_totals CASCADE;
DROP VIEW IF EXISTS public.analytics_currency_totals CASCADE;

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

-- RPC functions (use views above)
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
-- Hard verification: ensure required relations exist
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  missing TEXT := '';
BEGIN
  IF to_regclass('public.files') IS NULL THEN
    missing := missing || ' public.files';
  END IF;
  IF to_regclass('public.invoices') IS NULL THEN
    missing := missing || ' public.invoices';
  END IF;
  IF to_regclass('public.processing_jobs') IS NULL THEN
    missing := missing || ' public.processing_jobs';
  END IF;
  IF to_regclass('public.invoice_formats') IS NULL THEN
    missing := missing || ' public.invoice_formats';
  END IF;
  IF to_regclass('public.invoice_format_matches') IS NULL THEN
    missing := missing || ' public.invoice_format_matches';
  END IF;
  IF to_regclass('public.analytics_monthly_spend') IS NULL THEN
    missing := missing || ' public.analytics_monthly_spend';
  END IF;
  IF to_regclass('public.analytics_vendor_totals') IS NULL THEN
    missing := missing || ' public.analytics_vendor_totals';
  END IF;
  IF to_regclass('public.analytics_currency_totals') IS NULL THEN
    missing := missing || ' public.analytics_currency_totals';
  END IF;

  IF missing <> '' THEN
    RAISE EXCEPTION 'PGRST205 repair incomplete. Missing:%s', missing;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- Reload PostgREST schema cache
-- -----------------------------------------------------------------------------
-- Some projects respond better to one form than the other; run both.
NOTIFY pgrst, 'reload schema';
SELECT pg_notify('pgrst', 'reload schema');

