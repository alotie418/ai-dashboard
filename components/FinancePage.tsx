
import React, { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { BusinessData } from '../types';

interface Props {
  data: BusinessData;
  selectedYear: string;
  selectedQuarter: string;
  selectedMonth: string;
}

type StatementType = 'pl' | 'balance' | 'cashflow';

const FinancePage: React.FC<Props> = ({ data, selectedYear, selectedQuarter, selectedMonth }) => {
  const { t } = useTranslation();
  const [activeTab, setActiveTab] = useState<StatementType>('pl');

  // Construct display period string
  const periodDisplay = selectedQuarter !== '全年'
    ? `${selectedYear}年 ${selectedQuarter}`
    : selectedMonth !== '全部'
      ? `${selectedYear}年 ${selectedMonth}`
      : `${selectedYear}年度`;

  const formatCurrency = (val: number) => `¥${val.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

  const recomputePL = () => {
    const revenue = data.financialStatement.salesRevenue;
    const cost = data.financialStatement.costOfSales;
    const tax = data.financialStatement.taxSurcharge;
    const shipping = data.financialStatement.shippingFee;
    const admin = data.financialStatement.adminExpense;
    const incomeTax = data.financialStatement.incomeTax;

    const grossProfit = revenue - cost;
    const netProfit = revenue - cost - tax - shipping - admin - incomeTax;
    const grossMargin = revenue === 0 ? 0 : +(grossProfit / revenue * 100).toFixed(2);
    const netMargin = revenue === 0 ? 0 : +(netProfit / revenue * 100).toFixed(2);

    return { grossProfit, netProfit, grossMargin, netMargin };
  };

  const exportToCSV = () => {
    const { grossProfit, netProfit } = recomputePL();
    let csvContent = "\uFEFF"; // BOM for Excel UTF-8 compatibility

    if (activeTab === 'pl') {
      csvContent += "项目,金额\n";
      csvContent += `一、营业收入,${data.financialStatement.salesRevenue}\n`;
      csvContent += `减：营业成本,${data.financialStatement.costOfSales}\n`;
      csvContent += `二、毛利,${grossProfit}\n`;
      csvContent += `减：税金及附加,${data.financialStatement.taxSurcharge}\n`;
      csvContent += `减：销售费用,${data.financialStatement.shippingFee}\n`;
      csvContent += `减：管理费用,${data.financialStatement.adminExpense}\n`;
      csvContent += `减：所得税费用,${data.financialStatement.incomeTax}\n`;
      csvContent += `三、净利润,${netProfit}\n`;
    } else {
      csvContent += "科目,期末余额,期初余额\n";
      csvContent += "货币资金,0.00,0.00\n";
      csvContent += "应收账款,0.00,0.00\n";
      csvContent += "存货,0.00,0.00\n";
    }

    const blob = new Blob([csvContent], { type: 'text/csv;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.setAttribute("href", url);
    link.setAttribute("download", `AI_Dashboard_${activeTab}_${selectedYear}_${selectedQuarter !== '全年' ? selectedQuarter : selectedMonth}.csv`);
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  };

  return (
    <div className="space-y-8 animate-in fade-in duration-500">
      {/* Top Controls - Simplified */}
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-4">
        <div className="flex items-center space-x-4">
          {/* Header removed as it is now in top bar, keeping generic title or removing completely? Keeping actions aligned right */}
        </div>
        <div className="flex space-x-3 w-full justify-end">
          <button
            onClick={exportToCSV}
            className="flex items-center px-4 py-2 bg-[#f9f9f8] hover:bg-[#f0eeeb] text-[#191918] rounded-xl text-sm font-medium border border-[#e0ddd5] transition-all"
          >
            <i className="fas fa-file-export mr-2 text-[#d97757]"></i> {t('finance.export')}
          </button>
          <button className="flex items-center px-4 py-2 bg-[#d97757] hover:bg-[#c56a4a] text-white rounded-xl text-sm font-medium transition-all" style={{ boxShadow: '0 4px 16px rgba(217,119,87,0.15)' }}>
            <i className="fas fa-print mr-2"></i> {t('finance.print')}
          </button>
        </div>
      </div>

      {/* Quick KPIs */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
        <div className="bg-white/80 border border-[#e0ddd5] p-6 rounded-xl">
          <p className="text-[#5c5c5a] text-[10px] uppercase font-bold tracking-widest mb-1">{t('finance.kpiNetAssets')}</p>
          <h4 className="text-2xl font-bold text-[#191918] tracking-tight">¥0.00</h4>
          <p className="text-[#5c5c5a] text-xs mt-2 italic">{t('finance.kpiNoData')}</p>
        </div>
        <div className="bg-white/80 border border-[#e0ddd5] p-6 rounded-xl">
          <p className="text-[#5c5c5a] text-[10px] uppercase font-bold tracking-widest mb-1">{t('finance.kpiDebtRatio')}</p>
          <h4 className="text-2xl font-bold text-[#191918] tracking-tight">0.0%</h4>
          <p className="text-[#5c5c5a] text-xs mt-2 italic">{t('finance.kpiNoData')}</p>
        </div>
        <div className="bg-white/80 border border-[#e0ddd5] p-6 rounded-xl">
          <p className="text-[#5c5c5a] text-[10px] uppercase font-bold tracking-widest mb-1">{t('finance.kpiCurrentRatio')}</p>
          <h4 className="text-2xl font-bold text-[#191918] tracking-tight">0.0</h4>
          <p className="text-[#5c5c5a] text-xs mt-2 italic">{t('finance.kpiNoData')}</p>
        </div>
      </div>

      {/* Tabs */}
      <div className="flex bg-white/80 p-1.5 rounded-xl border border-[#e0ddd5] w-fit">
        <button
          onClick={() => setActiveTab('pl')}
          className={`px-6 py-2 rounded-lg text-sm font-medium transition-all ${activeTab === 'pl' ? 'bg-[#d97757] text-white' : 'text-[#4a4a48] hover:text-[#191918]'}`}
          style={activeTab === 'pl' ? { boxShadow: '0 4px 16px rgba(217,119,87,0.15)' } : {}}
        >
          {t('finance.tabPl')}
        </button>
        <button
          onClick={() => setActiveTab('balance')}
          className={`px-6 py-2 rounded-lg text-sm font-medium transition-all ${activeTab === 'balance' ? 'bg-[#d97757] text-white' : 'text-[#4a4a48] hover:text-[#191918]'}`}
          style={activeTab === 'balance' ? { boxShadow: '0 4px 16px rgba(217,119,87,0.15)' } : {}}
        >
          {t('finance.tabBalance')}
        </button>
        <button
          onClick={() => setActiveTab('cashflow')}
          className={`px-6 py-2 rounded-lg text-sm font-medium transition-all ${activeTab === 'cashflow' ? 'bg-[#d97757] text-white' : 'text-[#4a4a48] hover:text-[#191918]'}`}
          style={activeTab === 'cashflow' ? { boxShadow: '0 4px 16px rgba(217,119,87,0.15)' } : {}}
        >
          {t('finance.tabCashflow')}
        </button>
      </div>

      {/* Statement Table */}
      <div className="bg-white/80 border border-[#e0ddd5] rounded-xl overflow-hidden" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.05)' }}>
        {activeTab === 'pl' && (
          <div className="p-10">
            <div className="max-w-4xl mx-auto space-y-6">
              <div className="text-center mb-10">
                <h2 className="text-2xl font-bold text-[#191918]">{t('finance.plTitle')}</h2>
                <p className="text-[#5c5c5a] text-sm">{t('finance.plPeriod')}{periodDisplay}</p>
              </div>
              {(() => {
                const pl = recomputePL();
                return (
                  <div className="space-y-1">
                    <LineItem label={t('finance.plRevenue')} value={data.financialStatement.salesRevenue} bold primary />
                    <LineItem label={t('finance.plCost')} value={data.financialStatement.costOfSales} indent />
                    <LineItem label={t('finance.plGrossProfit')} value={pl.grossProfit} bold primary />
                    <LineItem label={t('finance.plTaxSurcharge')} value={data.financialStatement.taxSurcharge} indent />
                    <LineItem label={t('finance.plShipping')} value={data.financialStatement.shippingFee} indent />
                    <LineItem label={t('finance.plAdmin')} value={data.financialStatement.adminExpense} indent />
                    <LineItem label={t('finance.plIncomeTax')} value={data.financialStatement.incomeTax} indent />
                    <LineItem label={t('finance.plNetProfit')} value={pl.netProfit} bold success />
                    <LineItem label={t('finance.plNetMargin')} value={`${pl.netMargin.toFixed(2)}%`} indent />
                  </div>
                );
              })()}
            </div>
          </div>
        )}

        {activeTab === 'balance' && (
          <div className="grid grid-cols-1 md:grid-cols-2 divide-x divide-[#e0ddd5]">
            <div className="p-10">
              <h3 className="text-lg font-bold text-[#191918] mb-6 flex items-center">
                <i className="fas fa-coins mr-3 text-amber-500"></i> {t('finance.balanceAssets')}
              </h3>
              <div className="space-y-1">
                <h4 className="text-xs font-bold text-[#5c5c5a] uppercase tracking-widest py-2">{t('finance.balanceCurrentAssets')}</h4>
                <LineItem label={t('finance.balanceCash')} value={0.0} />
                <LineItem label={t('finance.balanceReceivables')} value={0.0} />
                <LineItem label={t('finance.balanceInventory')} value={0.0} />
                <div className="border-t border-[#e0ddd5] my-4"></div>
                <LineItem label={t('finance.balanceCurrentAssetsTotal')} value={0.0} bold />
                <h4 className="text-xs font-bold text-[#5c5c5a] uppercase tracking-widest py-2 mt-4">{t('finance.balanceNonCurrentAssets')}</h4>
                <LineItem label={t('finance.balanceFixedAssets')} value={0.0} />
                <div className="border-t border-[#e0ddd5] my-4"></div>
                <LineItem label={t('finance.balanceTotalAssets')} value={0.0} bold primary />
              </div>
            </div>
            <div className="p-10 bg-[#f9f9f8]/20">
              <h3 className="text-lg font-bold text-[#191918] mb-6 flex items-center">
                <i className="fas fa-hand-holding-dollar mr-3 text-rose-500"></i> {t('finance.balanceLiabilitiesEquity')}
              </h3>
              <div className="space-y-1">
                <h4 className="text-xs font-bold text-[#5c5c5a] uppercase tracking-widest py-2">{t('finance.balanceCurrentLiabilities')}</h4>
                <LineItem label={t('finance.balancePayables')} value={0.0} />
                <LineItem label={t('finance.balanceTaxPayable')} value={0.0} />
                <div className="border-t border-[#e0ddd5] my-4"></div>
                <LineItem label={t('finance.balanceTotalLiabilities')} value={0.0} bold />
                <h4 className="text-xs font-bold text-[#5c5c5a] uppercase tracking-widest py-2 mt-4">{t('finance.balanceEquity')}</h4>
                <LineItem label={t('finance.balancePaidInCapital')} value={0.0} />
                <LineItem label={t('finance.balanceRetainedEarnings')} value={0.0} />
                <div className="border-t border-[#e0ddd5] my-4"></div>
                <LineItem label={t('finance.balanceTotalLiabilitiesEquity')} value={0.0} bold primary />
              </div>
            </div>
          </div>
        )}

        {activeTab === 'cashflow' && (
          <div className="p-20 text-center text-[#5c5c5a] flex flex-col items-center">
            <i className="fas fa-faucet-drip text-6xl mb-6 opacity-20"></i>
            <h3 className="text-xl font-medium">{t('finance.cashflowTitle')}</h3>
            <p className="mt-2 text-sm max-w-md">{t('finance.cashflowDesc')}</p>
            <button className="mt-8 px-6 py-2 bg-[#f9f9f8] rounded-xl text-sm hover:text-[#191918] transition-colors border border-[#e0ddd5]">
              {t('finance.cashflowSync')}
            </button>
          </div>
        )}
      </div>
    </div>
  );
};

interface LineItemProps {
  label: string;
  value: number | string;
  bold?: boolean;
  indent?: boolean;
  primary?: boolean;
  success?: boolean;
}

const LineItem: React.FC<LineItemProps> = ({ label, value, bold, indent, primary, success }) => (
  <div className={`flex justify-between items-center py-3 px-4 rounded-xl transition-colors hover:bg-[#f0eeeb]/50 ${bold ? 'font-bold' : ''} ${primary ? 'bg-[#d97757]/5' : ''} ${success ? 'bg-emerald-500/5' : ''}`}>
    <span className={`text-sm ${indent ? 'pl-8 text-[#4a4a48]' : 'text-[#191918]'}`}>{label}</span>
    <span className={`text-base font-mono ${primary ? 'text-[#d97757]' : success ? 'text-emerald-600' : 'text-[#4a4a48]'}`}>
      {typeof value === 'number' ? value.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 }) : value}
    </span>
  </div>
);

export default FinancePage;
