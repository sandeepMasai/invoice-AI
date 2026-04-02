-- Invoice AI: core schema, RLS, storage bucket, optional pgvector
-- Enable extensions
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "vector";

-- -----------------------------------------------------------------------------
-- profiles (synced from auth.users on first touch)
-- -----------------------------------------------------------------------------
CREATE TABLE public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  email TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "profiles_select_own"
  ON public.profiles FOR SELECT
  USING (id = auth.uid());

CREATE POLICY "profiles_update_own"
  ON public.profiles FOR UPDATE
  USING (id = auth.uid());

CREATE POLICY "profiles_insert_own"
  ON public.profiles FOR INSERT
  WITH CHECK (id = auth.uid());

-- -----------------------------------------------------------------------------
-- files
-- -----------------------------------------------------------------------------
CREATE TABLE public.files (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  storage_path TEXT NOT NULL,
  mime_type TEXT NOT NULL,
  original_filename TEXT NOT NULL,
  byte_size BIGINT NOT NULL DEFAULT 0,
  sha256 TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (storage_path)
);

CREATE INDEX idx_files_user_id ON public.files (user_id);
CREATE INDEX idx_files_created_at ON public.files (user_id, created_at DESC);

ALTER TABLE public.files ENABLE ROW LEVEL SECURITY;

CREATE POLICY "files_all_own"
  ON public.files FOR ALL
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- processing_jobs
-- -----------------------------------------------------------------------------
CREATE TYPE public.job_status AS ENUM (
  'queued',
  'ocr_running',
  'llm_running',
  'completed',
  'failed'
);

CREATE TABLE public.processing_jobs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  file_id UUID NOT NULL REFERENCES public.files (id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  status public.job_status NOT NULL DEFAULT 'queued',
  attempt_count INT NOT NULL DEFAULT 0,
  error_message TEXT,
  started_at TIMESTAMPTZ,
  finished_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_jobs_file_id ON public.processing_jobs (file_id);
CREATE INDEX idx_jobs_user_status ON public.processing_jobs (user_id, status);

ALTER TABLE public.processing_jobs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "jobs_all_own"
  ON public.processing_jobs FOR ALL
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- vendors
-- -----------------------------------------------------------------------------
CREATE TABLE public.vendors (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  normalized_name TEXT NOT NULL,
  display_name TEXT NOT NULL,
  metadata JSONB NOT NULL DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, normalized_name)
);

CREATE INDEX idx_vendors_user ON public.vendors (user_id);

ALTER TABLE public.vendors ENABLE ROW LEVEL SECURITY;

CREATE POLICY "vendors_all_own"
  ON public.vendors FOR ALL
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- vendor_aliases
-- -----------------------------------------------------------------------------
CREATE TABLE public.vendor_aliases (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES public.vendors (id) ON DELETE CASCADE,
  alias_text TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT 'rule' CHECK (source IN ('rule', 'llm', 'manual')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (vendor_id, alias_text)
);

CREATE INDEX idx_vendor_aliases_text ON public.vendor_aliases (lower(alias_text));

ALTER TABLE public.vendor_aliases ENABLE ROW LEVEL SECURITY;

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

-- -----------------------------------------------------------------------------
-- invoice_formats (optional embedding for similarity; 1536 = OpenAI text-embedding-3-small)
-- -----------------------------------------------------------------------------
CREATE TABLE public.invoice_formats (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users (id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  embedding vector(1536),
  template_json JSONB NOT NULL DEFAULT '{}',
  sample_snippet TEXT,
  success_count INT NOT NULL DEFAULT 0,
  last_used_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_invoice_formats_user ON public.invoice_formats (user_id);
-- Add vector index after data exists, e.g. HNSW: CREATE INDEX ... USING hnsw (embedding vector_cosine_ops);

ALTER TABLE public.invoice_formats ENABLE ROW LEVEL SECURITY;

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

-- -----------------------------------------------------------------------------
-- invoices
-- -----------------------------------------------------------------------------
CREATE TABLE public.invoices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  file_id UUID NOT NULL REFERENCES public.files (id) ON DELETE CASCADE,
  job_id UUID REFERENCES public.processing_jobs (id) ON DELETE SET NULL,
  vendor_raw TEXT,
  vendor_id UUID REFERENCES public.vendors (id) ON DELETE SET NULL,
  invoice_number TEXT,
  invoice_date DATE,
  due_date DATE,
  currency TEXT,
  total_amount NUMERIC(18, 4),
  subtotal NUMERIC(18, 4),
  tax_total NUMERIC(18, 4),
  line_items JSONB NOT NULL DEFAULT '[]',
  extraction JSONB NOT NULL DEFAULT '{}',
  confidence NUMERIC(5, 4),
  format_id UUID REFERENCES public.invoice_formats (id) ON DELETE SET NULL,
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

CREATE POLICY "invoices_all_own"
  ON public.invoices FOR ALL
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- invoice_format_matches (audit)
-- -----------------------------------------------------------------------------
CREATE TABLE public.invoice_format_matches (
  invoice_id UUID NOT NULL REFERENCES public.invoices (id) ON DELETE CASCADE,
  format_id UUID NOT NULL REFERENCES public.invoice_formats (id) ON DELETE CASCADE,
  score NUMERIC(8, 6) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (invoice_id, format_id)
);

ALTER TABLE public.invoice_format_matches ENABLE ROW LEVEL SECURITY;

CREATE POLICY "format_matches_all"
  ON public.invoice_format_matches FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.invoices i
      WHERE i.id = invoice_format_matches.invoice_id AND i.user_id = auth.uid()
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.invoices i
      WHERE i.id = invoice_format_matches.invoice_id AND i.user_id = auth.uid()
    )
  );

-- -----------------------------------------------------------------------------
-- Trigger: create profile on signup
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.profiles (id, email)
  VALUES (NEW.id, NEW.email)
  ON CONFLICT (id) DO UPDATE SET email = EXCLUDED.email;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE PROCEDURE public.handle_new_user();

-- -----------------------------------------------------------------------------
-- Storage: bucket + policies (private invoices)
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
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- Path convention: {user_id}/{uuid}_{filename}
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
