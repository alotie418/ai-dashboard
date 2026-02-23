
import React, { useState, useMemo } from 'react';
import { BusinessData } from '../types';

interface Props {
  data: BusinessData;
  selectedYear: string;
  selectedQuarter: string;
  selectedMonth: string;
}

type InvoiceType = 'all' | 'input' | 'output';

const InventoryPage: React.FC<Props> = ({ data, selectedYear, selectedQuarter, selectedMonth }) => {
  const [searchTerm, setSearchTerm] = useState('');
  const [filterType, setFilterType] = useState<InvoiceType>('all');
  const [showAdvanced, setShowAdvanced] = useState(false);

  // Advanced filter state
  const [dateFrom, setDateFrom] = useState('');
  const [dateTo, setDateTo] = useState('');
  const [amountMin, setAmountMin] = useState('');
  const [amountMax, setAmountMax] = useState('');
  const [weightMin, setWeightMin] = useState('');
  const [weightMax, setWeightMax] = useState('');
  const [statusFilter, setStatusFilter] = useState<string>('all');

  const clearAdvancedFilters = () => {
    setDateFrom(''); setDateTo('');
    setAmountMin(''); setAmountMax('');
    setWeightMin(''); setWeightMax('');
    setStatusFilter('all');
  };

  const hasAdvancedFilters = dateFrom || dateTo || amountMin || amountMax || weightMin || weightMax || statusFilter !== 'all';

  // Simulated combined invoice list based on mock business data logic
  const allInvoices = useMemo(() => {
    const output: any[] = [];
    const input: any[] = [];
    return [...output, ...input];
  }, []);

  const filteredInvoices = useMemo(() => {
    return allInvoices.filter(inv => {
      const matchesSearch = inv.partner.toLowerCase().includes(searchTerm.toLowerCase()) ||
        inv.invoiceNo.includes(searchTerm);
      const matchesType = filterType === 'all' ||
        (filterType === 'input' && inv.type === '进项') ||
        (filterType === 'output' && inv.type === '销项');

      // Advanced filters
      const matchesDateFrom = !dateFrom || inv.date >= dateFrom;
      const matchesDateTo = !dateTo || inv.date <= dateTo;
      const matchesAmountMin = !amountMin || inv.amount >= parseFloat(amountMin);
      const matchesAmountMax = !amountMax || inv.amount <= parseFloat(amountMax);
      const invWeight = parseFloat(String(inv.weight).replace(/[^0-9.]/g, '')) || 0;
      const matchesWeightMin = !weightMin || invWeight >= parseFloat(weightMin);
      const matchesWeightMax = !weightMax || invWeight <= parseFloat(weightMax);
      const matchesStatus = statusFilter === 'all' || inv.status === statusFilter;

      return matchesSearch && matchesType &&
        matchesDateFrom && matchesDateTo &&
        matchesAmountMin && matchesAmountMax &&
        matchesWeightMin && matchesWeightMax &&
        matchesStatus;
    });
  }, [allInvoices, searchTerm, filterType, dateFrom, dateTo, amountMin, amountMax, weightMin, weightMax, statusFilter]);

  const stats = {
    currentStock: "0.00t",
    totalInputWeight: "0.0t",
    totalOutputWeight: "0.0t",
    pendingCertification: "¥0.00"
  };

  return (
    <div className="space-y-8 animate-in fade-in duration-500">
      {/* Header Stats Grid */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
        <StatCard
          title="实时库存量"
          value={stats.currentStock}
          sub="库存警戒：低"
          icon="fa-warehouse"
          color="text-amber-500"
          bg="bg-amber-500/10"
        />
        <StatCard
          title="累计进项吨数"
          value={stats.totalInputWeight}
          sub="暂无进项记录"
          icon="fa-file-import"
          color="text-[#d97757]"
          bg="bg-[#d97757]/10"
        />
        <StatCard
          title="累计销项吨数"
          value={stats.totalOutputWeight}
          sub="暂无销售记录"
          icon="fa-file-export"
          color="text-emerald-600"
          bg="bg-emerald-500/10"
        />
        <StatCard
          title="待认证进项额"
          value={stats.pendingCertification}
          sub="预计可抵扣税额"
          icon="fa-clock"
          color="text-[#d97757]"
          bg="bg-[#d97757]/10"
        />
      </div>

      {/* Search and Filters */}
      <div className="bg-white/80 border border-[#e0ddd5] p-6 rounded-xl flex flex-col md:flex-row md:items-center justify-between gap-4" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.05)' }}>
        <div className="relative flex-1 max-w-md">
          <i className="fas fa-search absolute left-4 top-1/2 -translate-y-1/2 text-[#5c5c5a]"></i>
          <input
            type="text"
            placeholder="搜索发票号或往来单位..."
            value={searchTerm}
            onChange={(e) => setSearchTerm(e.target.value)}
            className="w-full bg-white border border-[#e0ddd5] rounded-xl py-3 pl-12 pr-4 text-sm focus:outline-none focus:ring-2 focus:ring-[#d97757] transition-all"
          />
        </div>

        <div className="flex items-center space-x-2 bg-white p-1.5 rounded-xl border border-[#e0ddd5]">
          <FilterTab active={filterType === 'all'} onClick={() => setFilterType('all')} label="全部发票" />
          <FilterTab active={filterType === 'input'} onClick={() => setFilterType('input')} label="进项明细" />
          <FilterTab active={filterType === 'output'} onClick={() => setFilterType('output')} label="销项明细" />
        </div>
      </div>

      {/* Main Data Table */}
      <div className="bg-white/80 border border-[#e0ddd5] rounded-xl overflow-hidden" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.05)' }}>
        <div className="p-8 border-b border-[#e0ddd5] flex justify-between items-center bg-[#f9f9f8]/20">
          <div>
            <h3 className="text-xl font-bold text-[#191918]">发票流转全景视图</h3>
            <p className="text-sm text-[#5c5c5a] mt-1">核对发票流与物流的一致性 (Inventory vs Invoices)</p>
          </div>
          <div className="flex space-x-3">
            <button
              onClick={() => setShowAdvanced(!showAdvanced)}
              className={`px-4 py-2 text-xs font-bold rounded-xl transition-all flex items-center ${showAdvanced || hasAdvancedFilters ? 'bg-[#d97757]/10 text-[#d97757] border border-[#d97757]/30' : 'text-[#4a4a48] hover:text-[#191918] hover:bg-[#f0eeeb] border border-transparent'}`}
            >
              <i className={`fas fa-filter mr-2 ${hasAdvancedFilters ? 'text-[#d97757]' : ''}`}></i>
              高级过滤
              {hasAdvancedFilters && <span className="ml-2 w-2 h-2 bg-[#d97757] rounded-full"></span>}
            </button>
            <button className="px-4 py-2 bg-[#d97757] text-white rounded-xl text-xs font-bold hover:bg-[#c56a4a] transition-all" style={{ boxShadow: '0 4px 16px rgba(217,119,87,0.15)' }}>
              <i className="fas fa-download mr-2"></i> 导出报表
            </button>
          </div>
        </div>

        {/* Advanced Filter Panel */}
        {showAdvanced && (
          <div className="px-8 py-6 border-b border-[#e0ddd5] bg-[#f9f9f8]/60 animate-in slide-in-from-top-2 duration-300">
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
              {/* Date Range */}
              <div className="space-y-2">
                <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">开票日期范围</label>
                <div className="flex items-center space-x-2">
                  <input type="date" value={dateFrom} onChange={e => setDateFrom(e.target.value)}
                    className="flex-1 bg-white border border-[#e0ddd5] rounded-lg px-3 py-2 text-xs text-[#191918] focus:outline-none focus:ring-2 focus:ring-[#d97757]/50 transition-all" />
                  <span className="text-[#5c5c5a] text-xs">—</span>
                  <input type="date" value={dateTo} onChange={e => setDateTo(e.target.value)}
                    className="flex-1 bg-white border border-[#e0ddd5] rounded-lg px-3 py-2 text-xs text-[#191918] focus:outline-none focus:ring-2 focus:ring-[#d97757]/50 transition-all" />
                </div>
              </div>

              {/* Amount Range */}
              <div className="space-y-2">
                <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">金额范围 (不含税)</label>
                <div className="flex items-center space-x-2">
                  <input type="number" placeholder="最低" value={amountMin} onChange={e => setAmountMin(e.target.value)}
                    className="flex-1 bg-white border border-[#e0ddd5] rounded-lg px-3 py-2 text-xs text-[#191918] focus:outline-none focus:ring-2 focus:ring-[#d97757]/50 transition-all" />
                  <span className="text-[#5c5c5a] text-xs">—</span>
                  <input type="number" placeholder="最高" value={amountMax} onChange={e => setAmountMax(e.target.value)}
                    className="flex-1 bg-white border border-[#e0ddd5] rounded-lg px-3 py-2 text-xs text-[#191918] focus:outline-none focus:ring-2 focus:ring-[#d97757]/50 transition-all" />
                </div>
              </div>

              {/* Weight Range */}
              <div className="space-y-2">
                <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">重量范围 (吨)</label>
                <div className="flex items-center space-x-2">
                  <input type="number" placeholder="最低" value={weightMin} onChange={e => setWeightMin(e.target.value)}
                    className="flex-1 bg-white border border-[#e0ddd5] rounded-lg px-3 py-2 text-xs text-[#191918] focus:outline-none focus:ring-2 focus:ring-[#d97757]/50 transition-all" />
                  <span className="text-[#5c5c5a] text-xs">—</span>
                  <input type="number" placeholder="最高" value={weightMax} onChange={e => setWeightMax(e.target.value)}
                    className="flex-1 bg-white border border-[#e0ddd5] rounded-lg px-3 py-2 text-xs text-[#191918] focus:outline-none focus:ring-2 focus:ring-[#d97757]/50 transition-all" />
                </div>
              </div>

              {/* Status Filter */}
              <div className="space-y-2">
                <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">发票状态</label>
                <select value={statusFilter} onChange={e => setStatusFilter(e.target.value)}
                  className="w-full bg-white border border-[#e0ddd5] rounded-lg px-3 py-2 text-xs text-[#191918] focus:outline-none focus:ring-2 focus:ring-[#d97757]/50 transition-all appearance-none cursor-pointer"
                  style={{ backgroundImage: `url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' fill='none' viewBox='0 0 20 20'%3E%3Cpath stroke='%236b7280' stroke-linecap='round' stroke-linejoin='round' stroke-width='1.5' d='M6 8l4 4 4-4'/%3E%3C/svg%3E")`, backgroundPosition: 'right 0.5rem center', backgroundRepeat: 'no-repeat', backgroundSize: '1.5em 1.5em', paddingRight: '2.5rem' }}>
                  <option value="all">全部状态</option>
                  <option value="已验真">已验真</option>
                  <option value="已认证">已认证</option>
                  <option value="已抵扣">已抵扣</option>
                  <option value="待认证">待认证</option>
                  <option value="待开票">待开票</option>
                </select>
              </div>
            </div>

            {/* Filter Actions */}
            <div className="mt-5 flex items-center justify-between">
              <div className="text-xs text-[#5c5c5a]">
                {hasAdvancedFilters && (
                  <span className="flex items-center">
                    <i className="fas fa-info-circle mr-1.5 text-[#d97757]"></i>
                    已启用高级过滤条件，共 {filteredInvoices.length} 条匹配记录
                  </span>
                )}
              </div>
              <button
                onClick={clearAdvancedFilters}
                disabled={!hasAdvancedFilters}
                className="px-4 py-2 text-xs font-bold text-[#5c5c5a] hover:text-[#d97757] disabled:opacity-30 disabled:cursor-not-allowed transition-all flex items-center"
              >
                <i className="fas fa-times mr-1.5"></i> 清除所有过滤
              </button>
            </div>
          </div>
        )}

        <div className="overflow-x-auto">
          <table className="w-full text-left border-collapse min-w-[1000px]">
            <thead>
              <tr className="bg-[#f9f9f8]/30 text-[#5c5c5a] text-[10px] uppercase font-bold tracking-widest">
                <th className="px-8 py-5">开票日期</th>
                <th className="px-8 py-5">类型</th>
                <th className="px-8 py-5">往来单位</th>
                <th className="px-8 py-5">实物重量</th>
                <th className="px-8 py-5 text-right">金额 (不含税)</th>
                <th className="px-8 py-5 text-right">税额</th>
                <th className="px-8 py-5">发票号码</th>
                <th className="px-8 py-5 text-center">状态</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-[#e0ddd5]">
              {filteredInvoices.map((inv) => (
                <tr key={inv.invoiceNo || inv.date + inv.partner} className="group hover:bg-[#f9f9f8]/40 transition-all">
                  <td className="px-8 py-5 text-sm text-[#4a4a48]">{inv.date}</td>
                  <td className="px-8 py-5">
                    <span className={`px-2 py-1 rounded text-[10px] font-bold ${inv.type === '销项' ? 'bg-[#d97757]/10 text-[#d97757]' : 'bg-amber-500/10 text-amber-400'}`}>
                      {inv.type}
                    </span>
                  </td>
                  <td className="px-8 py-5 text-sm font-bold text-[#191918] group-hover:text-[#191918] transition-colors">{inv.partner}</td>
                  <td className="px-8 py-5 text-sm font-mono text-[#5c5c5a]">{inv.weight}</td>
                  <td className="px-8 py-5 text-sm text-right font-bold text-[#191918]">¥{inv.amount.toLocaleString()}</td>
                  <td className="px-8 py-5 text-sm text-right text-[#4a4a48]">¥{inv.tax.toLocaleString()}</td>
                  <td className="px-8 py-5 text-sm font-mono text-[#5c5c5a] tracking-tighter">{inv.invoiceNo}</td>
                  <td className="px-8 py-5 text-center">
                    <StatusBadge status={inv.status} />
                  </td>
                </tr>
              ))}
              {filteredInvoices.length === 0 && (
                <tr>
                  <td colSpan={8} className="px-8 py-20 text-center text-[#5c5c5a] italic">
                    <div className="flex flex-col items-center">
                      <i className="fas fa-search text-4xl mb-4 opacity-20"></i>
                      <p>未找到匹配的发票记录</p>
                      {hasAdvancedFilters && (
                        <button onClick={clearAdvancedFilters} className="mt-3 text-[#d97757] text-xs font-bold hover:underline">
                          <i className="fas fa-times mr-1"></i> 清除过滤条件重试
                        </button>
                      )}
                    </div>
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
};

const StatCard: React.FC<{ title: string, value: string, sub: string, icon: string, color: string, bg: string }> = ({ title, value, sub, icon, color, bg }) => (
  <div className="bg-white/80 border border-[#e0ddd5] p-6 rounded-xl group hover:border-[#d97757]/30 transition-all duration-300" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.05)' }}>
    <div className="flex items-center justify-between mb-4">
      <div className={`w-12 h-12 ${bg} rounded-xl flex items-center justify-center ${color} group-hover:scale-110 transition-transform`}>
        <i className={`fas ${icon} text-xl`}></i>
      </div>
      <div className="text-right">
        <p className="text-[#5c5c5a] text-[10px] uppercase font-bold tracking-widest">{title}</p>
        <p className={`text-2xl font-bold ${color} tracking-tighter`}>{value}</p>
      </div>
    </div>
    <p className="text-[#5c5c5a] text-xs italic">{sub}</p>
  </div>
);

const FilterTab: React.FC<{ active: boolean, onClick: () => void, label: string }> = ({ active, onClick, label }) => (
  <button
    onClick={onClick}
    className={`px-5 py-2 rounded-xl text-xs font-bold transition-all duration-300 ${active ? 'bg-[#d97757] text-white' : 'text-[#5c5c5a] hover:text-[#4a4a48]'}`}
    style={active ? { boxShadow: '0 4px 16px rgba(217,119,87,0.15)' } : {}}
  >
    {label}
  </button>
);

const StatusBadge: React.FC<{ status: string }> = ({ status }) => {
  const colors: Record<string, string> = {
    '已验真': 'bg-[#d97757]/10 text-[#d97757] border-[#d97757]/20',
    '已认证': 'bg-emerald-500/10 text-emerald-600 border-emerald-500/20',
    '已抵扣': 'bg-purple-500/10 text-purple-400 border-purple-500/20'
  };
  return (
    <span className={`px-2 py-0.5 rounded border text-[10px] font-bold ${colors[status] || 'bg-[#f0eeeb]/10 text-[#4a4a48] border-[#e0ddd5]/20'}`}>
      {status}
    </span>
  );
};

export default InventoryPage;
