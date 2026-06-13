import React from 'react';
import { useTranslation } from 'react-i18next';
import type { ExtractedInvoice } from '../services/ocrService';

interface Props {
  extracted: ExtractedInvoice;
  counterpartyLabel: string;            // 供应商 (purchase) / 客户 (sales)
  fmtMoney: (val: number) => string;
  onClose: () => void;
  onConfirm?: () => void;               // PR-3c: "use these values" → fill the form (no DB write)
}

// PR-3b/3c: preview of a vision-OCR result. Shows the recognized fields; when onConfirm is provided,
// a "use these values" button fills the page's add-form state (NO DB write — the user still saves
// manually). Nothing here is persisted; the extracted detail lives only in React state.
const OcrPreviewModal: React.FC<Props> = ({ extracted, counterpartyLabel, fmtMoney, onClose, onConfirm }) => {
  const { t } = useTranslation();
  const rows: { label: string; value: string }[] = [
    { label: t('tableHeaders.date'), value: extracted.date || '—' },
    { label: counterpartyLabel, value: extracted.customer || '—' },
    { label: t('tableHeaders.quantity'), value: extracted.quantity || '—' },
    { label: t('tableHeaders.totalAmountWithoutTax'), value: fmtMoney(extracted.price || 0) },
    { label: t('tableHeaders.totalTax'), value: fmtMoney(extracted.taxAmount || 0) },
    { label: t('tableHeaders.taxRate'), value: extracted.taxRate || '—' },
    { label: t('tableHeaders.totalWithTax'), value: fmtMoney(extracted.totalWithTax || 0) },
    { label: t('tableHeaders.invoiceNo'), value: extracted.invoiceNo || '—' },
  ];
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" onClick={onClose}>
      <div className="bg-white rounded-2xl w-full max-w-md shadow-xl" onClick={(e) => e.stopPropagation()}>
        <div className="px-6 py-4 border-b border-[#e0ddd5] flex items-center justify-between">
          <h3 className="text-lg font-bold text-[#191918]">{t('ocr.previewTitle')}</h3>
          <button onClick={onClose} className="text-[#5c5c5a] hover:text-[#191918]" aria-label={t('ocr.close')}>
            <i className="fas fa-times"></i>
          </button>
        </div>
        <div className="px-6 py-4 space-y-1">
          {rows.map((r, i) => (
            <div key={i} className="flex justify-between text-sm border-b border-[#f0eeeb] py-1.5">
              <span className="text-[#5c5c5a]">{r.label}</span>
              <span className="text-[#191918] font-medium text-right ml-4">{r.value}</span>
            </div>
          ))}
          <p className="text-xs text-[#5c5c5a] pt-3">{t('ocr.previewHint')}</p>
        </div>
        <div className="px-6 py-4 border-t border-[#e0ddd5] flex justify-end gap-3">
          <button onClick={onClose} className="px-6 py-2 bg-[#f0eeeb] hover:bg-[#e0ddd5] text-[#4a4a48] font-medium rounded-lg transition-colors">
            {t('ocr.close')}
          </button>
          {onConfirm && (
            <button onClick={onConfirm} className="px-6 py-2 bg-primary hover:bg-primary-hover text-white font-medium rounded-lg transition-colors">
              {t('ocr.useResult')}
            </button>
          )}
        </div>
      </div>
    </div>
  );
};

export default OcrPreviewModal;
