// US-specific dashboard cards — Schedule C + Deductions + SE Tax + Margins
// Labels follow uiLanguage; financial logic follows accountingLocale (always US here)
import React from 'react';
import { useTranslation } from 'react-i18next';
import { formatMoney, getTaxLabel } from './accountingHelpers';

interface Props {
  report: any;
  mileageSummary: any;
  homeOffice: any;
  accountingLocale: string;
  uiLanguage: string;
}

const USDashboardCards: React.FC<Props> = ({ report, mileageSummary, homeOffice, accountingLocale, uiLanguage }) => {
  const { t } = useTranslation();
  const sc = report?.scheduleC || {};
  const se = report?.selfEmploymentTax || {};
  const est = report?.estimatedTax || {};
  const label = (key: string) => getTaxLabel(accountingLocale, uiLanguage, key);
  const fmt = (v: number) => formatMoney(v, accountingLocale, uiLanguage);

  return (
    <>
      {/* Schedule C Summary */}
      <div className="bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl overflow-hidden h-full flex flex-col" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.06)' }}>
        <div className="p-6 border-b border-[#e0ddd5] flex items-center space-x-3">
          <i className="fas fa-file-invoice-dollar text-lg text-primary"></i>
          <h3 className="text-lg font-bold text-[#191918]">{label('taxTitle')}</h3>
        </div>
        <div className="flex flex-col flex-1 justify-around py-2">
          <Row label={label('grossReceipts')} value={fmt(sc.line1_grossReceipts)} primary />
          <Row label={label('totalExpenses')} value={fmt(sc.line28_totalExpenses)} />
          <Row label={label('netProfit')} value={fmt(sc.line31_netProfit)} bold success={sc.line31_netProfit >= 0} />
        </div>
      </div>

      {/* Deductions + Mileage + Home Office */}
      <div className="bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl overflow-hidden h-full flex flex-col" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.06)' }}>
        <div className="p-6 border-b border-[#e0ddd5] flex items-center space-x-3">
          <i className="fas fa-receipt text-lg text-emerald-500"></i>
          <h3 className="text-lg font-bold text-[#191918]">{label('totalExpenses')}</h3>
        </div>
        <div className="flex flex-col flex-1 justify-around py-2">
          {mileageSummary && mileageSummary.totalDeduction > 0 && (
            <Row label={`🚗 ${label('mileage')} (${t('usDashboard.mileageTrips', { count: mileageSummary.trips })})`} value={fmt(mileageSummary.totalDeduction)} />
          )}
          {homeOffice && homeOffice.deduction > 0 && (
            <Row label={`🏠 ${label('homeOffice')}`} value={fmt(homeOffice.deduction)} />
          )}
          {sc.line24b_meals > 0 && <Row label={`🍽️ ${t('usDashboard.scMeals')}`} value={fmt(sc.line24b_meals)} />}
          {sc.line9_car > 0 && <Row label={`🚙 ${t('usDashboard.scCarTruck')}`} value={fmt(sc.line9_car)} />}
          {sc.line18_office > 0 && <Row label={`📎 ${t('usDashboard.scOffice')}`} value={fmt(sc.line18_office)} />}
        </div>
      </div>

      {/* Self-Employment Tax + Quarterly Estimated */}
      <div className="bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl overflow-hidden h-full flex flex-col" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.06)' }}>
        <div className="p-6 border-b border-[#e0ddd5] flex items-center space-x-3">
          <i className="fas fa-landmark text-lg text-rose-400"></i>
          <h3 className="text-lg font-bold text-[#191918]">{label('seTax')}</h3>
        </div>
        <div className="flex flex-col flex-1 justify-around py-2">
          <Row label={label('seTax')} value={fmt(se.totalSETax)} />
          <Row label={`├ ${label('socialSecurity')}`} value={fmt(se.socialSecurityTax)} indent />
          <Row label={`├ ${label('medicare')}`} value={fmt(se.medicareTax)} indent />
          {se.additionalMedicare > 0 && <Row label={`└ ${label('additionalMedicare')} (0.9%)`} value={fmt(se.additionalMedicare)} indent />}
          <div className="border-t border-[#e0ddd5] mx-4 my-1"></div>
          <Row label={label('quarterlyTax')} value={fmt(est.quarterlyPayment)} bold primary />
          {est.dueDates && (
            <div className="px-6 py-1 text-[10px] text-[#5c5c5a]">
              {label('dueLabel')}: {est.dueDates.join(' · ')}
            </div>
          )}
          {/* PR-E1: SE-tax / quarterly figures are estimates, not a filing basis. */}
          <p className="px-6 pt-1 pb-3 text-[10px] text-[#5c5c5a] leading-snug">{t('disclaimer.usTax')}</p>
        </div>
      </div>

      {/* Profit Margins */}
      <div className="bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl p-6 h-full flex flex-col" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.06)' }}>
        <div className="flex items-center space-x-3 mb-6">
          <i className="fas fa-chart-line text-lg text-rose-400"></i>
          <h3 className="text-lg font-bold text-[#191918]">{label('profitMargins')}</h3>
        </div>
        <div className="space-y-6 flex-1">
          <MarginBar label={label('grossMargin')} value={sc.line7_grossIncome > 0 ? Math.round((sc.line7_grossIncome - sc.line28_totalExpenses) / sc.line7_grossIncome * 100) : null} color="bg-primary" />
          <MarginBar label={label('netMargin')} value={sc.line7_grossIncome > 0 ? Math.round(sc.line31_netProfit / sc.line7_grossIncome * 100) : null} color="bg-emerald-500" />
        </div>
      </div>
    </>
  );
};

const Row: React.FC<{ label: string; value: string; bold?: boolean; indent?: boolean; primary?: boolean; success?: boolean }> = ({ label, value, bold, indent, primary, success }) => (
  <div className={`flex justify-between items-center px-6 py-2.5 hover:bg-[#f0eeeb] transition-colors ${bold ? 'font-bold' : ''} ${primary ? 'bg-primary/5' : ''} ${success ? 'bg-emerald-500/5' : ''}`}>
    <span className={`text-sm ${indent ? 'pl-4 text-[#5c5c5a]' : 'text-[#4a4a48]'}`}>{label}</span>
    <span className={`text-base font-mono tabular-nums whitespace-nowrap ${primary ? 'text-primary' : success ? 'text-emerald-600' : 'text-[#4a4a48]'}`}>{value}</span>
  </div>
);

const MarginBar: React.FC<{ label: string; value: number | null; color: string }> = ({ label, value, color }) => (
  <div className="space-y-2">
    <div className="flex justify-between items-end">
      <span className="text-sm text-[#4a4a48] font-medium">{label}</span>
      <span className="font-bold text-xl">{value === null ? '—' : `${value}%`}</span>
    </div>
    <div className="w-full bg-[#f0eeeb]/50 h-2.5 rounded-full overflow-hidden">
      <div className={`${color} h-full rounded-full transition-all duration-1000`} style={{ width: `${value === null ? 0 : Math.max(0, Math.min(100, value))}%` }}></div>
    </div>
  </div>
);

export default USDashboardCards;
