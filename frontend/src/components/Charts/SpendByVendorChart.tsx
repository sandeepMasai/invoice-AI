import {
  Bar,
  BarChart,
  CartesianGrid,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";

type Row = {
  vendor_display?: string | null;
  vendor_key?: string | null;
  total_spend?: number | string | null;
  currency?: string | null;
};

/** Sum spend per vendor label (across currencies) for clearer bars. */
function buildChartPoints(rows: Row[]) {
  const m = new Map<string, { spend: number; currencies: Set<string> }>();
  for (const d of rows) {
    const label = String(d.vendor_display ?? d.vendor_key ?? "Unknown").trim() || "Unknown";
    const raw = d.total_spend;
    const spend = typeof raw === "number" ? raw : Number(raw);
    const s = Number.isFinite(spend) ? spend : 0;
    const cur = String(d.currency ?? "").trim();
    const ex = m.get(label) ?? { spend: 0, currencies: new Set<string>() };
    ex.spend += s;
    if (cur) ex.currencies.add(cur);
    m.set(label, ex);
  }
  return [...m.entries()]
    .map(([name, { spend, currencies }]) => ({
      name: name.length > 18 ? `${name.slice(0, 16)}…` : name,
      spend,
      currencyHint: currencies.size <= 1 ? [...currencies][0] ?? "" : "multiple",
    }))
    .sort((a, b) => b.spend - a.spend)
    .slice(0, 15);
}

export function SpendByVendorChart({ data }: { data: Row[] }) {
  const chart = buildChartPoints(Array.isArray(data) ? data : []);
  if (chart.length === 0) {
    return (
      <div className="text-slate-500 dark:text-slate-400 text-sm py-8 text-center min-h-[220px] sm:min-h-[280px]">
        No vendor spend data yet.
      </div>
    );
  }
  return (
    <div className="w-full min-w-0 h-[220px] sm:h-[280px] min-h-[200px]">
      <ResponsiveContainer width="100%" height="100%" minWidth={0} minHeight={200}>
        <BarChart data={chart} margin={{ top: 8, right: 8, left: 4, bottom: 48 }}>
          <CartesianGrid strokeDasharray="3 3" stroke="var(--chart-grid)" />
          <XAxis
            dataKey="name"
            tick={{ fill: "var(--chart-axis)", fontSize: 10 }}
            interval={0}
            angle={-32}
            textAnchor="end"
            height={56}
          />
          <YAxis tick={{ fill: "var(--chart-axis)", fontSize: 11 }} width={44} />
          <Tooltip
            contentStyle={{
              background: "var(--chart-tooltip-bg)",
              border: "1px solid var(--chart-tooltip-border)",
            }}
            labelStyle={{ color: "var(--chart-tooltip-fg)" }}
            formatter={(value: number) => [Math.round(value).toLocaleString(), "Spend"]}
            labelFormatter={(_label, payload) => {
              const p = payload?.[0]?.payload as { currencyHint?: string } | undefined;
              const h = p?.currencyHint;
              if (h && h !== "multiple") return `${_label} (${h})`;
              if (h === "multiple") return `${_label} (multiple currencies)`;
              return _label;
            }}
          />
          <Bar dataKey="spend" fill="var(--chart-line-mint)" radius={[6, 6, 0, 0]} maxBarSize={48} />
        </BarChart>
      </ResponsiveContainer>
    </div>
  );
}
