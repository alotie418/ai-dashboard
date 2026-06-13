import React from 'react';
import { useTranslation } from 'react-i18next';
import type { ExtractedInvoice } from '../services/ocrService';

interface Props {
  extracted: ExtractedInvoice;
  counterpartyLabel: string;            // 供应商 (purchase) / 客户 (sales)
  fmtMoney: (val: number) => string;
  onClose: () => void;
}

// PR-3b: read-only preview of a vision-OCR result. Shows the recognized fields ONLY — it does NOT
// write to the DB or fill any form (confirm→autofill lands in PR-3c). Nothing here is persisted;
// the extracted detail lives only in React state and is dropped when the modal closes.
const OcrPreviewModal: React.FC<Props> = ({ extracted, counterpartyLabel, fmtMoney, onClose }) => {
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
        <div className="px-6 py-4 border-t border-[#e0ddd5] flex justify-end">
          <button onClick={onClose} className="px-6 py-2 bg-[#f0eeeb] hover:bg-[#e0ddd5] text-[#4a4a48] font-medium rounded-lg transition-colors">
            {t('ocr.close')}
          </button>
        </div>
      </div>
    </div>
  );
};

export default OcrPreviewModal;
