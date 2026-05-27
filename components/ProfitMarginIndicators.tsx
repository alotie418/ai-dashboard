
import React from 'react';
import { useTranslation } from 'react-i18next';
import { FinancialStatementData } from '../types';
import { getTaxLabel } from './accountingHelpers';

interface Props {
  data: FinancialStatementData;
  accountingLocale?: string;
}

const ProfitMarginIndicators: React.FC<Props> = ({ data, accountingLocale = 'CN' }) => {
  const { t, i18n } = useTranslation();
  if (!data) return null;
  const uiLang = i18n.language;

  const recompute = () => {
    const revenue = data.salesRevenue;
    const cost = data.costOfSales;
    const tax = data.taxSurcharge;
    const shipping = data.shippingFee;
    const admin = data.adminExpense;
    const incomeTax = data.incomeTax;
    const grossProfit = revenue - cost;
    const netProfit = revenue - cost - tax - shipping - admin - incomeTax;
    const grossMargin = revenue === 0 ? 0 : +(grossProfit / revenue * 100).toFixed(2);
    const netMargin = revenue === 0 ? 0 : +(netProfit / revenue * 100).toFixed(2);
    return { grossMargin, netMargin };
  };
  const { grossMargin, netMargin } = recompute();

  return (
    <div className="bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl p-6 h-full flex flex-col" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.06)' }}>
      <div className="flex items-center space-x-3 mb-8">
        <i className="fas fa-chart-line text-lg text-rose-400"></i>
        <h3 className="text-lg font-bold text-[#191918]">{t('dashboard.profitMarginTitle')}</h3>
      </div>

      <div className="space-y-8 flex-1">
        <div className="space-y-3">
          <div className="flex justify-between items-end">
            <span className="text-sm text-[#4a4a48] font-medium">{t('dashboard.grossMargin')}</span>
            <span className="text-[#d97757] font-bold text-xl">{grossMargin}%</span>
          </div>
          <div className="w-full bg-[#f0eeeb]/50 h-2.5 rounded-full overflow-hidden">
            <div className="bg-[#d97757] h-full rounded-full transition-all duration-1000 ease-out" style={{ width: `${Math.max(0, Math.min(100, grossMargin))}%`, boxShadow: '0 0 10px rgba(217,119,87,0.3)' }}></div>
          </div>
          <div className="text-[#5c5c5a] text-[10px] uppercase tracking-tight">{t('dashboard.grossMarginFormula')}</div>
        </div>

        <div className="space-y-3">
          <div className="flex justify-between items-end">
            <span className="text-sm text-[#4a4a48] font-medium">{t('dashboard.netMargin')}</span>
            <span className="text-emerald-500 font-bold text-xl">{netMargin}%</span>
          </div>
          <div className="w-full bg-[#f0eeeb]/50 h-2.5 rounded-full overflow-hidden">
            <div className="bg-emerald-500 h-full rounded-full transition-all duration-1000 ease-out shadow-[0_0_10px_rgba(16,185,129,0.3)]" style={{ width: `${Math.max(0, Math.min(100, netMargin))}%` }}></div>
          </div>
          <div className="text-[#5c5c5a] text-[10px] uppercase tracking-tight">{t('dashboard.netMarginFormula')}</div>
        </div>
      </div>

      <div className="mt-8 pt-6 border-t border-[#e0ddd5] space-y-2">
        <div className="flex items-start space-x-2 text-xs text-[#5c5c5a]">
          <span role="img" aria-label="lightbulb">💡</span>
          <span>{t('dashboard.grossMarginNote')}</span>
        </div>
        <div className="flex items-start space-x-2 text-xs text-[#5c5c5a]">
          <span role="img" aria-label="lightbulb">💡</span>
          <span>{t('dashboard.netMarginNote')}</span>
        </div>
      </div>
    </div>
  );
};

export default ProfitMarginIndicators;
