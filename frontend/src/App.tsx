import { useEffect, useState } from "react";
import { Navigate, Outlet, Route, Routes, useLocation, useSearchParams } from "react-router-dom";
import { AppShellNav } from "@/components/AppShellNav";
import { ThemeToggle } from "@/components/ThemeToggle";
import { useAuth } from "@/hooks/useAuth";
import { BatchPage } from "@/pages/BatchPage";
import { DashboardPage } from "@/pages/DashboardPage";
import { InvoiceDetailPage } from "@/pages/InvoiceDetailPage";
import { InvoicesListPage } from "@/pages/InvoicesListPage";
import { LoginPage } from "@/pages/LoginPage";
import { UploadPage } from "@/pages/UploadPage";

function AppLayout() {
  const { user, loading, signOut } = useAuth();
  const { pathname } = useLocation();
  const [searchParams] = useSearchParams();
  const homeTabRaw = (searchParams.get("tab") || "dashboard").toLowerCase();
  const homeTab = homeTabRaw === "settings" ? "dashboard" : homeTabRaw;
  const onDashboardRoute = pathname === "/";
  const onInvoicesListRoute = pathname === "/invoices";
  const invoicesTab = onInvoicesListRoute ? searchParams.get("tab") : null;
  const [mobileNavOpen, setMobileNavOpen] = useState(false);

  useEffect(() => {
    setMobileNavOpen(false);
  }, [pathname, searchParams.toString()]);

  useEffect(() => {
    if (!mobileNavOpen) return;
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.body.style.overflow = prev;
    };
  }, [mobileNavOpen]);

  if (loading) {
    return (
      <div className="min-h-dvh bg-[var(--app-canvas)] p-4 sm:p-6">
        <p className="text-slate-600 dark:text-slate-400">Loading session…</p>
      </div>
    );
  }
  if (!user) {
    return <Navigate to="/login" replace />;
  }

  return (
    <div className="min-h-dvh flex flex-col overflow-x-hidden bg-[var(--app-canvas)]">
      <header className="gradient-bg text-white shadow-sm shrink-0 z-50 border-b border-white/10">
        <div className="w-full px-3 sm:px-4 lg:px-6 pt-[max(0.75rem,env(safe-area-inset-top,0px))] pb-3 sm:pb-4">
          <div className="flex items-center justify-between gap-2 sm:gap-4">
            <div className="flex items-center gap-2 sm:gap-3 min-w-0 flex-1">
              <button
                type="button"
                className="lg:hidden shrink-0 flex h-11 w-11 items-center justify-center rounded-xl bg-white/15 hover:bg-white/25 transition touch-manipulation"
                aria-expanded={mobileNavOpen}
                aria-controls="mobile-drawer-nav"
                onClick={() => setMobileNavOpen((o) => !o)}
              >
                <i className={`fas text-lg ${mobileNavOpen ? "fa-times" : "fa-bars"}`} aria-hidden />
                <span className="sr-only">{mobileNavOpen ? "Close menu" : "Open menu"}</span>
              </button>
              <div className="flex items-center gap-2 sm:gap-3 min-w-0">
                <div className="w-9 h-9 sm:w-10 sm:h-10 bg-white/20 rounded-xl flex items-center justify-center shrink-0">
                  <i className="fas fa-file-invoice-dollar text-base sm:text-xl" />
                </div>
                <div className="min-w-0">
                  <h1 className="text-lg sm:text-xl font-bold truncate">InvoiceAI</h1>
                  <p className="text-[10px] sm:text-xs text-white/70 truncate">Smart Invoice Extraction</p>
                </div>
              </div>
            </div>
            <div className="flex items-center gap-1 sm:gap-2 md:gap-3 shrink-0">
              <ThemeToggle variant="inverse" />
              <button
                className="hidden sm:flex p-2 hover:bg-white/10 rounded-lg transition touch-manipulation"
                type="button"
                aria-label="Notifications"
              >
                <i className="fas fa-bell" />
              </button>
              <div className="hidden sm:flex w-8 h-8 bg-white/20 rounded-full items-center justify-center">
                <i className="fas fa-user text-sm" />
              </div>
              <button
                type="button"
                onClick={() => void signOut()}
                className="lg:hidden px-2.5 sm:px-3 py-2 bg-white/15 hover:bg-white/20 rounded-lg text-xs sm:text-sm font-semibold transition touch-manipulation whitespace-nowrap"
                aria-label="Sign out"
              >
                <span className="sm:hidden" aria-hidden>
                  <i className="fas fa-right-from-bracket" />
                </span>
                <span className="hidden sm:inline">Sign out</span>
              </button>
            </div>
          </div>
        </div>
      </header>

      <div className="flex flex-1 min-h-0 min-w-0 w-full">
        {mobileNavOpen && (
          <button
            type="button"
            className="fixed inset-0 z-40 bg-black/50 lg:hidden"
            aria-label="Close menu"
            onClick={() => setMobileNavOpen(false)}
          />
        )}

        <aside
          id="mobile-drawer-nav"
          className={[
            "fixed lg:static inset-y-0 left-0 z-50 flex min-h-0 flex-col lg:self-stretch",
            "w-[min(100%,18rem)] sm:w-72 lg:w-64 shrink-0",
            "bg-[var(--app-surface)] shadow-xl lg:shadow-sm border-r border-[var(--app-border)]",
            "transition-transform duration-200 ease-out lg:translate-x-0",
            mobileNavOpen ? "translate-x-0" : "-translate-x-full lg:translate-x-0",
          ].join(" ")}
        >
          <div className="flex shrink-0 items-center justify-between border-b border-[var(--app-border)] px-3 py-3 sm:px-4 lg:hidden">
            <span className="font-semibold text-[var(--app-text)]">Menu</span>
            <button
              type="button"
              className="flex h-10 w-10 items-center justify-center rounded-lg hover:bg-[var(--app-surface-hover)] touch-manipulation"
              onClick={() => setMobileNavOpen(false)}
              aria-label="Close menu"
            >
              <i className="fas fa-times text-[var(--app-text-muted)]" />
            </button>
          </div>

          <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain px-3 py-3 sm:px-4 sm:py-4">
            <AppShellNav
              onDashboardRoute={onDashboardRoute}
              homeTab={homeTab}
              onInvoicesListRoute={onInvoicesListRoute}
              invoicesTab={invoicesTab}
              onNavigate={() => setMobileNavOpen(false)}
            />
          </div>

          <div className="shrink-0 border-t border-[var(--app-border)] bg-[var(--app-surface)] p-3 sm:p-4 pb-[max(0.75rem,env(safe-area-inset-bottom,0px))]">
            <button
              type="button"
              onClick={() => {
                setMobileNavOpen(false);
                void signOut();
              }}
              className="flex w-full min-h-11 items-center justify-center gap-2 rounded-xl border border-[var(--app-border)] bg-[var(--app-surface-hover)] px-4 py-2.5 text-sm font-semibold text-[var(--app-text)] transition hover:bg-slate-200/80 dark:hover:bg-slate-700/80 touch-manipulation"
            >
              <i className="fas fa-right-from-bracket text-[var(--app-text-muted)]" aria-hidden />
              Log out
            </button>
          </div>
        </aside>

        <main className="flex-1 min-w-0 min-h-0 overflow-y-auto w-full bg-[var(--app-canvas)] p-3 sm:p-4 md:p-6 lg:px-8 pb-[max(0.75rem,env(safe-area-inset-bottom,0px))]">
          <Outlet />
        </main>
      </div>
    </div>
  );
}

export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<LoginPage />} />
      <Route element={<AppLayout />}>
        <Route path="/" element={<DashboardPage />} />
        <Route path="/upload" element={<UploadPage />} />
        <Route path="/batch" element={<BatchPage />} />
        <Route path="/invoices" element={<InvoicesListPage />} />
        <Route path="/invoices/:id" element={<InvoiceDetailPage />} />
      </Route>
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
}
