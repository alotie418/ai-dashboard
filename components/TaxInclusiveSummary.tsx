
import React from 'react';
import { useTranslation } from 'react-i18next';
import { TaxInclusiveSummaryData } from '../types';
import { getTaxLabel, formatMoney } from './accountingHelpers';

interface Props {
  data: TaxInclusiveSummaryData;
  accountingLocale?: string;
}

const TaxInclusiveSummary: React.FC<Props> = ({ data, accountingLocale = 'CN' }) => {
  const { i18n } = useTranslation();
  if (!data) return null;
  const uiLang = i18n.language;
  const label = (key: string) => getTaxLabel(accountingLocale, uiLang, key);
  const fmt = (val: number) => formatMoney(val || 0, accountingLocale, uiLang);

  return (
    <div className="bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl overflow-hidden flex flex-col h-full" style={{boxShadow: '0 4px 24px rgba(0,0,0,0.06)'}}>
      <div className="p-6 border-b border-[#e0ddd5] flex items-center space-x-3">
        <i className="fas fa-balance-scale text-lg text-emerald-400"></i>
        <h3 className="text-lg font-bold text-[#191918] whitespace-nowrap">{label('taxSummaryTitle')}</h3>
      </div>
      <div className="flex-1 flex flex-col">
        <div className="px-6 py-5 space-y-5">
          <div className="flex justify-between items-center">
            <span className="text-sm text-[#4a4a48] font-medium">{label('purchaseTotal')}</span>
            <span className="text-base font-semibold text-[#191918]">{fmt(data.purchaseTotal)}</span>
          </div>
          <div className="flex justify-between items-center">
            <span className="text-sm text-[#4a4a48] font-medium">{label('salesTotal')}</span>
            <span className="text-base font-semibold text-[#191918]">{fmt(data.salesTotal)}</span>
          </div>
        </div>
        <div className="px-6 py-6 border-t border-[#e0ddd5] bg-emerald-500/5">
          <div className="flex justify-between items-center">
            <span className="text-base font-bold text-[#191918]">{label('taxDifference')}</span>
            <span className="text-xl font-bold text-emerald-500">{fmt(data.difference)}</span>
          </div>
        </div>
      </div>
    </div>
  );
};

export default TaxInclusiveSummary;
