import { getAccessToken } from "@/lib/supabaseClient";

const prefix = import.meta.env.VITE_API_PREFIX || "/api";

async function apiFetch(path: string, init: RequestInit = {}) {
  const token = (await getAccessToken())?.trim();
  if (!token) {
    throw new Error(JSON.stringify({ detail: "Not signed in — no access token. Try signing in again." }));
  }
  const headers = new Headers(init.headers);
  headers.set("Authorization", `Bearer ${token}`);
  // Some dev proxies mishandle Authorization; backend accepts this duplicate as fallback.
  headers.set("X-Supabase-Access-Token", token);
  const res = await fetch(`${prefix}${path}`, { ...init, headers, credentials: "same-origin" });
  if (!res.ok) {
    const text = await res.text();
    let msg = text || res.statusText;
    try {
      const j = JSON.parse(text) as { detail?: unknown };
      if (typeof j.detail === "string") msg = j.detail;
      else if (Array.isArray(j.detail)) msg = JSON.stringify(j.detail);
    } catch {
      /* use raw text */
    }
    throw new Error(msg);
  }
  const ct = res.headers.get("content-type");
  if (ct?.includes("application/json")) return res.json();
  return res.text();
}

export const api = {
  uploadFile: (file: File) => {
    const fd = new FormData();
    fd.append("file", file);
    return apiFetch("/upload", { method: "POST", body: fd });
  },
  uploadBatch: (files: File[]) => {
    const fd = new FormData();
    files.forEach((f) => fd.append("files", f));
    return apiFetch("/upload/batch", { method: "POST", body: fd });
  },
  processFile: (fileId: string) =>
    apiFetch(`/invoices/${fileId}/process`, { method: "POST" }),
  listInvoices: (q?: string) => apiFetch(`/invoices${q || ""}`),
  getInvoice: (id: string) => apiFetch(`/invoices/${id}`),
  getJob: (id: string) => apiFetch(`/jobs/${id}`),
  analyticsSummary: () => apiFetch("/analytics/summary"),
  analyticsMonthly: () => apiFetch("/analytics/monthly"),
  analyticsVendors: () => apiFetch("/analytics/vendors?limit=12"),
  analyticsCurrencies: () => apiFetch("/analytics/currencies"),
};
