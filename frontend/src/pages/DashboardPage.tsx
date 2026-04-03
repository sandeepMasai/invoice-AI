import { useCallback, useEffect, useMemo, useState } from "react";
import { CurrencyBreakdownChart } from "@/components/Charts/CurrencyBreakdownChart";
import { MonthlyTrendChart } from "@/components/Charts/MonthlyTrendChart";
import { SpendByVendorChart } from "@/components/Charts/SpendByVendorChart";
import { useAuth } from "@/hooks/useAuth";
import { api } from "@/services/api";
import { useLocation, useNavigate, useSearchParams } from "react-router-dom";

type Summary = {
  total_invoices: number;
  duplicate_candidates: number;
  monthly: { month: string; currency: string; total_spend: number; invoice_count: number }[];
  top_vendors: {
    vendor_key?: string;
    vendor_display: string;
    currency: string;
    total_spend: number;
    invoice_count: number;
  }[];
  currencies: { currency: string; total_spend: number; invoice_count: number }[];
};

function pulseClass() {
  return "animate-pulse rounded-md bg-slate-200/90 dark:bg-slate-600/50";
}

function DashboardSkeleton({
  tab,
  setSearchParams,
}: {
  tab: string;
  setSearchParams: ReturnType<typeof useSearchParams>[1];
}) {
  const p = pulseClass();
  return (
    <div className="space-y-4 sm:space-y-6 w-full max-w-full min-w-0" aria-busy="true" aria-label="Loading dashboard">
      <div className="min-w-0">
        <div className={`h-7 sm:h-8 w-48 ${p}`} />
        <div className={`h-4 w-72 max-w-full mt-2 ${p}`} />
      </div>

      <div className="flex items-center gap-3 sm:gap-4 text-sm overflow-x-auto pb-1 -mx-1 px-1 [scrollbar-width:thin]">
        <button
          type="button"
          onClick={() => setSearchParams({})}
          className={[
            "pb-2 px-1 font-medium",
            tab === "dashboard"
              ? "border-b-2 border-indigo-500 text-indigo-600 dark:text-indigo-400"
              : "text-slate-500 dark:text-slate-400 hover:text-slate-700 dark:hover:text-slate-200",
          ].join(" ")}
        >
          Dashboard
        </button>
        <button
          type="button"
          onClick={() => setSearchParams({ tab: "analytics" })}
          className={[
            "pb-2 px-1 font-medium",
            tab === "analytics"
              ? "border-b-2 border-indigo-500 text-indigo-600 dark:text-indigo-400"
              : "text-slate-500 dark:text-slate-400 hover:text-slate-700 dark:hover:text-slate-200",
          ].join(" ")}
        >
          Analytics
        </button>
      </div>

      <div className="space-y-4 sm:space-y-6 min-w-0">
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3 sm:gap-4 md:gap-6">
          {[0, 1, 2, 3].map((i) => (
            <div key={i} className="card-gradient rounded-xl sm:rounded-2xl p-4 sm:p-6 min-w-0">
              <div className="flex items-center justify-between gap-3">
                <div className="min-w-0 flex-1 space-y-3">
                  <div className={`h-3 w-28 ${p}`} />
                  <div className={`h-8 w-24 sm:w-32 ${p}`} />
                  <div className={`h-3 w-40 ${p}`} />
                </div>
                <div className={`w-11 h-11 sm:w-14 sm:h-14 shrink-0 rounded-xl sm:rounded-2xl ${p}`} />
              </div>
            </div>
          ))}
        </div>

        <div className="grid grid-cols-1 lg:grid-cols-2 gap-4 sm:gap-6 min-w-0">
          <div className="card-gradient rounded-xl sm:rounded-2xl p-4 sm:p-6 min-w-0">
            <div className={`h-5 w-40 mb-4 sm:mb-6 ${p}`} />
            <div className={`h-[220px] sm:h-[280px] w-full ${p}`} />
          </div>
          <div className="card-gradient rounded-xl sm:rounded-2xl p-4 sm:p-6 min-w-0">
            <div className={`h-5 w-36 mb-4 sm:mb-6 ${p}`} />
            <div className={`h-[220px] sm:h-[280px] w-full ${p}`} />
          </div>
        </div>

        <div className="grid grid-cols-1 lg:grid-cols-2 gap-4 sm:gap-6 min-w-0">
          <div className="card-gradient rounded-xl sm:rounded-2xl p-4 sm:p-6 min-w-0">
            <div className={`h-5 w-28 mb-4 sm:mb-6 ${p}`} />
            <div className={`h-[200px] sm:h-[260px] w-full max-w-[200px] mx-auto rounded-full ${p}`} />
          </div>
          <div className="card-gradient rounded-xl sm:rounded-2xl p-4 sm:p-6 min-w-0">
            <div className={`h-5 w-44 mb-4 sm:mb-6 ${p}`} />
            <div className="space-y-3">
              {[0, 1, 2, 3].map((j) => (
                <div key={j} className={`h-10 w-full ${p}`} />
              ))}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

export function DashboardPage() {
  const { session, loading: authLoading } = useAuth();
  const [data, setData] = useState<Summary | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [searchParams, setSearchParams] = useSearchParams();
  const location = useLocation();
  const navigate = useNavigate();
  const tabRaw = (searchParams.get("tab") || "dashboard").toLowerCase();
  const tab = tabRaw === "settings" ? "dashboard" : tabRaw;
  const pendingProcessing = Boolean(
    (location.state as { pendingProcessing?: boolean } | null)?.pendingProcessing,
  );

  useEffect(() => {
    if (searchParams.get("tab")?.toLowerCase() === "settings") {
      const next = new URLSearchParams(searchParams);
      next.delete("tab");
      setSearchParams(next, { replace: true });
    }
  }, [searchParams, setSearchParams]);

  const loadSummary = useCallback(
    async (opts?: { soft?: boolean }) => {
      if (!session?.access_token) return;
      if (!opts?.soft) setErr(null);
      try {
        const raw = (await api.analyticsSummary()) as Partial<Summary> & {
          topVendors?: Summary["top_vendors"];
          monthlySpend?: Summary["monthly"];
        };
        const topVendorsRaw = raw.top_vendors ?? raw.topVendors;
        const monthlyRaw = raw.monthly ?? raw.monthlySpend;
        const s: Summary = {
          total_invoices: Number(raw.total_invoices) || 0,
          duplicate_candidates: Number(raw.duplicate_candidates) || 0,
          monthly: Array.isArray(monthlyRaw) ? monthlyRaw : [],
          top_vendors: Array.isArray(topVendorsRaw) ? topVendorsRaw : [],
          currencies: Array.isArray(raw.currencies) ? raw.currencies : [],
        };
        setData(s);
        setErr(null);
      } catch (e) {
        if (opts?.soft) return;
        setErr(e instanceof Error ? e.message : "Failed to load analytics");
      }
    },
    [session?.access_token],
  );

  useEffect(() => {
    if (authLoading) return;
    if (!session?.access_token) {
      setErr("Not signed in — open Login and complete magic link.");
      return;
    }
    let cancelled = false;
    void (async () => {
      await loadSummary();
      if (cancelled) return;
    })();
    return () => {
      cancelled = true;
    };
  }, [authLoading, session?.access_token, loadSummary]);

  // Processing runs in the background; poll briefly after upload so counts/charts update without a full reload.
  useEffect(() => {
    if (!pendingProcessing || authLoading || !session?.access_token) return;
    let n = 0;
    const id = window.setInterval(() => {
      n += 1;
      void loadSummary({ soft: true });
      if (n >= 18) window.clearInterval(id);
    }, 2500);
    const clearState = window.setTimeout(() => {
      navigate(`${location.pathname}${location.search}`, { replace: true, state: {} });
    }, 47000);
    return () => {
      window.clearInterval(id);
      window.clearTimeout(clearState);
    };
  }, [
    pendingProcessing,
    authLoading,
    session?.access_token,
    loadSummary,
    navigate,
    location.pathname,
    location.search,
  ]);

  useEffect(() => {
    const onVis = () => {
      if (document.visibilityState === "visible" && session?.access_token && !authLoading) {
        void loadSummary({ soft: true });
      }
    };
    document.addEventListener("visibilitychange", onVis);
    return () => document.removeEventListener("visibilitychange", onVis);
  }, [session?.access_token, authLoading, loadSummary]);

  const analyticsCards = useMemo(() => {
    if (!data) {
      return { totalSpendAll: 0, avgInvoice: 0, topCurrency: "—", topVendor: "—" };
    }
    const totalSpendAll = data.currencies.reduce((acc, r) => acc + (r.total_spend || 0), 0);
    const avgInvoice = data.total_invoices ? totalSpendAll / data.total_invoices : 0;
    const topCurrency =
      [...data.currencies].sort((a, b) => (b.total_spend || 0) - (a.total_spend || 0))[0]?.currency || "—";
    const topVendor =
      [...data.top_vendors].sort((a, b) => (b.total_spend || 0) - (a.total_spend || 0))[0]?.vendor_display ||
      "—";
    return { totalSpendAll, avgInvoice, topCurrency, topVendor };
  }, [data]);

  if (authLoading) return <p className="text-slate-500 dark:text-slate-400 px-1">Loading session…</p>;
  if (err) return <p className="text-red-600 dark:text-red-400 text-sm sm:text-base break-words px-1">{err}</p>;
  if (!data) return <DashboardSkeleton tab={tab} setSearchParams={setSearchParams} />;

  return (
    <div className="space-y-4 sm:space-y-6 w-full max-w-full min-w-0">
      <div className="min-w-0">
        <h2 className="text-xl sm:text-2xl font-bold text-slate-800 dark:text-slate-100">
          {tab === "analytics" ? "Analytics Dashboard" : "Dashboard"}
        </h2>
        <p className="text-slate-500 dark:text-slate-400 mt-1">Insights and trends from your invoice data</p>
      </div>

      <div className="flex items-center gap-3 sm:gap-4 text-sm overflow-x-auto pb-1 -mx-1 px-1 [scrollbar-width:thin]">
        <button
          type="button"
          onClick={() => setSearchParams({})}
          className={[
            "pb-2 px-1 font-medium",
            tab === "dashboard"
              ? "border-b-2 border-indigo-500 text-indigo-600 dark:text-indigo-400"
              : "text-slate-500 dark:text-slate-400 hover:text-slate-700 dark:hover:text-slate-200",
          ].join(" ")}
        >
          Dashboard
        </button>
        <button
          type="button"
          onClick={() => setSearchParams({ tab: "analytics" })}
          className={[
            "pb-2 px-1 font-medium",
            tab === "analytics"
              ? "border-b-2 border-indigo-500 text-indigo-600 dark:text-indigo-400"
              : "text-slate-500 dark:text-slate-400 hover:text-slate-700 dark:hover:text-slate-200",
          ].join(" ")}
        >
          Analytics
        </button>
      </div>

      <div className="space-y-4 sm:space-y-6 min-w-0">
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3 sm:gap-4 md:gap-6">
            <div className="card-gradient rounded-xl sm:rounded-2xl p-4 sm:p-6 min-w-0">
              <div className="flex items-center justify-between gap-3">
                <div className="min-w-0">
                  <p className="text-slate-500 dark:text-slate-400 text-xs sm:text-sm">
                    {tab === "analytics" ? "Average Invoice Value" : "Total Invoices"}
                  </p>
                  <p className="text-2xl sm:text-3xl font-bold text-slate-800 dark:text-slate-100 mt-1 tabular-nums truncate">
                    {tab === "analytics"
                      ? Math.round(analyticsCards.avgInvoice).toLocaleString()
                      : data.total_invoices}
                  </p>
                  <p className="text-slate-400 dark:text-slate-500 text-sm mt-2">
                    {tab === "analytics" ? "Across all currencies (sum)" : "Total processed records"}
                  </p>
                </div>
                <div className="w-11 h-11 sm:w-14 sm:h-14 shrink-0 bg-gradient-to-br from-blue-500 to-blue-600 rounded-xl sm:rounded-2xl flex items-center justify-center">
                  <i className={`fas ${tab === "analytics" ? "fa-receipt" : "fa-file-invoice"} text-white text-lg sm:text-xl`} />
                </div>
              </div>
            </div>

            <div className="card-gradient rounded-xl sm:rounded-2xl p-4 sm:p-6 min-w-0">
              <div className="flex items-center justify-between gap-3">
                <div className="min-w-0">
                  <p className="text-slate-500 dark:text-slate-400 text-xs sm:text-sm">
                    {tab === "analytics" ? "Total Spend (all)" : "Duplicate candidates"}
                  </p>
                  <p className="text-2xl sm:text-3xl font-bold text-slate-800 dark:text-slate-100 mt-1 tabular-nums truncate">
                    {tab === "analytics"
                      ? Math.round(analyticsCards.totalSpendAll).toLocaleString()
                      : data.duplicate_candidates}
                  </p>
                  <p className="text-slate-400 dark:text-slate-500 text-sm mt-2">
                    {tab === "analytics" ? "Sum across currencies" : "Flagged by fingerprint"}
                  </p>
                </div>
                <div className="w-11 h-11 sm:w-14 sm:h-14 shrink-0 bg-gradient-to-br from-orange-500 to-orange-600 rounded-xl sm:rounded-2xl flex items-center justify-center">
                  <i className={`fas ${tab === "analytics" ? "fa-dollar-sign" : "fa-clone"} text-white text-lg sm:text-xl`} />
                </div>
              </div>
            </div>

            <div className="card-gradient rounded-xl sm:rounded-2xl p-4 sm:p-6 min-w-0">
              <div className="flex items-center justify-between gap-3">
                <div className="min-w-0">
                  <p className="text-slate-500 dark:text-slate-400 text-xs sm:text-sm">{tab === "analytics" ? "Top Vendor" : "Top vendors"}</p>
                  <p
                    className={[
                      "text-2xl sm:text-3xl font-bold text-slate-800 dark:text-slate-100 mt-1 tabular-nums min-w-0",
                      tab === "analytics" ? "break-words line-clamp-2" : "truncate",
                    ].join(" ")}
                  >
                    {tab === "analytics" ? analyticsCards.topVendor.slice(0, 10) : data.top_vendors.length}
                  </p>
                  <p className="text-slate-400 dark:text-slate-500 text-sm mt-2">{tab === "analytics" ? "By spend" : "In summary list"}</p>
                </div>
                <div className="w-11 h-11 sm:w-14 sm:h-14 shrink-0 bg-gradient-to-br from-purple-500 to-purple-600 rounded-xl sm:rounded-2xl flex items-center justify-center">
                  <i className="fas fa-building text-white text-lg sm:text-xl" />
                </div>
              </div>
            </div>

            <div className="card-gradient rounded-xl sm:rounded-2xl p-4 sm:p-6 min-w-0">
              <div className="flex items-center justify-between gap-3">
                <div className="min-w-0">
                  <p className="text-slate-500 dark:text-slate-400 text-xs sm:text-sm">{tab === "analytics" ? "Top Currency" : "Currencies"}</p>
                  <p className="text-2xl sm:text-3xl font-bold text-slate-800 dark:text-slate-100 mt-1 tabular-nums truncate">
                    {tab === "analytics" ? analyticsCards.topCurrency : data.currencies.length}
                  </p>
                  <p className="text-slate-400 dark:text-slate-500 text-sm mt-2">{tab === "analytics" ? "By spend" : "Detected"}</p>
                </div>
                <div className="w-11 h-11 sm:w-14 sm:h-14 shrink-0 bg-gradient-to-br from-green-500 to-green-600 rounded-xl sm:rounded-2xl flex items-center justify-center">
                  <i className="fas fa-coins text-white text-lg sm:text-xl" />
                </div>
              </div>
            </div>
          </div>

          <div className="grid grid-cols-1 lg:grid-cols-2 gap-4 sm:gap-6 min-w-0">
            <div className="card-gradient rounded-xl sm:rounded-2xl p-4 sm:p-6 min-w-0">
              <div className="flex items-center justify-between mb-4 sm:mb-6">
                <h3 className="font-bold text-slate-800 dark:text-slate-100 text-base sm:text-lg">Monthly Spend Trends</h3>
              </div>
              <MonthlyTrendChart data={data.monthly} />
            </div>

            <div className="card-gradient rounded-xl sm:rounded-2xl p-4 sm:p-6 min-w-0">
              <div className="flex items-center justify-between mb-4 sm:mb-6">
                <h3 className="font-bold text-slate-800 dark:text-slate-100 text-base sm:text-lg">Spend by Vendor</h3>
              </div>
              <SpendByVendorChart data={data.top_vendors} />
            </div>
          </div>

          <div className="grid grid-cols-1 lg:grid-cols-2 gap-4 sm:gap-6 min-w-0">
            <div className="card-gradient rounded-xl sm:rounded-2xl p-4 sm:p-6 min-w-0">
              <h3 className="font-bold text-slate-800 dark:text-slate-100 text-base sm:text-lg mb-4 sm:mb-6">By currency</h3>
              <CurrencyBreakdownChart data={data.currencies} />
            </div>

            <div className="card-gradient rounded-xl sm:rounded-2xl p-4 sm:p-6 min-w-0">
              <h3 className="font-bold text-slate-800 dark:text-slate-100 text-base sm:text-lg mb-4 sm:mb-6">Top vendors by spend</h3>
              <div className="overflow-x-auto -mx-1 px-1">
                <table className="w-full min-w-[320px] text-sm">
                  <thead>
                    <tr className="text-left text-slate-500 dark:text-slate-400 text-xs sm:text-sm border-b border-slate-200 dark:border-slate-600">
                      <th className="pb-3 sm:pb-4 font-medium">Vendor</th>
                      <th className="pb-3 sm:pb-4 font-medium">Invoices</th>
                      <th className="pb-3 sm:pb-4 font-medium">Currency</th>
                      <th className="pb-3 sm:pb-4 font-medium">Total Spend</th>
                    </tr>
                  </thead>
                  <tbody>
                    {data.top_vendors.length === 0 ? (
                      <tr>
                        <td colSpan={4} className="py-8 text-center text-sm text-slate-500 dark:text-slate-400">
                          No vendor spend breakdown yet. After invoices are processed with a vendor name, totals appear
                          here.
                        </td>
                      </tr>
                    ) : (
                      data.top_vendors.slice(0, 10).map((v, idx) => (
                        <tr
                          key={`${v.vendor_key ?? v.vendor_display ?? "v"}-${v.currency ?? "c"}-${idx}`}
                          className="border-b border-slate-200 dark:border-slate-600 hover:bg-slate-50 dark:hover:bg-slate-800/50 transition"
                        >
                          <td className="py-3 sm:py-4 font-medium text-slate-800 dark:text-slate-100 max-w-[140px] sm:max-w-none truncate sm:whitespace-normal">
                            {v.vendor_display || "—"}
                          </td>
                          <td className="py-3 sm:py-4 text-slate-600 dark:text-slate-300">{v.invoice_count}</td>
                          <td className="py-3 sm:py-4 text-slate-600 dark:text-slate-300">{v.currency || "—"}</td>
                          <td className="py-3 sm:py-4 font-semibold text-slate-800 dark:text-slate-100 tabular-nums">
                            {Math.round(Number(v.total_spend) || 0).toLocaleString()}
                          </td>
                        </tr>
                      ))
                    )}
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        </div>
    </div>
  );
}
