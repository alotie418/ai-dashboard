
import React from 'react';
import { useTranslation } from 'react-i18next';
import { FinancialStatementData } from '../types';
import { formatMoney, getTaxLabel } from './accountingHelpers';

interface Props {
  data: FinancialStatementData;
  accountingLocale?: string;
}

const FinancialStatementTable: React.FC<Props> = ({ data, accountingLocale = 'CN' }) => {
  const { i18n } = useTranslation();
  if (!data) return null;
  const uiLang = i18n.language;
  const label = (key: string) => getTaxLabel(accountingLocale, uiLang, key);
  const fmt = (val: number) => formatMoney(val || 0, accountingLocale, uiLang);

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
        <i className="fas fa-file-invoice-dollar text-lg text-primary"></i>
        <h3 className="text-lg font-bold text-[#191918]">{label('plRevenue').split('.')[0] || 'P&L'}</h3>
      </div>
      <div className="flex flex-col flex-1 justify-around py-2">
        <LineItem label={label('plRevenue')} value={fmt(data.salesRevenue)} primary />
        <LineItem label={label('plCost')} value={`-${fmt(data.costOfSales)}`} />
        <LineItem label={label('plGrossProfit')} value={fmt(grossProfit)} bold primary />
        {data.taxSurcharge > 0 && <LineItem label={label('plTaxSurcharge')} value={`-${fmt(data.taxSurcharge)}`} />}
        {data.shippingFee > 0 && <LineItem label={label('plShipping')} value={`-${fmt(data.shippingFee)}`} />}
        <LineItem label={label('plAdmin')} value={`-${fmt(data.adminExpense)}`} />
        <LineItem label={label('plIncomeTax')} value={`-${fmt(data.incomeTax)}`} />
        <LineItem label={label('plNetProfit')} value={fmt(netProfit)} bold success />
      </div>
    </div>
  );
};

const LineItem: React.FC<{ label: string; value: string; bold?: boolean; primary?: boolean; success?: boolean }> = ({ label, value, bold, primary, success }) => (
  <div className={`flex justify-between items-center px-6 py-3 hover:bg-[#f0eeeb] transition-colors ${bold ? 'font-bold' : ''} ${primary ? 'bg-primary/5' : ''} ${success ? 'bg-emerald-500/5' : ''}`}>
    <span className="text-sm text-[#4a4a48]">{label}</span>
    <span className={`text-base font-mono ${primary ? 'text-primary' : success ? 'text-emerald-600' : 'text-[#4a4a48]'}`}>{value}</span>
  </div>
);

export default FinancialStatementTable;
