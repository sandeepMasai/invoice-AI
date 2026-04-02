import { useCallback, useId, useMemo, useState } from "react";
import { api } from "@/services/api";
import { getAccessToken } from "@/lib/supabaseClient";

type Props = {
  multiple?: boolean;
  onDone?: () => void;
};

export function FileUploader({ multiple = false, onDone }: Props) {
  const fileInputId = useId();
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [drag, setDrag] = useState(false);
  const [autoProcess, setAutoProcess] = useState(true);
  const [progressPct, setProgressPct] = useState<number | null>(null);
  const [progressLabel, setProgressLabel] = useState<string | null>(null);

  const apiPrefix = useMemo(() => import.meta.env.VITE_API_PREFIX || "/api", []);

  async function xhrUpload(
    url: string,
    body: FormData,
    onProgress: (pct: number) => void,
  ): Promise<unknown> {
    const token = (await getAccessToken())?.trim();
    if (!token) throw new Error(JSON.stringify({ detail: "Not signed in — no access token. Try signing in again." }));

    return await new Promise((resolve, reject) => {
      const xhr = new XMLHttpRequest();
      xhr.open("POST", url, true);
      xhr.setRequestHeader("Authorization", `Bearer ${token}`);
      xhr.setRequestHeader("X-Supabase-Access-Token", token);

      xhr.upload.onprogress = (evt) => {
        if (!evt.lengthComputable) return;
        const pct = Math.max(0, Math.min(100, Math.round((evt.loaded / evt.total) * 100)));
        onProgress(pct);
      };

      xhr.onerror = () => reject(new Error("Upload failed (network error)"));
      xhr.onabort = () => reject(new Error("Upload cancelled"));
      xhr.onload = () => {
        const text = xhr.responseText || "";
        if (xhr.status < 200 || xhr.status >= 300) {
          reject(new Error(text || `Upload failed (HTTP ${xhr.status})`));
          return;
        }
        try {
          resolve(text ? JSON.parse(text) : {});
        } catch {
          resolve(text);
        }
      };
      xhr.send(body);
    });
  }

  const handleFiles = useCallback(
    async (list: FileList | null) => {
      if (!list?.length) return;
      setBusy(true);
      setMsg(null);
      setProgressPct(0);
      try {
        const files = Array.from(list);
        if (multiple) {
          setProgressLabel(`Uploading ${files.length} files…`);
          const fd = new FormData();
          files.forEach((f) => fd.append("files", f));
          const res = (await xhrUpload(`${apiPrefix}/upload/batch`, fd, (p) => setProgressPct(p))) as {
            id: string;
          }[];
          setMsg(`Uploaded ${res.length} files.`);
          if (autoProcess) {
            setProgressLabel(`Queuing ${res.length} jobs…`);
            setProgressPct(null);
            for (const r of res) {
              await api.processFile(r.id);
            }
            setMsg(`Uploaded and queued ${res.length} jobs.`);
          }
        } else {
          for (const f of files) {
            setProgressLabel(`Uploading: ${f.name}`);
            setProgressPct(0);
            const fd = new FormData();
            fd.append("file", f);
            const row = (await xhrUpload(`${apiPrefix}/upload`, fd, (p) => setProgressPct(p))) as {
              id: string;
            };
            if (autoProcess) {
              setProgressLabel(`Upload complete. Queuing processing…`);
              setProgressPct(null);
              await api.processFile(row.id);
              setMsg(`Uploaded & processing: ${f.name}`);
            } else {
              setMsg(`Uploaded: ${f.name}`);
            }
          }
        }
        onDone?.();
      } catch (e) {
        setMsg(e instanceof Error ? e.message : "Upload failed");
      } finally {
        setBusy(false);
        setProgressLabel(null);
        setProgressPct(null);
      }
    },
    [apiPrefix, autoProcess, multiple, onDone],
  );

  return (
    <div className="space-y-4">
      <div className="flex flex-col items-center justify-center gap-3 sm:flex-row sm:justify-between text-center sm:text-left">
        <label className="flex items-center gap-3 text-sm text-slate-600 dark:text-slate-300 select-none">
          <input
            type="checkbox"
            checked={autoProcess}
            onChange={(e) => setAutoProcess(e.target.checked)}
            className="h-4 w-4 rounded border-slate-300 dark:border-slate-600 bg-[var(--app-surface)] text-indigo-600 focus:ring-indigo-500"
          />
          Start processing after upload
        </label>
        <div className="text-sm text-slate-400 dark:text-slate-500">
          <i className="fas fa-shield-halved mr-2" />
          Secure upload
        </div>
      </div>

      <div
        className={[
          "rounded-xl p-10 text-center cursor-pointer transition border-2 border-dashed",
          drag
            ? "border-indigo-400 bg-indigo-50/60 dark:bg-indigo-950/40"
            : "border-slate-300 dark:border-slate-600 hover:border-indigo-400 hover:bg-indigo-50/40 dark:hover:bg-indigo-950/30",
          busy ? "opacity-70 cursor-not-allowed" : "",
        ].join(" ")}
        onDragOver={(e) => {
          e.preventDefault();
          setDrag(true);
        }}
        onDragLeave={() => setDrag(false)}
        onDrop={(e) => {
          e.preventDefault();
          setDrag(false);
          void handleFiles(e.dataTransfer.files);
        }}
      >
        <div className="space-y-4">
          <div className="w-20 h-20 mx-auto bg-gradient-to-br from-indigo-100 to-purple-100 dark:from-indigo-950 dark:to-purple-950 rounded-full flex items-center justify-center">
            <i className="fas fa-cloud-upload-alt text-3xl text-indigo-500 dark:text-indigo-400" />
          </div>
          <div>
            <p className="text-xl font-semibold text-slate-700 dark:text-slate-200">
              Drag & drop {multiple ? "files" : "a file"} here
            </p>
            <p className="text-slate-500 dark:text-slate-400 mt-2">or use the button below</p>
          </div>
          <p className="text-sm text-slate-400 dark:text-slate-500">Supported: PDF, PNG, JPG, WebP</p>
        </div>

        <div className="mt-6 flex flex-col items-center justify-center gap-2">
          <input
            id={fileInputId}
            type="file"
            accept=".pdf,image/*"
            multiple={multiple}
            disabled={busy}
            onChange={(e) => void handleFiles(e.target.files)}
            className="sr-only"
          />
          <label
            htmlFor={fileInputId}
            className={[
              "inline-flex cursor-pointer items-center justify-center gap-2 rounded-lg px-6 py-3 text-sm font-semibold shadow-sm transition touch-manipulation",
              "bg-indigo-600 text-white hover:bg-indigo-700 dark:bg-indigo-500 dark:hover:bg-indigo-600",
              busy ? "pointer-events-none opacity-50" : "",
            ].join(" ")}
          >
            <i className="fas fa-folder-open" aria-hidden />
            Choose file{multiple ? "s" : ""}
          </label>
          <p className="text-xs text-slate-400 dark:text-slate-500">or drag and drop above</p>
        </div>

        {busy && (
          <div className="mt-6 max-w-md mx-auto text-center sm:text-left">
            <div className="flex items-center justify-between mb-2">
              <p className="text-sm text-slate-600 dark:text-slate-300 m-0">
                {progressLabel || "Working…"}
              </p>
              {progressPct != null && (
                <span className="text-sm font-semibold text-slate-700 dark:text-slate-200">{progressPct}%</span>
              )}
            </div>
            {progressPct != null && (
              <div className="w-full h-2 bg-slate-200 dark:bg-slate-700 rounded-full overflow-hidden">
                <div
                  className="h-2 rounded-full"
                  style={{
                    width: `${progressPct}%`,
                    background: "linear-gradient(90deg, #4f46e5, #6366f1)",
                    transition: "width 0.35s ease",
                  }}
                />
              </div>
            )}
          </div>
        )}

        {msg && (
          <div className="mt-6 max-w-md mx-auto">
            <div className="rounded-lg border border-[var(--app-border)] bg-[var(--app-surface)] px-4 py-3 text-sm text-[var(--app-text)] text-center">
              {msg}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
