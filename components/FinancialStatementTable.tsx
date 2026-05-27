
import React from 'react';
import { useTranslation } from 'react-i18next';
import { FinancialStatementData } from '../types';

interface Props {
  data: FinancialStatementData;
}

const FinancialStatementTable: React.FC<Props> = ({ data }) => {
  const { t } = useTranslation();
  const formatCurrency = (val: number) => `¥${val.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
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
    return { grossProfit, netProfit, grossMargin, netMargin };
  };
  const { grossProfit, netProfit, grossMargin, netMargin } = recompute();

  return (
    <div className="bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl overflow-hidden h-full flex flex-col" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.06)' }}>
      <div className="p-6 border-b border-[#e0ddd5] flex items-center space-x-3">
        <i className="fas fa-file-invoice-dollar text-lg text-[#d97757]"></i>
        <h3 className="text-lg font-bold text-[#191918]">{t('dashboard.plTitle')}</h3>
      </div>

      <div className="flex flex-col flex-1 justify-around py-2">
        <div className="flex justify-between items-center px-6 py-3 hover:bg-[#f0eeeb] transition-colors">
          <span className="text-sm text-[#4a4a48]">{t('dashboard.plRevenue')}</span>
          <span className="text-base font-semibold text-emerald-500">{formatCurrency(data.salesRevenue)}</span>
        </div>

        <div className="flex justify-between items-center px-6 py-3 hover:bg-[#f0eeeb] transition-colors">
          <span className="text-sm text-[#4a4a48]">{t('dashboard.plCost')}</span>
          <span className="text-base font-medium text-rose-500">-{formatCurrency(data.costOfSales)}</span>
        </div>

        <div className="flex justify-between items-center px-6 py-4 bg-[#d97757]/5 border-y border-[#e0ddd5] transition-colors">
          <span className="text-base font-bold text-[#d97757]">{t('dashboard.plGrossProfit')}</span>
          <div className="text-right">
            <div className="text-xl font-bold text-[#d97757]">{formatCurrency(grossProfit)}</div>
            <div className="text-[#5c5c5a] text-[10px] uppercase tracking-wider">{t('dashboard.plGrossMargin')} {grossMargin}%</div>
          </div>
        </div>

        <div className="flex justify-between items-center px-6 py-3 hover:bg-[#f0eeeb] transition-colors">
          <span className="text-sm text-[#4a4a48]">{t('dashboard.plTaxSurcharge')}</span>
          <span className="text-base font-medium text-rose-500">-{formatCurrency(data.taxSurcharge)}</span>
        </div>

        <div className="flex justify-between items-center px-6 py-3 hover:bg-[#f0eeeb] transition-colors">
          <span className="text-sm text-[#4a4a48]">{t('dashboard.plShipping')}</span>
          <span className="text-base font-medium text-rose-500">-{formatCurrency(data.shippingFee)}</span>
        </div>

        <div className="flex justify-between items-center px-6 py-3 hover:bg-[#f0eeeb] transition-colors">
          <span className="text-sm text-[#4a4a48]">{t('dashboard.plAdmin')}</span>
          <span className="text-base font-medium text-rose-500">-{formatCurrency(data.adminExpense)}</span>
        </div>

        <div className="flex justify-between items-center px-6 py-3 hover:bg-[#f0eeeb] transition-colors">
          <span className="text-sm text-[#4a4a48]">{t('dashboard.plIncomeTax')}</span>
          <span className="text-base font-medium text-rose-500">-{formatCurrency(data.incomeTax)}</span>
        </div>

        <div className="flex justify-between items-center px-6 py-5 bg-emerald-500/5 transition-colors">
          <span className="text-base font-bold text-emerald-500">{t('dashboard.plNetProfit')}</span>
          <div className="text-right">
            <div className="text-xl font-bold text-emerald-500">{formatCurrency(netProfit)}</div>
            <div className="text-[#5c5c5a] text-[10px] uppercase tracking-wider">{t('dashboard.plNetMargin')} {netMargin}%</div>
          </div>
        </div>
      </div>
    </div>
  );
};

export default FinancialStatementTable;
