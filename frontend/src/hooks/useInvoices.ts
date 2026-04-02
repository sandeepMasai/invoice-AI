import { useCallback, useEffect, useState } from "react";
import { useAuth } from "@/hooks/useAuth";
import { api } from "@/services/api";

export type InvoiceRow = {
  id: string;
  file_id: string;
  vendor_raw: string | null;
  invoice_number: string | null;
  invoice_date: string | null;
  currency: string | null;
  total_amount: number | null;
  confidence: number | null;
  is_duplicate_candidate: boolean;
  created_at: string;
};

export function useInvoices() {
  const { session, loading: authLoading } = useAuth();
  const [items, setItems] = useState<InvoiceRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    if (!session?.access_token) {
      setError("Not signed in.");
      return;
    }
    setLoading(true);
    setError(null);
    try {
      const data = (await api.listInvoices()) as InvoiceRow[];
      setItems(data);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to load");
    } finally {
      setLoading(false);
    }
  }, [session?.access_token]);

  useEffect(() => {
    if (authLoading) return;
    if (!session?.access_token) {
      setError("Sign in to view invoices.");
      return;
    }
    void refresh();
  }, [authLoading, session?.access_token, refresh]);

  return { items, loading, error, refresh };
}
