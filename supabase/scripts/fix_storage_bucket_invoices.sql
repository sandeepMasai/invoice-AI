-- =============================================================================
-- Fix: Supabase Storage "Bucket not found" for bucket `invoices`
-- Run in Supabase SQL Editor against the target project.
-- Safe to run multiple times (uses IF NOT EXISTS / ON CONFLICT + policy drops).
-- =============================================================================

-- Create/update bucket definition
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

-- Ensure RLS on storage.objects (Supabase usually already enables it)
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;

-- Policies: private bucket under {user_id}/... folder
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

-- Refresh PostgREST schema cache
NOTIFY pgrst, 'reload schema';

