import { NavLink } from "react-router-dom";

function navClass({ isActive }: { isActive: boolean }) {
  return `sidebar-item p-3 rounded-lg cursor-pointer transition flex items-center min-h-[44px] touch-manipulation ${isActive ? "active" : ""}`;
}

type AppShellNavProps = {
  onDashboardRoute: boolean;
  homeTab: string;
  onInvoicesListRoute: boolean;
  invoicesTab: string | null;
  onNavigate?: () => void;
};

/** Shared sidebar / mobile drawer links. */
export function AppShellNav({
  onDashboardRoute,
  homeTab,
  onInvoicesListRoute,
  invoicesTab,
  onNavigate,
}: AppShellNavProps) {
  const invTab = (invoicesTab || "").toLowerCase();
  return (
    <nav className="space-y-1 sm:space-y-2" onClick={() => onNavigate?.()} aria-label="Main">
      <NavLink
        to="/"
        className={() =>
          navClass({
            isActive: onDashboardRoute && homeTab === "dashboard",
          })
        }
        end
      >
        <i className="fas fa-chart-pie w-5 mr-3 text-[var(--app-text-muted)] shrink-0" />
        <span className="text-[var(--app-text)] font-medium text-sm sm:text-base">Dashboard</span>
      </NavLink>
      <NavLink
        to="/?tab=analytics"
        className={() =>
          navClass({
            isActive: onDashboardRoute && homeTab === "analytics",
          })
        }
      >
        <i className="fas fa-chart-bar w-5 mr-3 text-[var(--app-text-muted)] shrink-0" />
        <span className="text-[var(--app-text)] font-medium text-sm sm:text-base">Analytics</span>
      </NavLink>
      <NavLink to="/upload" className={({ isActive }) => navClass({ isActive })}>
        <i className="fas fa-cloud-upload-alt w-5 mr-3 text-[var(--app-text-muted)] shrink-0" />
        <span className="text-[var(--app-text)] font-medium text-sm sm:text-base">Upload Invoice</span>
      </NavLink>
      <NavLink to="/batch" className={({ isActive }) => navClass({ isActive })}>
        <i className="fas fa-layer-group w-5 mr-3 text-[var(--app-text-muted)] shrink-0" />
        <span className="text-[var(--app-text)] font-medium text-sm sm:text-base">Batch</span>
      </NavLink>
      <NavLink
        to="/invoices"
        className={() =>
          navClass({
            isActive: onInvoicesListRoute && invTab !== "vendors",
          })
        }
      >
        <i className="fas fa-file-alt w-5 mr-3 text-[var(--app-text-muted)] shrink-0" />
        <span className="text-[var(--app-text)] font-medium text-sm sm:text-base">All Invoices</span>
      </NavLink>
      <NavLink
        to="/invoices?tab=vendors"
        className={() =>
          navClass({
            isActive: onInvoicesListRoute && invTab === "vendors",
          })
        }
      >
        <i className="fas fa-building w-5 mr-3 text-[var(--app-text-muted)] shrink-0" />
        <span className="text-[var(--app-text)] font-medium text-sm sm:text-base">Vendors</span>
      </NavLink>
    </nav>
  );
}
