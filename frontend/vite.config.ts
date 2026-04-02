import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

/** Parse .env-style files without extra deps (Vite already does this internally; this guarantees repo-root load in ESM). */
function parseEnvFile(filePath: string): Record<string, string> {
  if (!fs.existsSync(filePath)) return {};
  const raw = fs.readFileSync(filePath, "utf8");
  const out: Record<string, string> = {};
  for (const line of raw.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq).trim();
    let val = trimmed.slice(eq + 1).trim();
    if (
      (val.startsWith('"') && val.endsWith('"')) ||
      (val.startsWith("'") && val.endsWith("'"))
    ) {
      val = val.slice(1, -1);
    }
    out[key] = val;
  }
  return out;
}

function mergeRootEnv(repoRoot: string, mode: string) {
  const names = [
    ".env",
    ".env.local",
    `.env.${mode}`,
    `.env.${mode}.local`,
  ];
  let merged: Record<string, string> = {};
  for (const n of names) {
    merged = { ...merged, ...parseEnvFile(path.join(repoRoot, n)) };
  }
  return merged;
}

export default defineConfig(({ mode }) => {
  const repoRoot = path.resolve(__dirname, "..");
  const fileEnv = mergeRootEnv(repoRoot, mode);
  const viteEnv = loadEnv(mode, repoRoot, ["VITE_", "SUPABASE_"]);

  const supabaseUrl =
    viteEnv.VITE_SUPABASE_URL ||
    viteEnv.SUPABASE_URL ||
    fileEnv.VITE_SUPABASE_URL ||
    fileEnv.SUPABASE_URL ||
    "";
  const supabaseAnon =
    viteEnv.VITE_SUPABASE_ANON_KEY ||
    viteEnv.SUPABASE_ANON_KEY ||
    fileEnv.VITE_SUPABASE_ANON_KEY ||
    fileEnv.SUPABASE_ANON_KEY ||
    "";

  const apiUrl =
    viteEnv.VITE_API_URL ||
    viteEnv.BACKEND_URL ||
    fileEnv.VITE_API_URL ||
    fileEnv.BACKEND_URL ||
    "http://localhost:8001";
  const apiPrefix =
    viteEnv.VITE_API_PREFIX || fileEnv.VITE_API_PREFIX || "/api";

  return {
    envDir: repoRoot,
    define: {
      "import.meta.env.VITE_SUPABASE_URL": JSON.stringify(supabaseUrl),
      "import.meta.env.VITE_SUPABASE_ANON_KEY": JSON.stringify(supabaseAnon),
      "import.meta.env.VITE_API_PREFIX": JSON.stringify(apiPrefix),
    },
    plugins: [react(), tailwindcss()],
    resolve: {
      alias: { "@": path.resolve(__dirname, "src") },
    },
    server: {
      port: 5173,
      proxy: {
        [apiPrefix]: {
          target: apiUrl,
          changeOrigin: true,
          rewrite: (p) => p.replace(new RegExp(`^${escapeRegex(apiPrefix)}`), ""),
          configure: (proxy) => {
            proxy.on("proxyReq", (proxyReq, req) => {
              const auth = pickHeader(req, "authorization");
              if (auth) proxyReq.setHeader("Authorization", auth);
              const x = pickHeader(req, "x-supabase-access-token");
              if (x) proxyReq.setHeader("X-Supabase-Access-Token", x);
            });
          },
        },
      },
    },
  };
});

function escapeRegex(s: string) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** Node may expose duplicate headers as string | string[]. */
function pickHeader(req: { headers: Record<string, string | string[] | undefined> }, name: string) {
  const v = req.headers[name];
  if (v == null) return undefined;
  return Array.isArray(v) ? v[0] : v;
}
