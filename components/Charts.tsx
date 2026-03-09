
import React from 'react';
import {
  ComposedChart, Area, Bar, Line, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer,
  Legend, Cell, PieChart, Pie, BarChart
} from 'recharts';
import { ChartData, CategoryData } from '../types';

// Anthropic-style warm color palette
const COLORS = ['#d97757', '#10b981', '#8b5cf6', '#f59e0b', '#3b82f6'];

const EmptyChartPlaceholder: React.FC<{ height?: string }> = ({ height = 'h-80' }) => (
  <div className={`${height} w-full flex items-center justify-center text-sm text-[#5c5c5a]`}>
    <div className="text-center">
      <i className="fas fa-chart-bar text-2xl text-[#d1cdc4] mb-2 block"></i>
      暂无图表数据
    </div>
  </div>
);

export const PLStatementChart: React.FC<{ data: ChartData[] }> = ({ data }) => {
  if (!data || data.length === 0) return <EmptyChartPlaceholder />;
  return (
  <div className="h-80 w-full">
    <ResponsiveContainer width="100%" height="100%">
      <ComposedChart data={data} margin={{ top: 20, right: 20, bottom: 20, left: 20 }}>
        <CartesianGrid strokeDasharray="3 3" stroke="#e0ddd5" vertical={false} />
        <XAxis
          dataKey="name"
          stroke="#6b6b69"
          tickLine={false}
          axisLine={false}
          fontSize={12}
          dy={10}
        />
        <YAxis
          stroke="#6b6b69"
          tickLine={false}
          axisLine={false}
          fontSize={12}
          tickFormatter={(value) => `¥${value/1000}k`}
        />
        <Tooltip
          contentStyle={{ backgroundColor: '#ffffff', border: '1px solid #e0ddd5', borderRadius: '12px', boxShadow: '0 8px 24px rgba(0,0,0,0.08)' }}
          itemStyle={{ color: '#333330' }}
        />
        <Legend
          verticalAlign="top"
          align="right"
          wrapperStyle={{ paddingBottom: '20px', fontSize: '12px', color: '#4a4a48' }}
        />
        <Bar dataKey="revenue" name="营业收入" fill="#d97757" radius={[4, 4, 0, 0]} barSize={30} />
        <Bar dataKey="cost" name="营业成本" fill="#e8956e" radius={[4, 4, 0, 0]} barSize={30} opacity={0.6} />
        <Line type="monotone" dataKey="profit" name="营业利润" stroke="#10b981" strokeWidth={3} dot={{ fill: '#10b981', r: 4 }} />
      </ComposedChart>
    </ResponsiveContainer>
  </div>
  );
};

export const ProfitBarChart: React.FC<{ data: ChartData[] }> = ({ data }) => {
  if (!data || data.length === 0) return <EmptyChartPlaceholder />;
  return (
  <div className="h-80 w-full">
    <ResponsiveContainer width="100%" height="100%">
      <BarChart data={data} margin={{ top: 20, right: 20, bottom: 20, left: 20 }}>
        <CartesianGrid strokeDasharray="3 3" stroke="#e0ddd5" vertical={false} />
        <XAxis dataKey="name" stroke="#6b6b69" tickLine={false} axisLine={false} fontSize={12} dy={10} />
        <YAxis stroke="#6b6b69" tickLine={false} axisLine={false} fontSize={12} tickFormatter={(value) => `¥${value/1000}k`} />
        <Tooltip
          contentStyle={{ backgroundColor: '#ffffff', border: '1px solid #e0ddd5', borderRadius: '12px', boxShadow: '0 8px 24px rgba(0,0,0,0.08)' }}
          itemStyle={{ color: '#333330' }}
        />
        <Bar dataKey="profit" fill="#d97757" radius={[4, 4, 0, 0]} barSize={40} />
      </BarChart>
    </ResponsiveContainer>
  </div>
  );
};

export const ProfitabilityBarChart: React.FC<{ data: ChartData[] }> = ({ data }) => {
  if (!data || data.length === 0) return <EmptyChartPlaceholder />;
  return (
  <div className="h-80 w-full">
    <ResponsiveContainer width="100%" height="100%">
      <BarChart data={data}>
        <CartesianGrid strokeDasharray="3 3" stroke="#e0ddd5" vertical={false} />
        <XAxis dataKey="name" stroke="#6b6b69" tickLine={false} axisLine={false} fontSize={12} dy={10} />
        <YAxis
          stroke="#6b6b69"
          tickLine={false}
          axisLine={false}
          fontSize={12}
          tickFormatter={(value) => `¥${value/1000}k`}
        />
        <Tooltip
          cursor={{fill: 'rgba(217, 119, 87, 0.06)'}}
          contentStyle={{ backgroundColor: '#ffffff', border: '1px solid #e0ddd5', borderRadius: '12px', boxShadow: '0 8px 24px rgba(0,0,0,0.08)' }}
          itemStyle={{ color: '#333330' }}
        />
        <Bar dataKey="profit" fill="#10b981" radius={[4, 4, 0, 0]} barSize={40} />
      </BarChart>
    </ResponsiveContainer>
  </div>
  );
};

export const DistributionPieChart: React.FC<{ data: CategoryData[] }> = ({ data }) => {
  if (!data || data.length === 0) return <EmptyChartPlaceholder height="h-64" />;
  return (
  <div className="h-64 w-full">
    <ResponsiveContainer width="100%" height="100%">
      <PieChart>
        <Pie
          data={data}
          cx="50%"
          cy="50%"
          innerRadius={60}
          outerRadius={80}
          paddingAngle={5}
          dataKey="value"
        >
          {data.map((entry, index) => (
            <Cell key={`cell-${index}`} fill={COLORS[index % COLORS.length]} stroke="none" />
          ))}
        </Pie>
        <Tooltip
          contentStyle={{ backgroundColor: '#ffffff', border: '1px solid #e0ddd5', borderRadius: '12px', boxShadow: '0 8px 24px rgba(0,0,0,0.08)' }}
          itemStyle={{ color: '#333330' }}
        />
        <Legend
          verticalAlign="bottom"
          align="center"
          iconType="circle"
          wrapperStyle={{ paddingTop: '20px', fontSize: '12px', color: '#4a4a48' }}
        />
      </PieChart>
    </ResponsiveContainer>
  </div>
  );
};
