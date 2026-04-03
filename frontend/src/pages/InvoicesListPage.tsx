import { InvoiceTable } from "@/components/InvoiceTable";
import { useInvoices } from "@/hooks/useInvoices";
import type { InvoiceRow } from "@/hooks/useInvoices";
import { useMemo } from "react";
import { Link, useSearchParams } from "react-router-dom";

function formatShortDate(iso: string | null | undefined): string {
  if (!iso?.trim()) return "—";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso.trim();
  return d.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}

/** Prefer invoice #; otherwise distinguish rows without repeating the word “Invoice” only. */
function invoiceCardTitle(inv: InvoiceRow): string {
  const num = String(inv.invoice_number ?? "").trim();
  if (num) return num;
  const uploaded = formatShortDate(inv.created_at);
  if (uploaded !== "—") return `Uploaded ${uploaded}`;
  return `Document ${inv.id.slice(0, 8)}…`;
}

function invoiceCardDateLine(inv: InvoiceRow): string {
  const invDate = String(inv.invoice_date ?? "").trim();
  if (invDate) return invDate;
  const up = formatShortDate(inv.created_at);
  return up !== "—" ? `Invoice date not set · added ${up}` : "Date not available";
}

export function InvoicesListPage() {
  const { items, loading, error, refresh } = useInvoices();
  const rows = Array.isArray(items) ? items : [];
  const [searchParams, setSearchParams] = useSearchParams();
  const tab = (searchParams.get("tab") || "invoices").toLowerCase();
  const invoiceView = (searchParams.get("view") || "grid").toLowerCase(); // grid | table
  const q = (searchParams.get("q") || "").trim().toLowerCase();
  const invFilter = (searchParams.get("filter") || "all").toLowerCase(); // all | duplicates | low_confidence

  const vendors = useMemo(() => {
    const m = new Map<
      string,
      {
        name: string;
        invoiceCount: number;
        currencyCounts: Record<string, number>;
        currencyTotals: Record<string, number>;
      }
    >();
    for (const r of rows) {
      const name = String(r.vendor_raw || "Unknown vendor").trim() || "Unknown vendor";
      const key = name.toLowerCase();
      const cur = String(r.currency || "—").trim() || "—";
      const amt = typeof r.total_amount === "number" ? r.total_amount : 0;
      const curKey = cur || "—";

      const v =
        m.get(key) ||
        ({
          name,
          invoiceCount: 0,
          currencyCounts: {} as Record<string, number>,
          currencyTotals: {} as Record<string, number>,
        });

      const invoiceCount = v.invoiceCount + 1;
      const currencyCounts = { ...v.currencyCounts, [curKey]: (v.currencyCounts[curKey] || 0) + 1 };
      const currencyTotals = { ...v.currencyTotals, [curKey]: (v.currencyTotals[curKey] || 0) + amt };

      m.set(key, { name: v.name, invoiceCount, currencyCounts, currencyTotals });
    }

    const list = Array.from(m.values()).map((v) => {
      const currencies = Object.keys(v.currencyCounts);
      const primaryCurrency =
        currencies.sort((a, b) => (v.currencyCounts[b] || 0) - (v.currencyCounts[a] || 0))[0] || "—";
      const totalPrimary = v.currencyTotals[primaryCurrency] || 0;
      const avgPrimary = v.invoiceCount ? totalPrimary / v.invoiceCount : 0;
      return { ...v, primaryCurrency, totalPrimary, avgPrimary };
    });
    list.sort((a, b) => b.totalPrimary - a.totalPrimary);
    return list;
  }, [rows]);

  const filteredInvoices = useMemo(() => {
    let list = rows;

    if (invFilter === "duplicates") {
      list = list.filter((r) => r.is_duplicate_candidate);
    } else if (invFilter === "low_confidence") {
      list = list.filter((r) => (r.confidence ?? 0) > 0 && (r.confidence ?? 0) < 70);
    }

    if (q) {
      list = list.filter((r) => {
        const vendor = String(r.vendor_raw ?? "").toLowerCase();
        const inv = String(r.invoice_number ?? "").toLowerCase();
        const date = String(r.invoice_date ?? "").toLowerCase();
        return vendor.includes(q) || inv.includes(q) || date.includes(q);
      });
    }

    // newest first (created_at ISO string)
    return [...list].sort((a, b) => (a.created_at < b.created_at ? 1 : -1));
  }, [rows, invFilter, q]);

  const invoiceGrid = useMemo(() => {
    if (!filteredInvoices.length) return null;
    return (
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        {filteredInvoices.map((inv) => {
          const vendor = String(inv.vendor_raw ?? "").trim() || "Unknown vendor";
          const dateLine = invoiceCardDateLine(inv);
          const amount =
            inv.total_amount != null ? `${inv.currency || ""} ${inv.total_amount}`.trim() : "—";
          const conf = inv.confidence ?? 0;
          const confClass =
            conf >= 90
              ? "text-green-600 dark:text-green-400"
              : conf >= 70
                ? "text-amber-600 dark:text-amber-400"
                : conf > 0
                  ? "text-red-600 dark:text-red-400"
                  : "text-slate-400 dark:text-slate-500";
          return (
            <Link
              key={inv.id}
              to={`/invoices/${inv.id}`}
              className="card-gradient rounded-2xl p-6 transition hover:-translate-y-0.5 hover:shadow-md block"
            >
              <div className="flex items-start justify-between mb-4">
                <div>
                  <p className="font-bold text-indigo-600 dark:text-indigo-400">{invoiceCardTitle(inv)}</p>
                  <p className="text-sm text-slate-500 dark:text-slate-400">{dateLine}</p>
                </div>
                {inv.is_duplicate_candidate ? (
                  <span className="px-3 py-1 rounded-full text-xs font-medium bg-gradient-to-r from-amber-100 to-yellow-100 text-amber-800 dark:from-amber-900/50 dark:to-yellow-900/40 dark:text-amber-200">
                    Duplicate
                  </span>
                ) : (
                  <span className="px-3 py-1 rounded-full text-xs font-medium bg-gradient-to-r from-emerald-100 to-green-100 text-emerald-800 dark:from-emerald-900/40 dark:to-green-900/40 dark:text-emerald-200">
                    Completed
                  </span>
                )}
              </div>

              <div className="mb-4">
                <span className="px-3 py-1 rounded-full text-sm font-medium bg-gradient-to-br from-indigo-50 to-purple-50 text-indigo-700 dark:from-indigo-950 dark:to-purple-950 dark:text-indigo-300">
                  {vendor}
                </span>
              </div>

              <div className="flex items-end justify-between">
                <div>
                  <p className="text-sm text-slate-500 dark:text-slate-400">Total</p>
                  <p className="text-2xl font-bold text-slate-800 dark:text-slate-100">{amount}</p>
                </div>
                <div className="text-right">
                  <p className="text-sm text-slate-500 dark:text-slate-400">Confidence</p>
                  <p className={`text-lg font-bold ${confClass}`}>{conf ? `${conf}%` : "—"}</p>
                </div>
              </div>
            </Link>
          );
        })}
      </div>
    );
  }, [filteredInvoices]);

  return (
    <div className="space-y-4 sm:space-y-6 min-w-0">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <h2 className="text-xl sm:text-2xl font-bold text-slate-800 dark:text-slate-100">
            {tab === "vendors" ? "Vendors" : "All Invoices"}
          </h2>
          <p className="text-slate-500 dark:text-slate-400 mt-1 text-sm sm:text-base">
            {tab === "vendors"
              ? "Track and manage your vendors"
              : "Manage and view all processed invoices"}
          </p>
        </div>
        <button
          type="button"
          onClick={() => void refresh()}
          className="w-full sm:w-auto shrink-0 px-4 py-2.5 bg-gradient-to-r from-indigo-500 to-purple-500 text-white rounded-lg text-sm font-medium hover:shadow-lg transition touch-manipulation"
        >
          <i className="fas fa-rotate mr-2" />
          Refresh
        </button>
      </div>

      {error && <p className="text-red-600 dark:text-red-400">{error}</p>}

      <div className="flex items-center gap-3 sm:gap-4 text-sm overflow-x-auto pb-1 -mx-1 px-1 [scrollbar-width:thin]">
        <button
          type="button"
          onClick={() => setSearchParams({ tab: "invoices" })}
          className={[
            "pb-2 px-1 font-medium",
            tab !== "vendors"
              ? "border-b-2 border-indigo-500 text-indigo-600 dark:text-indigo-400"
              : "text-slate-500 dark:text-slate-400 hover:text-slate-700 dark:hover:text-slate-200",
          ].join(" ")}
        >
          Invoices
        </button>
        <button
          type="button"
          onClick={() => setSearchParams({ tab: "vendors" })}
          className={[
            "pb-2 px-1 font-medium",
            tab === "vendors"
              ? "border-b-2 border-indigo-500 text-indigo-600 dark:text-indigo-400"
              : "text-slate-500 dark:text-slate-400 hover:text-slate-700 dark:hover:text-slate-200",
          ].join(" ")}
        >
          Vendors
        </button>
      </div>

      {tab !== "vendors" && (
        <div className="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
          <div className="relative w-full max-w-md">
            <input
              type="text"
              value={searchParams.get("q") || ""}
              onChange={(e) => {
                const next = new URLSearchParams(searchParams);
                const v = e.target.value;
                if (v) next.set("q", v);
                else next.delete("q");
                setSearchParams(next);
              }}
              placeholder="Search invoices…"
              className="w-full pl-10 pr-4 py-2.5 rounded-lg text-sm bg-[var(--app-surface)] text-[var(--app-text)] border border-[var(--app-border)] placeholder:text-[var(--app-text-muted)] focus:ring-2 focus:ring-indigo-500 focus:border-transparent"
            />
            <i className="fas fa-search absolute left-3 top-1/2 -translate-y-1/2 text-slate-400 dark:text-slate-500 pointer-events-none" />
          </div>

          <div className="flex flex-wrap items-center gap-2">
            <button
              type="button"
              onClick={() => {
                const next = new URLSearchParams(searchParams);
                next.set("filter", "all");
                setSearchParams(next);
              }}
              className={[
                "px-3 py-2 rounded-lg text-sm font-medium transition",
                invFilter === "all"
                  ? "bg-indigo-50 text-indigo-700 dark:bg-indigo-950 dark:text-indigo-300"
                  : "text-slate-600 dark:text-slate-300 hover:bg-slate-50 dark:hover:bg-slate-800/60",
              ].join(" ")}
            >
              All
            </button>
            <button
              type="button"
              onClick={() => {
                const next = new URLSearchParams(searchParams);
                next.set("filter", "duplicates");
                setSearchParams(next);
              }}
              className={[
                "px-3 py-2 rounded-lg text-sm font-medium transition",
                invFilter === "duplicates"
                  ? "bg-indigo-50 text-indigo-700 dark:bg-indigo-950 dark:text-indigo-300"
                  : "text-slate-600 dark:text-slate-300 hover:bg-slate-50 dark:hover:bg-slate-800/60",
              ].join(" ")}
            >
              Duplicates
            </button>
            <button
              type="button"
              onClick={() => {
                const next = new URLSearchParams(searchParams);
                next.set("filter", "low_confidence");
                setSearchParams(next);
              }}
              className={[
                "px-3 py-2 rounded-lg text-sm font-medium transition",
                invFilter === "low_confidence"
                  ? "bg-indigo-50 text-indigo-700 dark:bg-indigo-950 dark:text-indigo-300"
                  : "text-slate-600 dark:text-slate-300 hover:bg-slate-50 dark:hover:bg-slate-800/60",
              ].join(" ")}
            >
              Low confidence
            </button>

            <div className="w-px h-6 bg-slate-200 dark:bg-slate-600 mx-1" />

            <button
              type="button"
              onClick={() => {
                const next = new URLSearchParams(searchParams);
                next.set("view", "grid");
                setSearchParams(next);
              }}
              className={[
                "px-3 py-2 rounded-lg text-sm font-medium transition",
                invoiceView === "grid"
                  ? "bg-indigo-50 text-indigo-700 dark:bg-indigo-950 dark:text-indigo-300"
                  : "text-slate-600 dark:text-slate-300 hover:bg-slate-50 dark:hover:bg-slate-800/60",
              ].join(" ")}
              title="Grid view"
            >
              <i className="fas fa-grip mr-2" />
              Grid
            </button>
            <button
              type="button"
              onClick={() => {
                const next = new URLSearchParams(searchParams);
                next.set("view", "table");
                setSearchParams(next);
              }}
              className={[
                "px-3 py-2 rounded-lg text-sm font-medium transition",
                invoiceView === "table"
                  ? "bg-indigo-50 text-indigo-700 dark:bg-indigo-950 dark:text-indigo-300"
                  : "text-slate-600 dark:text-slate-300 hover:bg-slate-50 dark:hover:bg-slate-800/60",
              ].join(" ")}
              title="Table view"
            >
              <i className="fas fa-table mr-2" />
              Table
            </button>
          </div>
        </div>
      )}

      <div className="card-gradient rounded-xl sm:rounded-2xl p-4 sm:p-6 min-w-0 overflow-hidden">
        {loading ? (
          <p className="text-slate-500 dark:text-slate-400">Loading…</p>
        ) : tab === "vendors" ? (
          vendors.length ? (
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
              {vendors.map((v) => (
                <div key={v.name} className="card-gradient rounded-2xl p-6">
                  <div className="flex items-center mb-4">
                    <div className="w-12 h-12 bg-gradient-to-br from-indigo-500 to-purple-500 rounded-xl flex items-center justify-center mr-4">
                      <span className="font-bold text-white text-xl">{v.name.charAt(0).toUpperCase()}</span>
                    </div>
                    <div>
                      <h4 className="font-bold text-slate-800 dark:text-slate-100">{v.name}</h4>
                      <p className="text-sm text-slate-500 dark:text-slate-400">{v.invoiceCount} invoices</p>
                    </div>
                  </div>
                  <div className="grid grid-cols-2 gap-4">
                    <div>
                      <p className="text-sm text-slate-500 dark:text-slate-400">Total ({v.primaryCurrency})</p>
                      <p className="font-bold text-slate-800 dark:text-slate-100">
                        {v.primaryCurrency} {v.totalPrimary.toLocaleString()}
                      </p>
                    </div>
                    <div>
                      <p className="text-sm text-slate-500 dark:text-slate-400">Avg ({v.primaryCurrency})</p>
                      <p className="font-bold text-slate-800 dark:text-slate-100">
                        {v.primaryCurrency} {Math.round(v.avgPrimary).toLocaleString()}
                      </p>
                    </div>
                  </div>
                </div>
              ))}
            </div>
          ) : (
            <p className="text-slate-500 dark:text-slate-400">No vendors yet.</p>
          )
        ) : (
          invoiceView === "table" ? (
            <InvoiceTable rows={filteredInvoices} />
          ) : filteredInvoices.length ? (
            invoiceGrid
          ) : (
            <p className="text-slate-500 dark:text-slate-400">No invoices yet.</p>
          )
        )}
      </div>
    </div>
  );
}
