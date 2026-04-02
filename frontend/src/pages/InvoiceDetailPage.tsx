import { useEffect, useMemo, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { ConfidenceBadge } from "@/components/ConfidenceBadge";
import { useAuth } from "@/hooks/useAuth";
import { api } from "@/services/api";

function resolveOcrText(row: {
  ocr_text: string | null;
  extraction: Record<string, unknown>;
}): string {
  const top = row.ocr_text;
  if (top != null && String(top).trim()) {
    return String(top);
  }
  const ext = row.extraction;
  const meta = ext && typeof ext === "object" ? (ext as Record<string, unknown>)["_ocr_meta"] : null;
  if (meta && typeof meta === "object" && meta !== null) {
    const m = meta as Record<string, unknown>;
    const p = m.preview ?? m.text;
    if (p != null && String(p).trim()) {
      return String(p);
    }
  }
  return "";
}

function extractionForDisplay(extraction: Record<string, unknown>): Record<string, unknown> {
  const { _ocr_meta: _o, _validation_errors: _v, ...rest } = extraction;
  return rest;
}

type InvoiceDetail = {
  id: string;
  vendor_raw: string | null;
  invoice_number: string | null;
  invoice_date: string | null;
  due_date: string | null;
  currency: string | null;
  total_amount: number | null;
  subtotal: number | null;
  tax_total: number | null;
  line_items: Record<string, unknown>[];
  extraction: Record<string, unknown>;
  confidence: number | null;
  is_duplicate_candidate: boolean;
  is_duplicate_of: string | null;
  ocr_text: string | null;
};

export function InvoiceDetailPage() {
  const { id } = useParams();
  const { session, loading: authLoading } = useAuth();
  const [row, setRow] = useState<InvoiceDetail | null>(null);
  const [ocrExpanded, setOcrExpanded] = useState(true);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (!id) return;
    setRow(null);
    if (authLoading) return;
    if (!session?.access_token) {
      setErr("Not signed in — open Login and complete magic link.");
      return;
    }
    let cancelled = false;
    setErr(null);
    (async () => {
      try {
        const d = (await api.getInvoice(id)) as InvoiceDetail;
        if (!cancelled) setRow(d);
      } catch (e) {
        if (!cancelled) setErr(e instanceof Error ? e.message : "Not found");
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [authLoading, session?.access_token, id]);

  const ocrContent = useMemo(() => (row ? resolveOcrText(row) : ""), [row]);
  const extractionJson = useMemo(
    () => (row ? extractionForDisplay(row.extraction) : {}),
    [row],
  );

  useEffect(() => {
    if (!row) return;
    setOcrExpanded(Boolean(ocrContent));
  }, [row, ocrContent]);

  if (authLoading) return <p className="text-slate-500 dark:text-slate-400">Loading session…</p>;
  if (err) {
    let msg = err;
    try {
      const o = JSON.parse(err) as { detail?: string };
      if (typeof o.detail === "string") msg = o.detail;
    } catch {
      /* use raw */
    }
    return <p className="text-red-600 dark:text-red-400">{msg}</p>;
  }
  if (!row) return <p className="text-slate-500 dark:text-slate-400">Loading…</p>;

  return (
    <div className="space-y-4 sm:space-y-6 min-w-0">
      <div className="flex items-center justify-between">
        <Link
          to="/invoices"
          className="inline-flex items-center gap-2 text-sm text-slate-600 dark:text-slate-300 hover:text-slate-800 dark:hover:text-slate-100 touch-manipulation py-1"
        >
          <i className="fas fa-arrow-left" />
          Invoices
        </Link>
      </div>

      <div className="card-gradient rounded-xl sm:rounded-2xl p-4 sm:p-6 min-w-0 overflow-hidden">
        <div className="flex flex-col gap-4 sm:flex-row sm:flex-wrap sm:items-start sm:justify-between">
          <div className="min-w-0 flex-1">
            <p className="text-slate-500 dark:text-slate-400 text-sm">Vendor</p>
            <h2 className="text-xl sm:text-2xl font-bold text-slate-800 dark:text-slate-100 mt-1 break-words">
              {row.vendor_raw || "Unknown vendor"}
            </h2>
            <p className="text-slate-400 dark:text-slate-500 text-sm mt-1">Invoice ID: {row.id}</p>
          </div>

          <div className="flex flex-wrap items-center gap-2 sm:gap-3">
            <ConfidenceBadge value={row.confidence} />
            {row.is_duplicate_candidate && (
              <span className="px-3 py-1 rounded-full text-xs font-medium bg-gradient-to-r from-amber-100 to-yellow-100 text-amber-800 dark:from-amber-900/50 dark:to-yellow-900/40 dark:text-amber-200">
                Possible duplicate
              </span>
            )}
          </div>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-4 gap-4 mt-6">
          <div className="bg-slate-50 dark:bg-slate-800/50 rounded-lg p-3">
            <p className="text-xs text-slate-500 dark:text-slate-400 uppercase">Invoice #</p>
            <p className="font-semibold text-slate-800 dark:text-slate-100">{row.invoice_number || "—"}</p>
          </div>
          <div className="bg-slate-50 dark:bg-slate-800/50 rounded-lg p-3">
            <p className="text-xs text-slate-500 dark:text-slate-400 uppercase">Date</p>
            <p className="font-semibold text-slate-800 dark:text-slate-100">{row.invoice_date || "—"}</p>
          </div>
          <div className="bg-slate-50 dark:bg-slate-800/50 rounded-lg p-3">
            <p className="text-xs text-slate-500 dark:text-slate-400 uppercase">Due</p>
            <p className="font-semibold text-slate-800 dark:text-slate-100">{row.due_date || "—"}</p>
          </div>
          <div className="bg-slate-50 dark:bg-slate-800/50 rounded-lg p-3">
            <p className="text-xs text-slate-500 dark:text-slate-400 uppercase">Total</p>
            <p className="font-semibold text-green-700 dark:text-green-400">
              {row.total_amount != null ? `${row.currency || ""} ${row.total_amount}`.trim() : "—"}
            </p>
          </div>
        </div>

        <div className="mt-4 sm:mt-6 min-w-0 rounded-xl border border-slate-200 dark:border-slate-600 bg-slate-50/80 dark:bg-slate-900/40 overflow-hidden">
          <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-2 px-4 py-3 border-b border-slate-200 dark:border-slate-600 bg-white/90 dark:bg-slate-900/80">
            <div className="flex items-center gap-2 min-w-0">
              <i className="fas fa-file-lines text-indigo-600 dark:text-indigo-400 shrink-0" aria-hidden />
              <h3 className="font-bold text-slate-800 dark:text-slate-100 text-base sm:text-lg">OCR text</h3>
              {ocrContent ? (
                <span className="text-xs text-slate-500 dark:text-slate-400 truncate">
                  ({ocrContent.length.toLocaleString()} chars)
                </span>
              ) : null}
            </div>
            <div className="flex items-center gap-2 shrink-0">
              {ocrContent ? (
                <>
                  <button
                    type="button"
                    className="px-3 py-2 border border-slate-200 dark:border-slate-600 rounded-lg text-slate-700 dark:text-slate-200 hover:bg-slate-50 dark:hover:bg-slate-800 text-sm font-medium touch-manipulation"
                    onClick={() => {
                      void navigator.clipboard?.writeText(ocrContent).catch(() => {
                        /* clipboard may be unavailable (non-HTTPS, denied) */
                      });
                    }}
                  >
                    <i className="fas fa-copy mr-1.5" aria-hidden />
                    Copy
                  </button>
                  <button
                    type="button"
                    className="px-3 py-2 border border-slate-200 dark:border-slate-600 rounded-lg text-slate-700 dark:text-slate-200 hover:bg-slate-50 dark:hover:bg-slate-800 text-sm font-medium touch-manipulation"
                    onClick={() => setOcrExpanded((e) => !e)}
                    aria-expanded={ocrExpanded}
                  >
                    <i className={`fas ${ocrExpanded ? "fa-chevron-up" : "fa-chevron-down"} mr-1.5`} aria-hidden />
                    {ocrExpanded ? "Collapse" : "Expand"}
                  </button>
                </>
              ) : null}
            </div>
          </div>
          {ocrExpanded && (
            <div className="p-3 sm:p-4">
              {ocrContent ? (
                <pre className="font-mono text-xs sm:text-sm text-slate-800 dark:text-slate-100 whitespace-pre-wrap break-words max-h-[min(55vh,520px)] overflow-y-auto overflow-x-auto p-3 sm:p-4 rounded-lg bg-white dark:bg-slate-950 border border-slate-200 dark:border-slate-600 shadow-inner leading-relaxed">
                  {ocrContent}
                </pre>
              ) : (
                <p className="text-sm text-slate-500 dark:text-slate-400 px-1 py-4">
                  No OCR text is stored for this invoice. Re-process the file or check that extraction saved{" "}
                  <code className="text-xs bg-slate-100 dark:bg-slate-800 px-1 rounded">_ocr_meta.preview</code> in the
                  database.
                </p>
              )}
            </div>
          )}
        </div>

        <div className="grid grid-cols-1 lg:grid-cols-2 gap-4 sm:gap-6 mt-4 sm:mt-6 min-w-0">
          <div>
            <div className="flex items-center justify-between mb-3">
              <h3 className="font-bold text-slate-800 dark:text-slate-100 text-lg">Line items</h3>
            </div>
            <pre className="bg-gray-900 text-green-300 p-3 sm:p-4 rounded-lg text-xs sm:text-sm overflow-x-auto max-w-full">
              {JSON.stringify(row.line_items, null, 2)}
            </pre>
          </div>

          <div>
            <div className="flex items-center justify-between mb-3">
              <h3 className="font-bold text-slate-800 dark:text-slate-100 text-lg">Raw extraction</h3>
            </div>

            <pre className="bg-gray-900 text-green-300 p-3 sm:p-4 rounded-lg text-xs sm:text-sm overflow-x-auto max-w-full">
              {JSON.stringify(extractionJson, null, 2)}
            </pre>
          </div>
        </div>
      </div>
    </div>
  );
}
