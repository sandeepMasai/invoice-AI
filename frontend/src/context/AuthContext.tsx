import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import type { AuthError, Session, User } from "@supabase/supabase-js";
import { supabase } from "@/lib/supabaseClient";

/** Magic-link landing URL (must match Supabase Auth redirect allow list). */
const PRODUCTION_EMAIL_REDIRECT = "https://invoice-ai-1-4fpp.onrender.com";

function friendlyAuthEmailError(error: AuthError): string {
  const msg = (error.message || "").toLowerCase();
  const code = "code" in error ? String((error as { code?: string }).code || "") : "";
  if (
    code === "over_email_send_rate_limit" ||
    msg.includes("rate limit") ||
    msg.includes("email rate") ||
    msg.includes("too many requests")
  ) {
    return "Email rate limit reached. Wait a few minutes before requesting another link, or ask your project admin to enable custom SMTP in Supabase (Authentication → Emails) for higher limits.";
  }
  return error.message;
}

type AuthState = {
  user: User | null;
  session: Session | null;
  loading: boolean;
  signInMagicLink: (email: string) => Promise<void>;
  signOut: () => Promise<void>;
};

const AuthContext = createContext<AuthState | undefined>(undefined);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    // Register listener before getSession() so INITIAL_SESSION / refresh races don’t leave a null session on first paint.
    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((_event, sess) => {
      setSession(sess);
    });
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session ?? null);
      setLoading(false);
    });
    return () => subscription.unsubscribe();
  }, []);

  const signInMagicLink = useCallback(async (email: string) => {
    const local =
      window.location.hostname === "localhost" ||
      window.location.hostname === "127.0.0.1";
    const emailRedirectTo = local
      ? `${window.location.origin}/`
      : `${PRODUCTION_EMAIL_REDIRECT.replace(/\/$/, "")}/`;
    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: { emailRedirectTo },
    });
    if (error) throw new Error(friendlyAuthEmailError(error));
  }, []);

  const signOut = useCallback(async () => {
    await supabase.auth.signOut();
  }, []);

  const value = useMemo(
    () => ({
      user: session?.user ?? null,
      session,
      loading,
      signInMagicLink,
      signOut,
    }),
    [session, loading, signInMagicLink, signOut],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuthContext() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuthContext outside AuthProvider");
  return ctx;
}
