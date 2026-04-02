-- =============================================================================
-- Fix: ERROR 42P01 — relation "public.vendors" does not exist
--
-- Cause: Views (e.g. analytics_vendor_totals) use:
--   LEFT JOIN public.vendors v ON v.id = i.vendor_id
-- If `vendors` was never created (partial migration / custom DB), the view fails.
--
-- Run ONE of the options below in Supabase SQL Editor (not both unless you want
-- the table AND the no-join view — usually pick A OR B).
--
-- OPTION A (recommended): Create `public.vendors` so JOINs and vendor normalization work.
-- OPTION B (quick): Replace analytics views so they never reference `public.vendors`.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- =============================================================================
-- OPTION A — Create `public.vendors` (scalable, matches Invoice AI backend)
-- =============================================================================
-- Columns align with backend/app/services/vendor_normalization_service.py and
-- supabase/migrations/20250401000001_initial.sql

CREATE TABLE IF NOT EXISTS public.vendors (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  normalized_name TEXT NOT NULL,
  display_name TEXT NOT NULL,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, normalized_name)
);

-- display_name is the canonical human-readable label (serves as "name" for integrations).

CREATE INDEX IF NOT EXISTS idx_vendors_user ON public.vendors (user_id);
CREATE INDEX IF NOT EXISTS idx_vendors_display_name_lower ON public.vendors (lower(display_name));

ALTER TABLE public.vendors ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "vendors_all_own" ON public.vendors;
CREATE POLICY "vendors_all_own"
  ON public.vendors FOR ALL
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

GRANT ALL ON TABLE public.vendors TO authenticated, service_role;

-- If you use vendor_aliases (from full initial migration), create when missing:
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

GRANT ALL ON TABLE public.vendor_aliases TO authenticated, service_role;

-- =============================================================================
-- OPTION B — Analytics views WITHOUT joining public.vendors (works if table missing)
-- =============================================================================
-- Safe display label: prefer vendor_name (newer), else vendor_raw (legacy), else Unknown.

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

CREATE OR REPLACE VIEW public.analytics_currency_totals AS
SELECT
  i.user_id,
  COALESCE(i.currency, 'UNKNOWN') AS currency,
  SUM(COALESCE(i.total_amount, 0)) AS total_spend,
  COUNT(*)::bigint AS invoice_count
FROM public.invoices i
GROUP BY i.user_id, 2;

-- RPCs (depend on views above)
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

GRANT SELECT ON public.analytics_monthly_spend TO authenticated, service_role;
GRANT SELECT ON public.analytics_vendor_totals TO authenticated, service_role;
GRANT SELECT ON public.analytics_currency_totals TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_analytics_monthly() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_analytics_vendors(int) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_analytics_currencies() TO authenticated, service_role;

-- If you also use analytics_summary (custom script), replace without vendors:
DROP VIEW IF EXISTS public.analytics_summary CASCADE;
CREATE OR REPLACE VIEW public.analytics_summary AS
SELECT
  i.user_id,
  COALESCE(
    NULLIF(btrim(COALESCE(i.vendor_name, i.vendor_raw, '')), ''),
    'Unknown'
  ) AS vendor_name,
  COALESCE(i.currency, 'UNKNOWN') AS currency,
  COUNT(*)::bigint AS invoice_count,
  SUM(COALESCE(i.total_amount, 0))::numeric(18, 4) AS total_spend,
  MAX(i.invoice_date) AS latest_invoice_date
FROM public.invoices i
GROUP BY
  i.user_id,
  COALESCE(
    NULLIF(btrim(COALESCE(i.vendor_name, i.vendor_raw, '')), ''),
    'Unknown'
  ),
  COALESCE(i.currency, 'UNKNOWN');

GRANT SELECT ON public.analytics_summary TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
