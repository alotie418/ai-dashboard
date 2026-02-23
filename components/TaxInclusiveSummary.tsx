
import React from 'react';
import { TaxInclusiveSummaryData } from '../types';

interface Props {
  data: TaxInclusiveSummaryData;
}

const TaxInclusiveSummary: React.FC<Props> = ({ data }) => {
  const formatVal = (val: number) => `¥${val.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

  return (
    <div className="bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl overflow-hidden flex flex-col h-full" style={{boxShadow: '0 4px 24px rgba(0,0,0,0.06)'}}>
      <div className="p-6 border-b border-[#e0ddd5] flex items-center space-x-3">
        <i className="fas fa-balance-scale text-lg text-emerald-400"></i>
        <h3 className="text-lg font-bold text-[#191918]">含税金额汇总 (对账用)</h3>
      </div>

      <div className="flex-1 flex flex-col">
        {/* Main Totals */}
        <div className="px-6 py-5 space-y-5">
          <div className="flex justify-between items-center">
            <span className="text-sm text-[#4a4a48] font-medium">采购含税总额</span>
            <span className="text-base font-semibold text-[#191918]">{formatVal(data.purchaseTotal)}</span>
          </div>
          <div className="flex justify-between items-center">
            <span className="text-sm text-[#4a4a48] font-medium">销售含税总额</span>
            <span className="text-base font-semibold text-[#191918]">{formatVal(data.salesTotal)}</span>
          </div>
        </div>

        {/* Difference (Green) */}
        <div className="px-6 py-6 border-t border-[#e0ddd5] bg-emerald-500/5">
          <div className="flex justify-between items-center">
            <span className="text-base font-bold text-[#191918]">含税差额</span>
            <span className="text-xl font-bold text-emerald-500">{formatVal(data.difference)}</span>
          </div>
        </div>

        {/* Footer Notes */}
        <div className="mt-auto px-6 py-6 border-t border-[#e0ddd5] space-y-2 bg-white/20">
          <div className="flex items-start space-x-2 text-xs text-[#5c5c5a]">
            <span role="img" aria-label="lightbulb">💡</span>
            <span>含税金额用于与供应商/客户进行往来对账</span>
          </div>
          <div className="flex items-start space-x-2 text-xs text-[#5c5c5a]">
            <span role="img" aria-label="lightbulb">💡</span>
            <span>核心财务决策应基于不含税金额进行分析</span>
          </div>
        </div>
      </div>
    </div>
  );
};

export default TaxInclusiveSummary;
