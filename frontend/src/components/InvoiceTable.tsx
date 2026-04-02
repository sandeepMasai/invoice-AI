import { Link } from "react-router-dom";
import { ConfidenceBadge } from "@/components/ConfidenceBadge";
import type { InvoiceRow } from "@/hooks/useInvoices";

export function InvoiceTable({ rows }: { rows: InvoiceRow[] }) {
  if (!rows.length) return <p className="text-slate-500 dark:text-slate-400">No invoices yet.</p>;
  return (
    <div className="overflow-x-auto -mx-1 px-1">
      <table className="w-full min-w-[640px] text-xs sm:text-sm">
        <thead>
          <tr className="text-left text-slate-500 dark:text-slate-400 border-b border-slate-200 dark:border-slate-600">
            <th className="pb-4 font-medium">Vendor</th>
            <th className="pb-4 font-medium">Invoice #</th>
            <th className="pb-4 font-medium">Date</th>
            <th className="pb-4 font-medium">Total</th>
            <th className="pb-4 font-medium">Confidence</th>
            <th className="pb-4 font-medium">Duplicate</th>
            <th className="pb-4 font-medium text-right">Actions</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr
              key={r.id}
              className="border-b border-slate-200 dark:border-slate-600 hover:bg-slate-50 dark:hover:bg-slate-800/50 transition"
            >
              <td className="py-4">
                <span className="px-3 py-1 rounded-full text-sm font-medium bg-gradient-to-br from-indigo-50 to-purple-50 text-indigo-700 dark:from-indigo-950 dark:to-purple-950 dark:text-indigo-300">
                  {r.vendor_raw || "—"}
                </span>
              </td>
              <td className="py-4 font-medium text-indigo-600 dark:text-indigo-400">{r.invoice_number || "—"}</td>
              <td className="py-4 text-slate-500 dark:text-slate-400">{r.invoice_date || "—"}</td>
              <td className="py-4 font-semibold">
                {r.total_amount != null ? `${r.currency || ""} ${r.total_amount}`.trim() : "—"}
              </td>
              <td className="py-4">
                <ConfidenceBadge value={r.confidence} />
              </td>
              <td className="py-4 text-slate-600 dark:text-slate-300">{r.is_duplicate_candidate ? "Yes" : "—"}</td>
              <td className="py-4 text-right">
                <Link
                  to={`/invoices/${r.id}`}
                  className="inline-flex items-center gap-2 px-3 py-2 rounded-lg hover:bg-slate-100 dark:hover:bg-slate-800 transition text-slate-700 dark:text-slate-200 touch-manipulation"
                >
                  <i className="fas fa-eye text-slate-500 dark:text-slate-400" />
                  View
                </Link>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
