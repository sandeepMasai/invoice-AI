import { FileUploader } from "@/components/FileUploader";
import { useInvoices } from "@/hooks/useInvoices";
import { useNavigate } from "react-router-dom";

export function UploadPage() {
  const { refresh } = useInvoices();
  const navigate = useNavigate();
  return (
    <div className="space-y-4 sm:space-y-6 min-w-0">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <h2 className="text-xl sm:text-2xl font-bold text-slate-800 dark:text-slate-100">Upload Invoices</h2>
          <p className="text-slate-500 dark:text-slate-400 mt-1 text-sm sm:text-base">Upload invoice files for AI-powered extraction</p>
        </div>
        <p className="text-xs sm:text-sm text-slate-500 dark:text-slate-400 shrink-0">Supported: PDF, PNG, JPG, WebP</p>
      </div>

      <div className="card-gradient rounded-xl sm:rounded-2xl p-4 sm:p-6 max-w-2xl mx-auto w-full">
        <FileUploader
          onDone={() => {
            void refresh();
            navigate("/");
          }}
        />
      </div>
    </div>
  );
}
