import React, { useState, useEffect, useCallback } from 'react';
import { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer } from 'recharts';
import { fetchReceivablesSummary, fetchPayablesSummary, recordSalePayment, recordPurchasePayment } from '../services/api';
import { ReceivablesSummary, PayablesSummary } from '../types';

type TabType = 'receivable' | 'payable';

const AccountsPage: React.FC = () => {
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
      alert(`付款金额不能超过剩余欠款 ¥${remaining.toLocaleString()}`);
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
      alert('付款记录失败，请重试');
    }
  };

  const formatCurrency = (val: number) => `¥${val.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

  const data = activeTab === 'receivable' ? receivables : payables;
  const agingData = data ? [
    { name: '0-30天', amount: data.agingBuckets['0-30'] },
    { name: '31-60天', amount: data.agingBuckets['31-60'] },
    { name: '61-90天', amount: data.agingBuckets['61-90'] },
    { name: '90天+', amount: data.agingBuckets['90+'] },
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
      {/* Tab Switcher */}
      <div className="flex items-center gap-1 bg-[#f0eeeb] rounded-xl p-1 w-fit">
        <button
          onClick={() => setActiveTab('receivable')}
          className={`px-5 py-2 rounded-lg text-sm font-medium transition-all ${activeTab === 'receivable' ? 'bg-white text-[#d97757] shadow-sm' : 'text-[#7a7a78] hover:text-[#191918]'}`}
        >
          <i className="fas fa-arrow-circle-down mr-1.5"></i>应收账款
        </button>
        <button
          onClick={() => setActiveTab('payable')}
          className={`px-5 py-2 rounded-lg text-sm font-medium transition-all ${activeTab === 'payable' ? 'bg-white text-[#d97757] shadow-sm' : 'text-[#7a7a78] hover:text-[#191918]'}`}
        >
          <i className="fas fa-arrow-circle-up mr-1.5"></i>应付账款
        </button>
      </div>

      {loading ? (
        <div className="flex items-center justify-center py-20">
          <i className="fas fa-spinner fa-spin text-2xl text-[#d97757]"></i>
        </div>
      ) : (
        <>
          {/* Summary Cards */}
          <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
            <div className="bg-white rounded-xl p-4 border border-[#e0ddd5]">
              <p className="text-xs text-[#7a7a78] mb-1">{activeTab === 'receivable' ? '应收总额' : '应付总额'}</p>
              <p className="text-xl font-bold text-[#191918]">{formatCurrency(totalAmount || 0)}</p>
            </div>
            <div className="bg-white rounded-xl p-4 border border-[#e0ddd5]">
              <p className="text-xs text-[#7a7a78] mb-1">逾期金额</p>
              <p className={`text-xl font-bold ${(overdueAmount || 0) > 0 ? 'text-red-500' : 'text-green-500'}`}>
                {formatCurrency(overdueAmount || 0)}
              </p>
            </div>
            <div className="bg-white rounded-xl p-4 border border-[#e0ddd5]">
              <p className="text-xs text-[#7a7a78] mb-1">未付笔数</p>
              <p className="text-xl font-bold text-[#191918]">{details.length}</p>
            </div>
            <div className="bg-white rounded-xl p-4 border border-[#e0ddd5]">
              <p className="text-xs text-[#7a7a78] mb-1">{activeTab === 'receivable' ? '回款率' : '付款率'}</p>
              <p className={`text-xl font-bold ${(rate || 0) >= 80 ? 'text-green-500' : (rate || 0) >= 50 ? 'text-yellow-500' : 'text-red-500'}`}>
                {rate?.toFixed(1)}%
              </p>
            </div>
          </div>

          {/* Charts & Ranking */}
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
            {/* Aging Analysis */}
            <div className="bg-white rounded-xl p-5 border border-[#e0ddd5]">
              <h4 className="text-sm font-bold text-[#191918] mb-4">
                <i className="fas fa-chart-bar mr-2 text-[#d97757]"></i>账龄分析
              </h4>
              {agingData.some(d => d.amount > 0) ? (
                <ResponsiveContainer width="100%" height={200}>
                  <BarChart data={agingData}>
                    <CartesianGrid strokeDasharray="3 3" stroke="#f0eeeb" />
                    <XAxis dataKey="name" tick={{ fontSize: 11, fill: '#7a7a78' }} />
                    <YAxis tick={{ fontSize: 11, fill: '#7a7a78' }} />
                    <Tooltip formatter={(val: number) => formatCurrency(val)} />
                    <Bar dataKey="amount" fill="#d97757" radius={[4, 4, 0, 0]} name="金额" />
                  </BarChart>
                </ResponsiveContainer>
              ) : (
                <div className="flex items-center justify-center h-[200px] text-[#7a7a78] text-sm">暂无逾期数据</div>
              )}
            </div>

            {/* Ranking */}
            <div className="bg-white rounded-xl p-5 border border-[#e0ddd5]">
              <h4 className="text-sm font-bold text-[#191918] mb-4">
                <i className="fas fa-ranking-star mr-2 text-[#d97757]"></i>
                {activeTab === 'receivable' ? '客户欠款排名' : '供应商欠款排名'}
              </h4>
              {ranking.length > 0 ? (
                <div className="space-y-2">
                  {ranking.map((item, i) => (
                    <div key={i} className="flex items-center justify-between py-2 border-b border-[#f0eeeb] last:border-0">
                      <div className="flex items-center gap-2">
                        <span className={`w-5 h-5 rounded-full flex items-center justify-center text-[10px] font-bold text-white ${i < 3 ? 'bg-[#d97757]' : 'bg-[#b0b0ae]'}`}>{i + 1}</span>
                        <span className="text-sm text-[#191918]">{item.name}</span>
                      </div>
                      <span className="text-sm font-medium text-[#191918]">{formatCurrency(item.amount)}</span>
                    </div>
                  ))}
                </div>
              ) : (
                <div className="flex items-center justify-center h-[200px] text-[#7a7a78] text-sm">暂无数据</div>
              )}
            </div>
          </div>

          {/* Details Table */}
          <div className="bg-white rounded-xl border border-[#e0ddd5] overflow-hidden">
            <div className="px-5 py-3 border-b border-[#e0ddd5] flex items-center justify-between">
              <h4 className="text-sm font-bold text-[#191918]">
                <i className="fas fa-list-alt mr-2 text-[#d97757]"></i>未结清明细
              </h4>
              <span className="text-xs text-[#7a7a78]">共 {details.length} 笔</span>
            </div>
            {details.length > 0 ? (
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="bg-[#f9f9f8] text-[#7a7a78] text-xs">
                      <th className="px-4 py-2 text-left">日期</th>
                      <th className="px-4 py-2 text-left">{activeTab === 'receivable' ? '客户' : '供应商'}</th>
                      <th className="px-4 py-2 text-right">总金额</th>
                      <th className="px-4 py-2 text-right">已付</th>
                      <th className="px-4 py-2 text-right">欠款</th>
                      <th className="px-4 py-2 text-center">到期日</th>
                      <th className="px-4 py-2 text-center">状态</th>
                      <th className="px-4 py-2 text-center">操作</th>
                    </tr>
                  </thead>
                  <tbody>
                    {details.map((item: any) => {
                      const unpaid = (item.totalAmount || 0) - (item.paid_amount || 0);
                      const isOverdue = item.due_date && item.due_date < new Date().toISOString().split('T')[0];
                      return (
                        <tr key={item.id} className="border-t border-[#f0eeeb] hover:bg-[#f9f9f8]">
                          <td className="px-4 py-2.5">{item.date}</td>
                          <td className="px-4 py-2.5">{activeTab === 'receivable' ? item.customer : item.supplier}</td>
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
                              {isOverdue ? '已逾期' : item.payment_status === 'partial' ? '部分付款' : '未付'}
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
                              className="text-xs text-[#d97757] hover:text-[#c56646] font-medium"
                            >
                              <i className="fas fa-money-bill-wave mr-1"></i>
                              {activeTab === 'receivable' ? '记录收款' : '记录付款'}
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
                  <p className="text-sm">所有款项已结清</p>
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
              <i className="fas fa-money-bill-wave mr-2 text-[#d97757]"></i>
              {paymentModal.type === 'sale' ? '记录收款' : '记录付款'}
            </h3>
            <div className="space-y-3 mb-6">
              <div className="flex justify-between text-sm">
                <span className="text-[#7a7a78]">{paymentModal.type === 'sale' ? '客户' : '供应商'}</span>
                <span className="font-medium">{paymentModal.name}</span>
              </div>
              <div className="flex justify-between text-sm">
                <span className="text-[#7a7a78]">总金额</span>
                <span className="font-medium">{formatCurrency(paymentModal.total)}</span>
              </div>
              <div className="flex justify-between text-sm">
                <span className="text-[#7a7a78]">已付金额</span>
                <span className="font-medium text-green-600">{formatCurrency(paymentModal.paid)}</span>
              </div>
              <div className="flex justify-between text-sm">
                <span className="text-[#7a7a78]">剩余欠款</span>
                <span className="font-medium text-red-500">{formatCurrency(paymentModal.total - paymentModal.paid)}</span>
              </div>
              <div className="pt-2">
                <label className="block text-xs text-[#7a7a78] mb-1">本次{paymentModal.type === 'sale' ? '收款' : '付款'}金额</label>
                <input
                  type="number"
                  value={paymentAmount}
                  onChange={e => setPaymentAmount(e.target.value)}
                  placeholder={`最多 ${formatCurrency(paymentModal.total - paymentModal.paid)}`}
                  className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm focus:ring-2 focus:ring-[#d97757] focus:border-transparent"
                />
              </div>
              <div className="flex gap-2 pt-1">
                <button
                  onClick={() => setPaymentAmount(String(paymentModal.total - paymentModal.paid))}
                  className="text-xs px-3 py-1 bg-[#f0eeeb] text-[#7a7a78] rounded-lg hover:bg-[#e0ddd5]"
                >全额结清</button>
              </div>
            </div>
            <div className="flex gap-3">
              <button onClick={() => { setPaymentModal(null); setPaymentAmount(''); }} className="flex-1 py-2 text-sm text-[#7a7a78] border border-[#e0ddd5] rounded-lg hover:bg-[#f0eeeb]">取消</button>
              <button onClick={handlePayment} disabled={!paymentAmount || parseFloat(paymentAmount) <= 0} className="flex-1 py-2 text-sm bg-[#d97757] text-white rounded-lg hover:bg-[#c56646] disabled:opacity-50">确认</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};

export default AccountsPage;
