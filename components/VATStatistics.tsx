
import React from 'react';
import { useTranslation } from 'react-i18next';
import { VATData } from '../types';

interface Props {
  data: VATData;
}

const VATStatistics: React.FC<Props> = ({ data }) => {
  const { t } = useTranslation();
  if (!data) return null;
  const formatVal = (val: number) => `¥${(val || 0).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

  return (
    <div className="bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl overflow-hidden flex flex-col h-full" style={{boxShadow: '0 4px 24px rgba(0,0,0,0.06)'}}>
      <div className="p-6 border-b border-[#e0ddd5] flex items-center space-x-3">
        <i className="fas fa-calculator text-lg text-[#4a4a48]"></i>
        <h3 className="text-lg font-bold text-[#191918]">{t('dashboard.vatTitle')}</h3>
      </div>

      <div className="flex-1 flex flex-col">
        <div className="px-6 py-4 space-y-4">
          <div className="flex justify-between items-center">
            <span className="text-sm text-[#4a4a48]">{t('dashboard.vatInputTotal')}</span>
            <span className="text-base font-semibold text-[#191918]">{formatVal(data.cumulativeInput)}</span>
          </div>
          <div className="flex justify-between items-center">
            <span className="text-sm text-[#4a4a48]">{t('dashboard.vatOutputTotal')}</span>
            <span className="text-base font-semibold text-[#191918]">{formatVal(data.cumulativeOutput)}</span>
          </div>
        </div>

        <div className="px-6 py-5 border-t border-dashed border-[#e0ddd5] space-y-4 bg-[#d97757]/5">
          <div className="flex justify-between items-center">
            <span className="text-sm text-[#d97757]/80">{t('dashboard.vatInputCertified')}</span>
            <span className="text-base font-semibold text-[#d97757]">{formatVal(data.certifiedInput)}</span>
          </div>
          <div className="flex justify-between items-center">
            <span className="text-sm text-[#d97757]/80">{t('dashboard.vatOutputInvoiced')}</span>
            <span className="text-base font-semibold text-[#d97757]">{formatVal(data.invoicedOutput)}</span>
          </div>
        </div>

        <div className="mt-auto px-6 py-6 border-t border-[#e0ddd5] bg-orange-500/5">
          <div className="flex justify-between items-center">
            <span className="text-base font-bold text-[#191918]">{t('dashboard.vatEstimated')}</span>
            <span className="text-xl font-bold text-orange-500">{formatVal(data.estimatedPayable)}</span>
          </div>
        </div>
      </div>
    </div>
  );
};

export default VATStatistics;
