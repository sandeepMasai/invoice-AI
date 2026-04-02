import { createClient, type SupabaseClient } from "@supabase/supabase-js";

const url = import.meta.env.VITE_SUPABASE_URL || "";
const anon = import.meta.env.VITE_SUPABASE_ANON_KEY || "";

function missingConfigMessage() {
  return "Missing Supabase config. Check VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY in .env";
}

let _client: SupabaseClient | null = null;

function getClient(): SupabaseClient {
  if (!url.trim() || !anon.trim()) {
    console.error(missingConfigMessage());
    throw new Error(missingConfigMessage());
  }

  if (!_client) {
    _client = createClient(url.trim(), anon.trim());
  }

  return _client;
}

export const supabase = new Proxy({} as SupabaseClient, {
  get(_target, prop, receiver) {
    const client = getClient();
    const value = Reflect.get(client, prop, receiver);
    return typeof value === "function" ? value.bind(client) : value;
  },
});

function sleep(ms: number) {
  return new Promise<void>((r) => setTimeout(r, ms));
}

export async function getAccessToken(): Promise<string | null> {
  try {
    for (let attempt = 0; attempt < 5; attempt++) {
      const { data, error } = await supabase.auth.getSession();

      if (error) {
        console.error("Session error:", error);
      }

      let session = data.session;

      if (session) {
        let token: string | undefined = session.access_token?.trim();

        // refresh if expiring
        if (!token || (session.expires_at! * 1000 < Date.now() + 60000)) {
          const { data: refreshed, error: refreshError } =
            await supabase.auth.refreshSession();

          if (refreshError) {
            console.error("Refresh error:", refreshError);
          }

          const next = refreshed.session?.access_token?.trim();
          if (next) token = next;
        }

        if (token) {
          return token;
        }
      }

      await sleep(100);
    }

    console.warn("❌ No token found after retries");
    return null;
  } catch (err) {
    console.error("🔥 getAccessToken failed:", err);
    return null;
  }
}