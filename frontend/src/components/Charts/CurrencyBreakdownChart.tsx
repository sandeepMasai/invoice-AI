import { Cell, Pie, PieChart, ResponsiveContainer, Tooltip } from "recharts";

type Row = { currency: string; total_spend: number };

const COLORS = ["#3dd6c3", "#6ea8ff", "#e6c07b", "#f07178", "#b388ff"];

export function CurrencyBreakdownChart({ data }: { data: Row[] }) {
  const chart = data.map((d) => ({ name: d.currency || "?", value: d.total_spend }));
  if (chart.length === 0) {
    return (
      <div className="text-slate-500 dark:text-slate-400 text-sm py-8 text-center min-h-[200px] sm:min-h-[260px]">
        No currency breakdown yet.
      </div>
    );
  }
  return (
    <div className="w-full h-[200px] sm:h-[260px] min-h-[180px]">
      <ResponsiveContainer>
        <PieChart>
          <Pie data={chart} dataKey="value" nameKey="name" innerRadius={50} outerRadius={90} paddingAngle={2}>
            {chart.map((_, i) => (
              <Cell key={i} fill={COLORS[i % COLORS.length]} />
            ))}
          </Pie>
          <Tooltip
            contentStyle={{
              background: "var(--chart-tooltip-bg)",
              border: "1px solid var(--chart-tooltip-border)",
            }}
            labelStyle={{ color: "var(--chart-tooltip-fg)" }}
          />
        </PieChart>
      </ResponsiveContainer>
    </div>
  );
}
