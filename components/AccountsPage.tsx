import React, { useState, useEffect, useCallback } from 'react';
import { useTranslation } from 'react-i18next';
import { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer } from 'recharts';
import { fetchReceivablesSummary, fetchPayablesSummary, recordSalePayment, recordPurchasePayment, fetchSettings } from '../services/api';
import { ReceivablesSummary, PayablesSummary } from '../types';
import { formatMoney, getTaxLabel } from './accountingHelpers';

type TabType = 'receivable' | 'payable';

const AccountsPage: React.FC = () => {
  const { t, i18n } = useTranslation();
  const [activeTab, setActiveTab] = useState<TabType>('receivable');
  const [receivables, setReceivables] = useState<ReceivablesSummary | null>(null);
  const [payables, setPayables] = useState<PayablesSummary | null>(null);
  const [loading, setLoading] = useState(true);
  const [paymentModal, setPaymentModal] = useState<{ id: string; type: 'sale' | 'purchase'; total: number; paid: number; name: string } | null>(null);
  const [paymentAmount, setPaymentAmount] = useState('');

  const loadData = useCallback(async () => {
    setLoading(true);
    try {
      const [r, p] = await Promise.all([fetchReceivablesSummary(), fetchPayablesSummary()]);
      setReceivables(r);
      setPayables(p);
    } catch (err) {
      console.error('Failed to load accounts data:', err);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { loadData(); }, [loadData]);

  const handlePayment = async () => {
    if (!paymentModal || !paymentAmount) return;
    const amount = parseFloat(paymentAmount);
    if (isNaN(amount) || amount <= 0) return;
    const remaining = paymentModal.total - paymentModal.paid;
    if (amount > remaining) {
      alert(t('accounts.alertExceeded', { amount: formatMoney(remaining, accLocale) }));
      return;
    }

    try {
      if (paymentModal.type === 'sale') {
        await recordSalePayment(paymentModal.id, { paid_amount: paymentModal.paid + amount });
      } else {
        await recordPurchasePayment(paymentModal.id, { paid_amount: paymentModal.paid + amount });
      }
      setPaymentModal(null);
      setPaymentAmount('');
      loadData();
    } catch (err) {
      console.error('Payment failed:', err);
      alert(t('accounts.alertFailed'));
    }
  };

  const [accLocale, setAccLocale] = useState('CN');
  useEffect(() => { fetchSettings().then((s: any) => { if (s.accounting_locale) setAccLocale(s.accounting_locale); }).catch(() => {}); }, []);
  const formatCurrency = (val: number) => formatMoney(val, accLocale);
  // All non-CN accountingLocales (US/JP/KR/TW/EU) frame receivables/payables by
  // customer/supplier instead of the China-GAAP 应收账款/应付账款 ledger terms.
  // localeLabel(taxConceptKey, fallbackI18nKey) returns the accountingLocale's
  // taxConcept when accLocale !== 'CN', else the default i18n value (CN keeps its
  // China-GAAP wording untouched).
  const localeLabel = (taxKey: string, i18nKey: string) => accLocale !== 'CN' ? getTaxLabel(accLocale, i18n.language, taxKey) : t(i18nKey);
  // TW accountingLocale + Chinese UI: AR/AP page uses 帐龄 (not 账龄) and tab-specific
  // 未收款/未付款明细 + 所有应收/应付款项已结清. Other locales / non-Chinese UI keep the
  // shared accounts.* i18n unchanged.
  const twZh = accLocale === 'TW' && (i18n.language === 'zh-CN' || i18n.language === 'zh-TW');
  const twAcct = (taxKey: string, i18nKey: string) => twZh ? getTaxLabel(accLocale, i18n.language, taxKey) : t(i18nKey);

  const data = activeTab === 'receivable' ? receivables : payables;
  const agingData = data ? [
    { name: t('accounts.aging0_30'), amount: data.agingBuckets['0-30'] },
    { name: t('accounts.aging31_60'), amount: data.agingBuckets['31-60'] },
    { name: t('accounts.aging61_90'), amount: data.agingBuckets['61-90'] },
    { name: t('accounts.aging90plus'), amount: data.agingBuckets['90+'] },
  ] : [];

  const ranking = activeTab === 'receivable'
    ? (receivables?.topCustomers || [])
    : (payables?.topSuppliers || []);

  const details = data?.details || [];
  const totalAmount = activeTab === 'receivable' ? receivables?.totalReceivable : payables?.totalPayable;
  const overdueAmount = activeTab === 'receivable' ? receivables?.totalOverdue : payables?.totalOverdue;
  const rate = activeTab === 'receivable' ? receivables?.collectionRate : payables?.paymentRate;

  return (
    <div className="space-y-6">
      <p className="text-sm text-[#5c5c5a]">{t('accounts.pageSubtitle')}</p>
      {/* Tab Switcher */}
      <div className="flex items-center gap-1 bg-[#f0eeeb] rounded-xl p-1 w-fit">
        <button
          onClick={() => setActiveTab('receivable')}
          className={`px-5 py-2 rounded-lg text-sm font-medium transition-all ${activeTab === 'receivable' ? 'bg-white text-primary shadow-sm' : 'text-[#7a7a78] hover:text-[#191918]'}`}
        >
          <i className="fas fa-arrow-circle-down mr-1.5"></i>{localeLabel('acctReceivableTab', 'accounts.receivable')}
        </button>
        <button
          onClick={() => setActiveTab('payable')}
          className={`px-5 py-2 rounded-lg text-sm font-medium transition-all ${activeTab === 'payable' ? 'bg-white text-primary shadow-sm' : 'text-[#7a7a78] hover:text-[#191918]'}`}
        >
          <i className="fas fa-arrow-circle-up mr-1.5"></i>{localeLabel('acctPayableTab', 'accounts.payable')}
        </button>
      </div>

      {loading ? (
        <div className="flex items-center justify-center py-20">
          <i className="fas fa-spinner fa-spin text-2xl text-primary"></i>
        </div>
      ) : (
        <>
          {/* Summary Cards */}
          <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
            <div className="bg-white rounded-xl p-4 border border-[#e0ddd5]">
              <p className="text-xs text-[#7a7a78] mb-1">{activeTab === 'receivable' ? localeLabel('acctTotalReceivable', 'accounts.totalReceivable') : localeLabel('acctTotalPayable', 'accounts.totalPayable')}</p>
              <p className="text-xl font-bold text-[#191918]">{formatCurrency(totalAmount || 0)}</p>
            </div>
            <div className="bg-white rounded-xl p-4 border border-[#e0ddd5]">
              <p className="text-xs text-[#7a7a78] mb-1">{t('accounts.overdueAmount')}</p>
              <p className={`text-xl font-bold ${(overdueAmount || 0) > 0 ? 'text-red-500' : 'text-green-500'}`}>
                {formatCurrency(overdueAmount || 0)}
              </p>
            </div>
            <div className="bg-white rounded-xl p-4 border border-[#e0ddd5]">
              <p className="text-xs text-[#7a7a78] mb-1">{activeTab === 'receivable' ? t('accounts.unpaidCountReceivable') : t('accounts.unpaidCount')}</p>
              <p className="text-xl font-bold text-[#191918]">{details.length}</p>
            </div>
            <div className="bg-white rounded-xl p-4 border border-[#e0ddd5]">
              <p className="text-xs text-[#7a7a78] mb-1">{activeTab === 'receivable' ? t('accounts.collectionRate') : t('accounts.paymentRate')}</p>
              {/* null/undefined rate = no billing base (no sales/purchases): show an N/A
                  empty state instead of a misleading fabricated 100%. */}
              <p className={`text-xl font-bold ${rate == null ? 'text-[#7a7a78]' : rate >= 80 ? 'text-green-500' : rate >= 50 ? 'text-yellow-500' : 'text-red-500'}`}>
                {rate == null ? t('accounts.rateNa') : `${rate.toFixed(1)}%`}
              </p>
            </div>
          </div>

          {/* Charts & Ranking */}
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
            {/* Aging Analysis */}
            <div className="bg-white rounded-xl p-5 border border-[#e0ddd5]">
              <h4 className="text-sm font-bold text-[#191918] mb-4">
                <i className="fas fa-chart-bar mr-2 text-primary"></i>{twAcct('acctAgingTitle', 'accounts.agingTitle')}
              </h4>
              {agingData.some(d => d.amount > 0) ? (
                <ResponsiveContainer width="100%" height={200}>
                  <BarChart data={agingData}>
                    <CartesianGrid strokeDasharray="3 3" stroke="#f0eeeb" />
                    <XAxis dataKey="name" tick={{ fontSize: 11, fill: '#7a7a78' }} />
                    <YAxis tick={{ fontSize: 11, fill: '#7a7a78' }} />
                    <Tooltip formatter={(val: number) => formatCurrency(val)} />
                    <Bar dataKey="amount" fill="#274C92" radius={[4, 4, 0, 0]} name={t('accounts.headerTotal')} />
                  </BarChart>
                </ResponsiveContainer>
              ) : (
                <div className="flex items-center justify-center h-[200px] text-[#7a7a78] text-sm">{t('accounts.emptyAging')}</div>
              )}
            </div>

            {/* Ranking */}
            <div className="bg-white rounded-xl p-5 border border-[#e0ddd5]">
              <h4 className="text-sm font-bold text-[#191918] mb-4">
                <i className="fas fa-ranking-star mr-2 text-primary"></i>
                {activeTab === 'receivable' ? t('accounts.rankingReceivable') : t('accounts.rankingPayable')}
              </h4>
              {ranking.length > 0 ? (
                <div className="space-y-2">
                  {ranking.map((item, i) => (
                    <div key={i} className="flex items-center justify-between py-2 border-b border-[#f0eeeb] last:border-0">
                      <div className="flex items-center gap-2">
                        <span className={`w-5 h-5 rounded-full flex items-center justify-center text-[10px] font-bold text-white ${i < 3 ? 'bg-primary' : 'bg-[#b0b0ae]'}`}>{i + 1}</span>
                        <span className="text-sm text-[#191918]">{item.name}</span>
                      </div>
                      <span className="text-sm font-medium text-[#191918]">{formatCurrency(item.amount)}</span>
                    </div>
                  ))}
                </div>
              ) : (
                <div className="flex items-center justify-center h-[200px] text-[#7a7a78] text-sm">{t('accounts.emptyRanking')}</div>
              )}
            </div>
          </div>

          {/* Details Table */}
          <div className="bg-white rounded-xl border border-[#e0ddd5] overflow-hidden">
            <div className="px-5 py-3 border-b border-[#e0ddd5] flex items-center justify-between">
              <h4 className="text-sm font-bold text-[#191918]">
                <i className="fas fa-list-alt mr-2 text-primary"></i>{twAcct(activeTab === 'receivable' ? 'acctDetailsReceivable' : 'acctDetailsPayable', 'accounts.details')}
              </h4>
              <span className="text-xs text-[#7a7a78]">{t('accounts.count')} {details.length} {t('accounts.unit')}</span>
            </div>
            {details.length > 0 ? (
              <div className="overflow-x-auto">
                <table className="w-full text-sm data-table">
                  <thead>
                    <tr className="bg-[#f9f9f8] text-[#7a7a78] text-xs">
                      <th className="px-4 py-2 text-left">{t('accounts.headerDate')}</th>
                      <th className="px-4 py-2 text-left">{activeTab === 'receivable' ? t('accounts.headerCustomer') : t('accounts.headerSupplier')}</th>
                      <th className="px-4 py-2 text-right">{t('accounts.headerTotal')}</th>
                      <th className="px-4 py-2 text-right">{t('accounts.headerPaid')}</th>
                      <th className="px-4 py-2 text-right">{t('accounts.headerOwed')}</th>
                      <th className="px-4 py-2 text-center">{t('accounts.headerDue')}</th>
                      <th className="px-4 py-2 text-center">{t('accounts.headerStatus')}</th>
                      <th className="px-4 py-2 text-center">{t('accounts.headerAction')}</th>
                    </tr>
                  </thead>
                  <tbody>
                    {details.map((item: any) => {
                      const unpaid = (item.totalAmount || 0) - (item.paid_amount || 0);
                      const isOverdue = item.due_date && item.due_date < new Date().toISOString().split('T')[0];
                      return (
                        <tr key={item.id} className="border-t border-[#f0eeeb] hover:bg-[#f9f9f8]">
                          <td className="px-4 py-2.5">{item.date}</td>
                          <td className="px-4 py-2.5 col-name">{activeTab === 'receivable' ? item.customer : item.supplier}</td>
                          <td className="px-4 py-2.5 text-right">{formatCurrency(item.totalAmount)}</td>
                          <td className="px-4 py-2.5 text-right text-green-600">{formatCurrency(item.paid_amount || 0)}</td>
                          <td className="px-4 py-2.5 text-right font-medium text-red-500">{formatCurrency(unpaid)}</td>
                          <td className="px-4 py-2.5 text-center">{item.due_date || '-'}</td>
                          <td className="px-4 py-2.5 text-center">
                            <span className={`inline-flex items-center px-2 py-0.5 rounded-full text-[10px] font-medium ${
                              isOverdue ? 'bg-red-100 text-red-600' :
                              item.payment_status === 'partial' ? 'bg-yellow-100 text-yellow-700' :
                              'bg-gray-100 text-gray-600'
                            }`}>
                              {isOverdue ? t('accounts.statusOverdue') : item.payment_status === 'partial' ? t('accounts.statusPartial') : t('accounts.statusUnpaid')}
                            </span>
                          </td>
                          <td className="px-4 py-2.5 text-center">
                            <button
                              onClick={() => setPaymentModal({
                                id: item.id,
                                type: activeTab === 'receivable' ? 'sale' : 'purchase',
                                total: item.totalAmount,
                                paid: item.paid_amount || 0,
                                name: activeTab === 'receivable' ? item.customer : item.supplier,
                              })}
                              className="text-xs text-primary hover:text-primary-hover font-medium"
                            >
                              <i className="fas fa-money-bill-wave mr-1"></i>
                              {activeTab === 'receivable' ? t('accounts.recordPayment') : t('accounts.recordPaymentPay')}
                            </button>
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            ) : (
              <div className="flex items-center justify-center py-16 text-[#7a7a78]">
                <div className="text-center">
                  <i className="fas fa-check-circle text-3xl text-green-400 mb-2"></i>
                  <p className="text-sm">{twAcct(activeTab === 'receivable' ? 'acctAllClearedReceivable' : 'acctAllClearedPayable', 'accounts.allCleared')}</p>
                </div>
              </div>
            )}
          </div>
        </>
      )}

      {/* Payment Modal */}
      {paymentModal && (
        <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
          <div className="bg-white rounded-2xl shadow-xl w-full max-w-md p-6">
            <h3 className="text-lg font-bold text-[#191918] mb-4">
              <i className="fas fa-money-bill-wave mr-2 text-primary"></i>
              {paymentModal.type === 'sale' ? t('accounts.recordPayment') : t('accounts.recordPaymentPay')}
            </h3>
            <div className="space-y-3 mb-6">
              <div className="flex justify-between text-sm">
                <span className="text-[#7a7a78]">{paymentModal.type === 'sale' ? t('accounts.headerCustomer') : t('accounts.headerSupplier')}</span>
                <span className="font-medium">{paymentModal.name}</span>
              </div>
              <div className="flex justify-between text-sm">
                <span className="text-[#7a7a78]">{t('accounts.headerTotal')}</span>
                <span className="font-medium">{formatCurrency(paymentModal.total)}</span>
              </div>
              <div className="flex justify-between text-sm">
                <span className="text-[#7a7a78]">{t('accounts.modalPaidAmount')}</span>
                <span className="font-medium text-green-600">{formatCurrency(paymentModal.paid)}</span>
              </div>
              <div className="flex justify-between text-sm">
                <span className="text-[#7a7a78]">{t('accounts.modalRemaining')}</span>
                <span className="font-medium text-red-500">{formatCurrency(paymentModal.total - paymentModal.paid)}</span>
              </div>
              <div className="pt-2">
                <label className="block text-xs text-[#7a7a78] mb-1">{t('accounts.modalThisPayment', { type: paymentModal.type === 'sale' ? t('accounts.modalReceive') : t('accounts.modalPay') })}</label>
                <input
                  type="number"
                  value={paymentAmount}
                  onChange={e => setPaymentAmount(e.target.value)}
                  placeholder={`${t('accounts.modalMax')} ${formatCurrency(paymentModal.total - paymentModal.paid)}`}
                  className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm focus:ring-2 focus:ring-primary focus:border-transparent"
                />
              </div>
              <div className="flex gap-2 pt-1">
                <button
                  onClick={() => setPaymentAmount(String(paymentModal.total - paymentModal.paid))}
                  className="text-xs px-3 py-1 bg-[#f0eeeb] text-[#7a7a78] rounded-lg hover:bg-[#e0ddd5]"
                >{t('accounts.modalFullPayment')}</button>
              </div>
            </div>
            <div className="flex gap-3">
              <button onClick={() => { setPaymentModal(null); setPaymentAmount(''); }} className="flex-1 py-2 text-sm text-[#7a7a78] border border-[#e0ddd5] rounded-lg hover:bg-[#f0eeeb]">{t('accounts.modalCancel')}</button>
              <button onClick={handlePayment} disabled={!paymentAmount || parseFloat(paymentAmount) <= 0} className="flex-1 py-2 text-sm bg-primary text-white rounded-lg hover:bg-primary-hover disabled:opacity-50">{t('accounts.modalConfirm')}</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};

export default AccountsPage;
