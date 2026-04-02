import {
  CartesianGrid,
  Line,
  LineChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";

type Row = { month: string; total_spend: number; currency: string };

function monthSortKey(m: string | undefined): number {
  const t = Date.parse(m || "");
  return Number.isNaN(t) ? 0 : t;
}

export function MonthlyTrendChart({ data }: { data: Row[] }) {
  const sorted = [...data].sort((a, b) => monthSortKey(a.month) - monthSortKey(b.month));
  const chart = sorted.map((d) => ({
    month: d.month?.slice(0, 7) || "",
    spend: d.total_spend,
  }));
  if (chart.length === 0) {
    return (
      <div className="text-slate-500 dark:text-slate-400 text-sm py-8 text-center min-h-[220px] sm:min-h-[280px]">
        No monthly data yet.
      </div>
    );
  }
  return (
    <div className="w-full h-[220px] sm:h-[280px] min-h-[200px]">
      <ResponsiveContainer>
        <LineChart data={chart} margin={{ top: 8, right: 8, left: 0, bottom: 0 }}>
          <CartesianGrid strokeDasharray="3 3" stroke="var(--chart-grid)" />
          <XAxis dataKey="month" tick={{ fill: "var(--chart-axis)", fontSize: 11 }} />
          <YAxis tick={{ fill: "var(--chart-axis)", fontSize: 11 }} />
          <Tooltip
            contentStyle={{
              background: "var(--chart-tooltip-bg)",
              border: "1px solid var(--chart-tooltip-border)",
            }}
            labelStyle={{ color: "var(--chart-tooltip-fg)" }}
          />
          <Line
            type="monotone"
            dataKey="spend"
            stroke="var(--chart-line-amber)"
            strokeWidth={2}
            dot={false}
          />
        </LineChart>
      </ResponsiveContainer>
    </div>
  );
}
