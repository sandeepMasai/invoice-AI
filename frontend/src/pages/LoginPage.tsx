import { useState } from "react";
import { Navigate } from "react-router-dom";
import { ThemeToggle } from "@/components/ThemeToggle";
import { useAuth } from "@/hooks/useAuth";

export function LoginPage() {
  const { user, signInMagicLink } = useAuth();
  const [email, setEmail] = useState("");
  const [sent, setSent] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  if (user) return <Navigate to="/" replace />;

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setErr(null);
    setBusy(true);
    try {
      await signInMagicLink(email);
      setSent(true);
    } catch (e2) {
      setErr(e2 instanceof Error ? e2.message : "Could not send link");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="relative min-h-dvh flex items-center justify-center bg-[var(--app-canvas)] p-4 sm:p-6 pt-[max(1rem,env(safe-area-inset-top,0px))] pb-[max(1rem,env(safe-area-inset-bottom,0px))]">
      <div className="absolute right-3 top-[max(0.75rem,env(safe-area-inset-top,0px))] sm:right-6 sm:top-[max(1rem,env(safe-area-inset-top,0px))]">
        <ThemeToggle variant="default" />
      </div>
      <div className="w-full max-w-md card-gradient rounded-xl sm:rounded-2xl p-6 sm:p-8">
        <div className="flex items-center gap-3 mb-6">
          <div className="w-11 h-11 rounded-xl flex items-center justify-center text-white gradient-bg shadow-sm">
            <i className="fas fa-file-invoice-dollar" />
          </div>
          <div>
            <h1 className="text-xl font-extrabold text-[var(--app-text)] leading-tight">InvoiceAI</h1>
            <p className="text-sm text-[var(--app-text-muted)]">Sign in to continue</p>
          </div>
        </div>

        <p className="text-[var(--app-text-muted)] text-sm mb-6">We’ll email you a magic link (Supabase Auth).</p>

        {sent ? (
          <div className="rounded-lg border border-[var(--app-border)] bg-[var(--app-surface)] px-4 py-3 text-sm text-[var(--app-text)]">
            <i className="fas fa-envelope mr-2 text-indigo-600 dark:text-indigo-400" />
            Check your inbox for the login link.
          </div>
        ) : (
          <form onSubmit={onSubmit} className="space-y-4">
            <div>
              <label className="block text-sm font-medium text-[var(--app-text)] mb-2" htmlFor="email">
                Email
              </label>
              <input
                id="email"
                type="email"
                required
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                placeholder="you@example.com"
                className="w-full px-4 py-2 rounded-lg text-sm bg-[var(--app-surface)] text-[var(--app-text)] border border-[var(--app-border)] placeholder:text-[var(--app-text-muted)] focus:ring-2 focus:ring-indigo-500 focus:border-transparent"
              />
            </div>

            {err && <p className="text-sm text-red-600 dark:text-red-400">{err}</p>}

            <button
              type="submit"
              disabled={busy}
              className="w-full px-4 py-3 bg-gradient-to-r from-indigo-500 to-purple-500 text-white rounded-lg font-semibold hover:shadow-lg transition disabled:opacity-60 disabled:cursor-not-allowed"
            >
              {busy ? "Sending…" : "Send magic link"}
            </button>
          </form>
        )}
      </div>
    </div>
  );
}
