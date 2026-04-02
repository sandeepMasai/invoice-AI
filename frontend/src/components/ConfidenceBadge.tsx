export function ConfidenceBadge({ value }: { value: number | null | undefined }) {
  if (value == null) return <span className="pill pill-warn">n/a</span>;
  const pct = Math.round(value * 100);
  let cls = "pill-ok";
  if (pct < 55) cls = "pill-bad";
  else if (pct < 75) cls = "pill-warn";
  return <span className={`pill ${cls}`}>{pct}%</span>;
}
