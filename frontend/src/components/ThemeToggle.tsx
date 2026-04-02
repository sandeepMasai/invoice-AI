import { useTheme } from "@/context/ThemeContext";

type Variant = "inverse" | "default";

/** Single control: switches between light and dark (explicit preference, not system). */
export function ThemeToggle({ variant = "inverse" }: { variant?: Variant }) {
  const { resolved, setTheme } = useTheme();
  const isDark = resolved === "dark";

  const toggle = () => {
    setTheme(isDark ? "light" : "dark");
  };

  const base =
    "inline-flex h-11 w-11 shrink-0 items-center justify-center rounded-xl text-base transition touch-manipulation focus:outline-none focus-visible:ring-2 focus-visible:ring-offset-2";

  const styles =
    variant === "inverse"
      ? `${base} border border-white/25 bg-white/15 text-white hover:bg-white/25 focus-visible:ring-white focus-visible:ring-offset-slate-900`
      : `${base} border border-[var(--app-border)] bg-[var(--app-surface)] text-[var(--app-text)] shadow-sm hover:bg-[var(--app-surface-hover)] focus-visible:ring-indigo-500 focus-visible:ring-offset-[var(--app-canvas)] dark:focus-visible:ring-offset-slate-900`;

  const label = isDark ? "Switch to light mode" : "Switch to dark mode";
  const icon = isDark ? "fa-sun" : "fa-moon";

  return (
    <button
      type="button"
      onClick={toggle}
      className={styles}
      aria-label={label}
      title={label}
    >
      <i className={`fas ${icon}`} aria-hidden />
    </button>
  );
}
