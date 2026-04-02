import { FileUploader } from "@/components/FileUploader";
import { useInvoices } from "@/hooks/useInvoices";

export function BatchPage() {
  const { refresh } = useInvoices();
  return (
    <div className="space-y-4 sm:space-y-6 min-w-0">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <h2 className="text-xl sm:text-2xl font-bold text-slate-800 dark:text-slate-100">Batch upload</h2>
          <p className="text-slate-500 dark:text-slate-400 mt-1 text-sm sm:text-base">Queue up to 20 files (requires batch enabled on API).</p>
        </div>
        <p className="text-xs sm:text-sm text-slate-500 dark:text-slate-400 shrink-0">Supported: PDF, PNG, JPG, WebP</p>
      </div>

      <div className="card-gradient rounded-xl sm:rounded-2xl p-4 sm:p-6 max-w-2xl mx-auto w-full">
        <FileUploader multiple onDone={() => void refresh()} />
      </div>
    </div>
  );
}
