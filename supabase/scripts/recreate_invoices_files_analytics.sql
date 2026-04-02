-- =============================================================================
-- Standalone reset: invoices + files + analytics_summary
-- Run in Supabase → SQL Editor when an old `invoices` / `files` shape causes 42703.
-- WARNING: Drops data in public.invoices and public.files (CASCADE).
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Drop dependent objects first (views, then child table, then parent)
DROP VIEW IF EXISTS public.analytics_summary CASCADE;

DROP TABLE IF EXISTS public.invoices CASCADE;
DROP TABLE IF EXISTS public.files CASCADE;

-- -----------------------------------------------------------------------------
-- files
-- -----------------------------------------------------------------------------
CREATE TABLE public.files (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  file_url TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_files_user_id ON public.files (user_id);
CREATE INDEX IF NOT EXISTS idx_files_user_created ON public.files (user_id, created_at DESC);

ALTER TABLE public.files ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "files_all_own" ON public.files;
CREATE POLICY "files_all_own"
  ON public.files
  FOR ALL
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

GRANT ALL ON TABLE public.files TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- invoices
-- -----------------------------------------------------------------------------
CREATE TABLE public.invoices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  file_id UUID NOT NULL REFERENCES public.files (id) ON DELETE CASCADE,
  vendor_name TEXT,
  invoice_date DATE,
  total_amount NUMERIC(18, 4),
  currency TEXT,
  json_data JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_invoices_user_id ON public.invoices (user_id);
CREATE INDEX IF NOT EXISTS idx_invoices_file_id ON public.invoices (file_id);
CREATE INDEX IF NOT EXISTS idx_invoices_user_created ON public.invoices (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_invoices_json_data ON public.invoices USING gin (json_data);

ALTER TABLE public.invoices ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "invoices_all_own" ON public.invoices;
CREATE POLICY "invoices_all_own"
  ON public.invoices
  FOR ALL
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

GRANT ALL ON TABLE public.invoices TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- analytics_summary: aggregates per user + vendor (+ currency)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.analytics_summary AS
SELECT
  i.user_id,
  COALESCE(NULLIF(trim(i.vendor_name), ''), 'Unknown') AS vendor_name,
  COALESCE(i.currency, 'UNKNOWN') AS currency,
  COUNT(*)::bigint AS invoice_count,
  SUM(COALESCE(i.total_amount, 0))::numeric(18, 4) AS total_spend,
  MAX(i.invoice_date) AS latest_invoice_date
FROM public.invoices i
GROUP BY
  i.user_id,
  COALESCE(NULLIF(trim(i.vendor_name), ''), 'Unknown'),
  COALESCE(i.currency, 'UNKNOWN');

GRANT SELECT ON public.analytics_summary TO authenticated, service_role;

-- Refresh PostgREST schema cache
NOTIFY pgrst, 'reload schema';
