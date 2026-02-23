
import React from 'react';
import { AIAnalysis } from '../types';

interface AIInsightsProps {
  analysis: AIAnalysis | null;
  loading: boolean;
  error?: string | null;
  onRefresh: () => void;
}

const AIInsights: React.FC<AIInsightsProps> = ({ analysis, loading, error, onRefresh }) => {
  return (
    <div className="bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl overflow-hidden flex flex-col h-full" style={{boxShadow: '0 4px 24px rgba(0,0,0,0.06)'}}>
      <div className="p-4 bg-[#f9f9f8]/50 border-b border-[#e0ddd5] flex justify-between items-center">
        <h3 className="text-lg font-bold flex items-center">
          <i className="fas fa-robot text-[#d97757] mr-2"></i>
          AI 简报
        </h3>
        <button
          onClick={onRefresh}
          disabled={loading}
          className="text-[#6b6b69] hover:text-[#191918] transition-colors"
        >
          <i className={`fas fa-sync-alt ${loading ? 'animate-spin' : ''}`}></i>
        </button>
      </div>

      <div className="p-6 overflow-y-auto custom-scrollbar flex-1 space-y-6">
        {loading ? (
          <div className="flex flex-col items-center justify-center h-full py-10 space-y-4">
            <div className="w-12 h-12 border-4 border-[#d97757]/30 border-t-[#d97757] rounded-full animate-spin"></div>
            <p className="text-[#6b6b69] animate-pulse">正在深度分析数据...</p>
          </div>
        ) : analysis ? (
          <>
            <section>
              <h4 className="text-xs font-semibold text-[#d97757] uppercase tracking-widest mb-2">执行摘要</h4>
              <p className="text-[#4a4a48] leading-relaxed italic border-l-2 border-[#d97757]/50 pl-4 bg-[#d97757]/5 py-2 rounded-r-lg">
                "{analysis.summary}"
              </p>
            </section>

            <section>
              <h4 className="text-xs font-semibold text-emerald-400 uppercase tracking-widest mb-3">核心业务洞察</h4>
              <ul className="space-y-3">
                {analysis.topInsights.map((insight, idx) => (
                  <li key={idx} className="flex items-start">
                    <span className="flex-shrink-0 w-1.5 h-1.5 mt-2 rounded-full bg-emerald-500 mr-3"></span>
                    <span className="text-[#4a4a48] text-sm">{insight}</span>
                  </li>
                ))}
              </ul>
            </section>

            {analysis.anomalies.length > 0 && (
              <section>
                <h4 className="text-xs font-semibold text-rose-400 uppercase tracking-widest mb-3">异常状况检测</h4>
                <ul className="space-y-3">
                  {analysis.anomalies.map((anomaly, idx) => (
                    <li key={idx} className="flex items-start bg-rose-500/5 border border-rose-500/20 p-3 rounded-xl">
                      <i className="fas fa-exclamation-triangle text-rose-500 mt-0.5 mr-3 text-sm"></i>
                      <span className="text-[#4a4a48] text-sm">{anomaly}</span>
                    </li>
                  ))}
                </ul>
              </section>
            )}

            <section>
              <h4 className="text-xs font-semibold text-[#d97757] uppercase tracking-widest mb-3">落地行动建议</h4>
              <div className="space-y-3">
                {analysis.recommendations.map((rec, idx) => (
                  <div key={idx} className="bg-[#f0eeeb]/30 p-4 rounded-xl border border-[#e0ddd5] hover:border-[#d97757]/30 transition-colors group">
                    <div className="flex items-center mb-1">
                      <span className="bg-[#d97757]/20 text-[#d97757] text-[10px] px-2 py-0.5 rounded-full mr-2">建议 {idx + 1}</span>
                    </div>
                    <p className="text-[#4a4a48] text-sm group-hover:text-[#191918] transition-colors">{rec}</p>
                  </div>
                ))}
              </div>
            </section>
          </>
        ) : error ? (
          <div className="text-center py-10 space-y-4">
            <i className="fas fa-exclamation-circle text-rose-500 text-3xl"></i>
            <p className="text-rose-400 text-sm">{error}</p>
            <button onClick={onRefresh} className="px-4 py-2 bg-[#f9f9f8] hover:bg-[#f0eeeb] text-[#4a4a48] rounded-xl text-xs border border-[#e0ddd5] transition-colors">
              <i className="fas fa-redo mr-2"></i>重试
            </button>
          </div>
        ) : (
          <div className="text-center py-10">
            <p className="text-[#5c5c5a]">暂无分析数据。点击刷新按钮生成。</p>
          </div>
        )}
      </div>

      <div className="p-4 bg-white text-[10px] text-[#5c5c5a] text-center uppercase tracking-tighter border-t border-[#e0ddd5]">
        由 Gemini 3 Flash 提供算力支持
      </div>
    </div>
  );
};

export default AIInsights;
