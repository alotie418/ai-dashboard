
import React from 'react';
import { Metric } from '../types';

interface MetricCardProps {
  metric: Metric;
}

const MetricCard: React.FC<MetricCardProps> = ({ metric }) => {
  return (
    <div className="bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl p-6 hover:shadow-sm transition-all duration-300 flex flex-col justify-between" style={{boxShadow: '0 4px 24px rgba(0,0,0,0.06)'}}>
      <div className="space-y-1">
        <h3 className="text-[#4a4a48] text-sm font-medium">{metric.label}</h3>
        <p className="text-[clamp(1rem,1.45vw,1.875rem)] font-bold text-[#191918] tracking-tight tabular-nums whitespace-nowrap overflow-hidden text-ellipsis" title={metric.value}>{metric.value}</p>
      </div>
      <div className="mt-4 pt-4 border-t border-[#e0ddd5]/50">
        <p className="text-xs text-[#4a4a48] font-medium">{metric.subValue}</p>
      </div>
    </div>
  );
};

export default MetricCard;
