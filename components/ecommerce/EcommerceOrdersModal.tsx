// 暂存订单预览模态（PR-EC4 · 仅读，不写账本）
// 从连接拉单 → 展示暂存订单 → 只读商品匹配（名称精确）→ 去重/错误/同步日志展示。
// 严格约束：无「导入/提交/入账/确认导入」按钮；仅「拉单 / 刷新 / 关闭」。
// 不写 sales/sales_items、不提交、不改匹配落库；fees/refunds 仅信息展示。
import React, { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import {
  listProducts,
  pullEcommerce,
  listStagedOrders,
  listEcommerceSyncLog,
  type Product,
  type StagedOrder,
  type EcommerceSyncLogEntry,
  type EcommerceConnection,
} from '../../services/api';
import { matchOrderItems, type OrderMatchStatus, type ItemMatchStatus } from './matchStagedItems';

const EcommerceOrdersModal: React.FC<{ connection: EcommerceConnection; onClose: () => void }> = ({ connection, onClose }) => {
  const { t } = useTranslation();
  const [products, setProducts] = useState<Product[]>([]);
  const [staged, setStaged] = useState<StagedOrder[]>([]);
  const [syncLog, setSyncLog] = useState<EcommerceSyncLogEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [pulling, setPulling] = useState(false);
  const [expanded, setExpanded] = useState<Set<number>>(new Set());
  const [message, setMessage] = useState<{ type: 'success' | 'error'; text: string } | null>(null);

  const reload = async () => {
    const [prod, rows, log] = await Promise.all([
      listProducts().catch(() => [] as Product[]),
      listStagedOrders({ connectionId: connection.id }).catch(() => [] as StagedOrder[]),
      listEcommerceSyncLog({ connectionId: connection.id, limit: 5 }).catch(() => [] as EcommerceSyncLogEntry[]),
    ]);
    setProducts(prod); setStaged(rows); setSyncLog(log);
  };

  useEffect(() => {
    let alive = true;
    (async () => { await reload(); if (alive) setLoading(false); })();
    return () => { alive = false; };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const flash = (type: 'success' | 'error', text: string) => { setMessage({ type, text }); setTimeout(() => setMessage(null), 3000); };

  const doPull = async () => {
    setPulling(true); setMessage(null);
    try {
      const r = await pullEcommerce(connection.id);
      if (r.ok) flash('success', t('settings.ecommerce.orders.runSummary', { pulled: r.pulled ?? 0, new: r.stagedNew ?? 0, updated: r.stagedUpdated ?? 0, errors: r.errors ?? 0 }));
      else flash('error', t('settings.ecommerce.orders.pullError', { msg: (r.code || '') + (r.message ? ' · ' + r.message : '') }));
      await reload();
    } catch (e: any) {
      flash('error', t('settings.ecommerce.orders.pullError', { msg: e?.message || t('common.error') }));
    } finally { setPulling(false); }
  };

  const doRefresh = async () => { setLoading(true); await reload(); setLoading(false); };

  const toggle = (id: number) => setExpanded((prev) => { const n = new Set(prev); n.has(id) ? n.delete(id) : n.add(id); return n; });

  const fmtTime = (iso: string | null) => { if (!iso) return ''; try { return new Date(iso.includes('T') ? iso : iso.replace(' ', 'T') + 'Z').toLocaleString(); } catch { return iso; } };
  const money = (v: number | null, cur: string | null) => v == null ? '—' : `${cur ? cur + ' ' : ''}${v.toFixed(2)}`;

  const orderMatchBadge = (s: OrderMatchStatus) => {
    const map: Record<OrderMatchStatus, { key: string; cls: string }> = {
      matched: { key: 'matchMatched', cls: 'text-emerald-600 bg-emerald-50' },
      partial: { key: 'matchPartial', cls: 'text-amber-700 bg-amber-50' },
      ambiguous: { key: 'matchAmbiguous', cls: 'text-rose-600 bg-rose-50' },
      unmatched: { key: 'matchUnmatched', cls: 'text-[#5c5c5a] bg-[#f0eeeb]' },
      empty: { key: 'matchEmpty', cls: 'text-[#5c5c5a] bg-[#f0eeeb]' },
    };
    const m = map[s];
    return <span className={`text-[10px] font-bold px-2 py-0.5 rounded ${m.cls}`}>{t('settings.ecommerce.orders.' + m.key)}</span>;
  };
  const itemMatchBadge = (s: ItemMatchStatus) => {
    if (s === 'matched') return <span className="text-[10px] text-emerald-600 bg-emerald-50 px-1.5 py-0.5 rounded">{t('settings.ecommerce.orders.matchMatched')}</span>;
    if (s === 'ambiguous') return <span className="text-[10px] text-rose-600 bg-rose-50 px-1.5 py-0.5 rounded" title={t('settings.ecommerce.orders.ambiguousHint')}>{t('settings.ecommerce.orders.matchAmbiguous')}</span>;
    return <span className="text-[10px] text-[#8a8a88] bg-[#f0eeeb] px-1.5 py-0.5 rounded" title={t('settings.ecommerce.orders.descriptionOnly')}>{t('settings.ecommerce.orders.matchUnmatched')}</span>;
  };
  const stageBadge = (s: string | null) => {
    if (s === 'committed') return <span className="text-[10px] font-bold text-primary bg-primary/10 px-2 py-0.5 rounded">{t('settings.ecommerce.orders.stageCommitted')}</span>;
    if (s === 'error') return <span className="text-[10px] font-bold text-rose-600 bg-rose-50 px-2 py-0.5 rounded">{t('settings.ecommerce.orders.stageError')}</span>;
    return <span className="text-[10px] font-bold text-[#5c5c5a] bg-[#f0eeeb] px-2 py-0.5 rounded">{t('settings.ecommerce.orders.stageStaged')}</span>;
  };

  const lastRun = syncLog[0] || null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" onClick={onClose}>
      <div className="bg-white rounded-2xl w-full max-w-5xl max-h-[88vh] flex flex-col overflow-hidden" onClick={(e) => e.stopPropagation()}>
        {/* Header */}
        <div className="flex items-center justify-between px-6 py-4 border-b border-[#e0ddd5]">
          <div className="min-w-0">
            <h3 className="text-lg font-bold text-[#191918]">{t('settings.ecommerce.orders.title')}</h3>
            <p className="text-xs text-[#6b6b69] mt-0.5 break-all">{connection.label || connection.platformName} · {connection.shopIdentifier}</p>
          </div>
          <button onClick={onClose} className="text-[#8a8a88] hover:text-[#191918] p-1" aria-label={t('common.close')}><i className="fas fa-times text-lg"></i></button>
        </div>

        {/* Notices + toolbar */}
        <div className="px-6 py-3 space-y-3 border-b border-[#e0ddd5]/60">
          <div className="text-xs text-amber-800 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2">
            <i className="fas fa-circle-info mr-1.5"></i>{t('settings.ecommerce.orders.previewNotice')}
          </div>
          <div className="text-[11px] text-[#8a8a88]"><i className="fas fa-tag mr-1"></i>{t('settings.ecommerce.orders.noSkuNote')}</div>
          {message && (
            <div className={`text-sm px-3 py-2 rounded-lg ${message.type === 'success' ? 'bg-emerald-50 text-emerald-700' : 'bg-rose-50 text-rose-700'}`}>
              <i className={`fas ${message.type === 'success' ? 'fa-check-circle' : 'fa-exclamation-circle'} mr-2`}></i>{message.text}
            </div>
          )}
          <div className="flex items-center gap-2 flex-wrap">
            <button onClick={doPull} disabled={pulling || !connection.enabled}
              className="px-4 py-2 bg-primary hover:bg-primary-hover text-white rounded-lg text-sm font-medium disabled:opacity-50">
              {pulling ? <><i className="fas fa-spinner fa-spin mr-1.5"></i>{t('settings.ecommerce.orders.pulling')}</> : <><i className="fas fa-cloud-arrow-down mr-1.5"></i>{t('settings.ecommerce.orders.pullNow')}</>}
            </button>
            <button onClick={doRefresh} disabled={loading || pulling} className="px-4 py-2 border border-[#e0ddd5] text-[#4a4a48] rounded-lg text-sm hover:bg-[#f0eeeb] disabled:opacity-50">
              <i className="fas fa-rotate mr-1.5"></i>{t('settings.ecommerce.orders.refresh')}
            </button>
            {lastRun && (
              <span className="text-[11px] text-[#8a8a88] ml-1">
                {t('settings.ecommerce.orders.lastRunAt', { time: fmtTime(lastRun.runAt) })} ·
                {' '}{t('settings.ecommerce.orders.runSummary', { pulled: lastRun.pulled, new: lastRun.stagedNew, updated: lastRun.stagedUpdated, errors: lastRun.errors })}
                {lastRun.status === 'partial' && <span className="text-amber-700 ml-1">{t('settings.ecommerce.orders.statusPartialHint')}</span>}
                {lastRun.status === 'error' && <span className="text-rose-600 ml-1">{lastRun.error?.code || 'error'}</span>}
              </span>
            )}
          </div>
        </div>

        {/* Body */}
        <div className="flex-1 overflow-y-auto px-6 py-4">
          {loading ? (
            <div className="flex items-center text-sm text-[#5c5c5a] py-8"><i className="fas fa-spinner fa-spin mr-2"></i>{t('common.loading')}</div>
          ) : staged.length === 0 ? (
            <div className="text-sm text-[#5c5c5a] bg-[#f9f9f8] border border-dashed border-[#d1cdc4] rounded-xl px-4 py-8 text-center">{t('settings.ecommerce.orders.noStaged')}</div>
          ) : (
            <div className="space-y-2">
              {/* column header */}
              <div className="hidden md:grid grid-cols-[1.5fr_1fr_1fr_0.8fr_0.6fr_0.9fr] gap-2 px-3 text-[10px] font-bold text-[#8a8a88] uppercase tracking-wide">
                <span>{t('settings.ecommerce.orders.colOrder')}</span>
                <span>{t('settings.ecommerce.orders.colStatus')}</span>
                <span>{t('settings.ecommerce.orders.colDate')}</span>
                <span className="text-right">{t('settings.ecommerce.orders.colTotal')}</span>
                <span className="text-center">{t('settings.ecommerce.orders.colItems')}</span>
                <span className="text-center">{t('settings.ecommerce.orders.colMatch')}</span>
              </div>
              {staged.map((o) => {
                const items = o.normalized?.items || [];
                const m = matchOrderItems(items, products as any);
                const isOpen = expanded.has(o.id);
                return (
                  <div key={o.id} className="border border-[#e0ddd5] rounded-xl bg-white">
                    <button onClick={() => toggle(o.id)} className="w-full text-left px-3 py-2.5 grid grid-cols-1 md:grid-cols-[1.5fr_1fr_1fr_0.8fr_0.6fr_0.9fr] gap-2 items-center hover:bg-[#faf9f7]">
                      <span className="min-w-0">
                        <i className={`fas fa-chevron-${isOpen ? 'down' : 'right'} text-[9px] text-[#8a8a88] mr-1.5`}></i>
                        <span className="text-[10px] text-[#8a8a88] mr-1">{o.platform}</span>
                        <span className="text-sm font-semibold text-[#191918]">{o.orderNumber || o.externalOrderId}</span>
                        {stageBadge(o.stageStatus)}
                        {o.stageStatus === 'committed' && <span className="text-[10px] text-[#8a8a88] ml-1">{t('settings.ecommerce.orders.committedReadonly')}</span>}
                      </span>
                      <span className="text-xs text-[#5c5c5a]">{o.orderStatus || '—'}</span>
                      <span className="text-xs text-[#5c5c5a]">{fmtTime(o.orderUpdatedAt)}</span>
                      <span className="text-xs text-[#191918] text-right font-medium">{money(o.totalGross, o.currency)}</span>
                      <span className="text-xs text-[#5c5c5a] text-center">{t('settings.ecommerce.orders.itemsCount', { n: items.length })}</span>
                      <span className="text-center">{orderMatchBadge(m.orderStatus)}</span>
                    </button>

                    {isOpen && (
                      <div className="px-4 pb-3 pt-1 border-t border-[#e0ddd5]/60 space-y-3">
                        {/* line items */}
                        <div className="overflow-x-auto">
                          <table className="w-full text-xs">
                            <thead>
                              <tr className="text-[#8a8a88] text-left">
                                <th className="py-1 pr-2 font-medium">{t('settings.ecommerce.orders.lineName')}</th>
                                <th className="py-1 pr-2 font-medium">{t('settings.ecommerce.orders.skuLabel')}</th>
                                <th className="py-1 pr-2 font-medium text-center">{t('settings.ecommerce.orders.lineQty')}</th>
                                <th className="py-1 pr-2 font-medium text-right">{t('settings.ecommerce.orders.lineAmount')}</th>
                                <th className="py-1 font-medium text-center">{t('settings.ecommerce.orders.colMatch')}</th>
                              </tr>
                            </thead>
                            <tbody>
                              {items.map((it, idx) => (
                                <tr key={idx} className="border-t border-[#f0eeeb]">
                                  <td className="py-1 pr-2 text-[#191918]">{it.name || '—'}</td>
                                  <td className="py-1 pr-2 text-[#8a8a88] font-mono">{it.sku || '—'}</td>
                                  <td className="py-1 pr-2 text-center">{it.quantity ?? '—'}</td>
                                  <td className="py-1 pr-2 text-right">{money(it.lineGross ?? null, o.currency)}</td>
                                  <td className="py-1 text-center">{itemMatchBadge(m.items[idx]?.status || 'unmatched')}</td>
                                </tr>
                              ))}
                            </tbody>
                          </table>
                        </div>
                        {/* shipping / taxes / fees / refunds — INFO ONLY (never posted) */}
                        <div className="grid grid-cols-2 sm:grid-cols-4 gap-2 text-[11px]">
                          <div className="bg-[#f9f9f8] rounded-lg px-2 py-1.5"><div className="text-[#8a8a88]">{t('settings.ecommerce.orders.shippingInfo')}</div><div className="text-[#191918]">{money(o.normalized?.shipping?.total ?? null, o.currency)}</div></div>
                          <div className="bg-[#f9f9f8] rounded-lg px-2 py-1.5"><div className="text-[#8a8a88]">{t('settings.ecommerce.orders.taxesInfo')}</div><div className="text-[#191918]">{money(o.normalized?.taxes?.total ?? null, o.currency)}</div></div>
                          <div className="bg-[#f9f9f8] rounded-lg px-2 py-1.5"><div className="text-[#8a8a88]">{t('settings.ecommerce.orders.feesInfo')}</div><div className="text-[#191918]">{money((o.normalized?.fees || []).reduce((s, f) => s + (f.amount || 0), 0) || null, o.currency)}</div></div>
                          <div className="bg-[#f9f9f8] rounded-lg px-2 py-1.5"><div className="text-[#8a8a88]">{t('settings.ecommerce.orders.refundsInfo')}</div><div className="text-[#191918]">{money((o.normalized?.refunds || []).reduce((s, r) => s + (r.amount || 0), 0) || null, o.currency)}</div></div>
                        </div>
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
          )}
        </div>

        {/* Footer — ONLY close (no import/submit/post) */}
        <div className="px-6 py-3 border-t border-[#e0ddd5] flex justify-end">
          <button onClick={onClose} className="px-5 py-2 border border-[#e0ddd5] text-[#4a4a48] rounded-lg text-sm hover:bg-[#f0eeeb]">{t('common.close')}</button>
        </div>
      </div>
    </div>
  );
};

export default EcommerceOrdersModal;
