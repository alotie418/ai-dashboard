// 暂存订单模态（PR-EC4 预览 + PR-EC5b 提交入账）
// EC4：拉单 → 暂存展示 → 只读商品匹配（名称精确）。
// EC5b：勾选 staged 单 → 确认弹窗（明确「写入销售记录」）→ ecommerce:commit（EC5a 后端
// 两遍式全或无）→ 结果 / 拒因展示。
// 边界：前端只做「结构性」禁用（非 staged / 同名歧义 / 无商品明细）；币种、订单状态、
// 退款等校验不在前端复刻——后端拒因码是唯一真相，此处仅做 i18n 映射展示。
// 运费/平台费用/退款绝不入账；提交前的合计一律标注「估算」，实际以提交结果为准。
// 提交不依赖 connection.enabled（后端有意允许对已暂存的本地数据离线提交）。
import React, { useEffect, useMemo, useState } from 'react';
import { useTranslation } from 'react-i18next';
import {
  listProducts,
  pullEcommerce,
  listStagedOrders,
  listEcommerceSyncLog,
  commitStagedOrders,
  type Product,
  type StagedOrder,
  type EcommerceSyncLogEntry,
  type EcommerceConnection,
  type EcommerceCommitResult,
} from '../../services/api';
import { matchOrderItems, type OrderMatchStatus, type ItemMatchStatus } from './matchStagedItems';

// 与后端 electron/ecommerce/commit.js 的 MAX_COMMIT 对齐（单次提交上限）
const MAX_COMMIT = 100;

// 后端 19 个稳定拒因码（commit.js validateOne + write_failed）；未知码回退通用失败文案，
// 严防 raw key 直出
const REASON_CODES = new Set([
  'not_found', 'already_committed', 'not_staged', 'bad_normalized', 'duplicate_external_order',
  'status_not_committable', 'has_refunds', 'store_currency_missing', 'currency_missing',
  'currency_mismatch', 'date_missing', 'empty_items', 'quantity_invalid', 'amount_missing',
  'amount_inconsistent', 'totals_missing', 'total_mismatch', 'ambiguous_product', 'write_failed',
]);

type CommitPhase = 'confirm' | 'committing' | 'result' | null;

const EcommerceOrdersModal: React.FC<{ connection: EcommerceConnection; onClose: () => void }> = ({ connection, onClose }) => {
  const { t } = useTranslation();
  const [products, setProducts] = useState<Product[]>([]);
  const [staged, setStaged] = useState<StagedOrder[]>([]);
  const [syncLog, setSyncLog] = useState<EcommerceSyncLogEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [pulling, setPulling] = useState(false);
  const [expanded, setExpanded] = useState<Set<number>>(new Set());
  const [message, setMessage] = useState<{ type: 'success' | 'error'; text: string } | null>(null);
  const [selected, setSelected] = useState<Set<number>>(new Set());
  const [commitPhase, setCommitPhase] = useState<CommitPhase>(null);
  const [commitResult, setCommitResult] = useState<EcommerceCommitResult | null>(null);

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

  // ===== EC5b 勾选 / 提交 =====
  // 匹配结果与 staged 同序（index 对齐）；仅用于展示 + 结构性禁用，不做业务预校验
  const matches = useMemo(
    () => staged.map((o) => matchOrderItems(o.normalized?.items || [], products as any)),
    [staged, products],
  );

  const canSelect = (o: StagedOrder, m: { orderStatus: OrderMatchStatus }) =>
    o.stageStatus === 'staged' && m.orderStatus !== 'ambiguous' && m.orderStatus !== 'empty';

  const selectableIds = useMemo(
    () => staged.filter((o, i) => canSelect(o, matches[i])).map((o) => o.id),
    [staged, matches],
  );

  // 列表变化（拉单/刷新/提交后 reload）时自动剔除已不可勾选的 id
  useEffect(() => {
    setSelected((prev) => {
      const allowed = new Set(selectableIds);
      const next = new Set([...prev].filter((id) => allowed.has(id)));
      return next.size === prev.size ? prev : next;
    });
  }, [selectableIds]);

  const toggleSelect = (id: number) => setSelected((prev) => { const n = new Set(prev); n.has(id) ? n.delete(id) : n.add(id); return n; });
  const allSelected = selectableIds.length > 0 && selectableIds.every((id) => selected.has(id));
  const toggleSelectAll = () => setSelected(allSelected ? new Set() : new Set(selectableIds));

  const selectedRows = useMemo(() => staged.filter((o) => selected.has(o.id)), [staged, selected]);

  // 估算合计 = Σ 选中订单的商品行 lineGross（按币种分组，避免跨币种相加）；仅供确认参考
  const estimatedTotal = useMemo(() => {
    const sums: Record<string, number> = {};
    for (const o of selectedRows) {
      const cur = o.currency || '—';
      const s = (o.normalized?.items || []).reduce((acc, it) => acc + (it.lineGross ?? 0), 0);
      sums[cur] = (sums[cur] || 0) + s;
    }
    const parts = Object.entries(sums).map(([c, v]) => `${c === '—' ? '' : c + ' '}${v.toFixed(2)}`);
    return parts.length ? parts.join(' + ') : '0.00';
  }, [selectedRows]);

  const reasonText = (code: string) => REASON_CODES.has(code)
    ? t('settings.ecommerce.orders.reasons.' + code)
    : t('settings.ecommerce.orders.commitFailedTitle');

  const committing = commitPhase === 'committing';

  const doCommit = async () => {
    setCommitPhase('committing');
    try {
      const r = await commitStagedOrders(connection.id, [...selected]);
      setCommitResult(r);
      if (r.ok && (r.errors?.length ?? 0) === 0) {
        // 全部成功：清空勾选并刷新（行变已入账只读）
        setSelected(new Set());
        await reload();
      } else if (r.ok && r.errors && r.errors.length > 0) {
        // 全或无被拒：自动取消勾选被拒单，保留其余勾选便于直接重试
        const rejected = new Set(r.errors.map((e) => e.stagedId).filter((v): v is number => v != null));
        setSelected((prev) => new Set([...prev].filter((id) => !rejected.has(id))));
      }
      setCommitPhase('result');
    } catch (e: any) {
      setCommitResult({ ok: false, message: e?.message || '' });
      setCommitPhase('result');
    }
  };

  const closeCommitOverlay = () => { setCommitPhase(null); setCommitResult(null); };

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
  const storeCur = connection.storeCurrency || null;
  const commitOk = !!(commitResult && commitResult.ok && (commitResult.errors?.length ?? 0) === 0);

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
            {/* 提交入账（不 gate 在 connection.enabled 上——提交本地暂存数据无需网络） */}
            <button onClick={() => setCommitPhase('confirm')}
              disabled={selected.size === 0 || selected.size > MAX_COMMIT || pulling || loading}
              className="px-4 py-2 bg-primary hover:bg-primary-hover text-white rounded-lg text-sm font-medium disabled:opacity-50">
              <i className="fas fa-file-invoice-dollar mr-1.5"></i>{t('settings.ecommerce.orders.commitSelected', { n: selected.size })}
            </button>
            {selected.size > 0 && (
              <span className="text-[11px] text-[#5c5c5a]">
                {t('settings.ecommerce.orders.selectedCount', { n: selected.size })} · {t('settings.ecommerce.orders.estimatedTotal', { amount: estimatedTotal })}
              </span>
            )}
            {selected.size > MAX_COMMIT && (
              <span className="text-[11px] text-rose-600">{t('settings.ecommerce.orders.maxSelection', { max: MAX_COMMIT })}</span>
            )}
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
              {/* column header（左侧留出勾选列宽度） */}
              <div className="hidden md:flex items-center">
                <span className="w-8 flex justify-center">
                  <input type="checkbox" checked={allSelected} onChange={toggleSelectAll} disabled={selectableIds.length === 0}
                    aria-label={t('settings.ecommerce.orders.selectAll')} title={t('settings.ecommerce.orders.selectAll')} />
                </span>
                <div className="flex-1 grid grid-cols-[1.5fr_1fr_1fr_0.8fr_0.6fr_0.9fr] gap-2 px-3 text-[10px] font-bold text-[#8a8a88] tracking-wide">
                  <span>{t('settings.ecommerce.orders.colOrder')}</span>
                  <span>{t('settings.ecommerce.orders.colStatus')}</span>
                  <span>{t('settings.ecommerce.orders.colDate')}</span>
                  <span className="text-right">{t('settings.ecommerce.orders.colTotal')}</span>
                  <span className="text-center">{t('settings.ecommerce.orders.colItems')}</span>
                  <span className="text-center">{t('settings.ecommerce.orders.colMatch')}</span>
                </div>
              </div>
              {staged.map((o, idx) => {
                const items = o.normalized?.items || [];
                const m = matches[idx];
                const isOpen = expanded.has(o.id);
                const selectable = canSelect(o, m);
                const disabledHint = !selectable
                  ? (o.stageStatus !== 'staged'
                    ? t('settings.ecommerce.orders.notSelectableCommitted')
                    : t('settings.ecommerce.orders.notSelectableAmbiguous'))
                  : undefined;
                return (
                  <div key={o.id} className={`border rounded-xl bg-white ${selected.has(o.id) ? 'border-primary/50' : 'border-[#e0ddd5]'}`}>
                    <div className="flex items-stretch">
                      <span className="w-8 flex items-center justify-center" title={disabledHint}>
                        <input type="checkbox" checked={selected.has(o.id)} disabled={!selectable}
                          onChange={() => toggleSelect(o.id)} className="disabled:opacity-40"
                          aria-label={o.orderNumber || o.externalOrderId} />
                      </span>
                      <button onClick={() => toggle(o.id)} className="flex-1 min-w-0 text-left px-3 py-2.5 grid grid-cols-1 md:grid-cols-[1.5fr_1fr_1fr_0.8fr_0.6fr_0.9fr] gap-2 items-center hover:bg-[#faf9f7] rounded-r-xl">
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
                    </div>

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
                              {items.map((it, i) => (
                                <tr key={i} className="border-t border-[#f0eeeb]">
                                  <td className="py-1 pr-2 text-[#191918]">{it.name || '—'}</td>
                                  <td className="py-1 pr-2 text-[#8a8a88] font-mono">{it.sku || '—'}</td>
                                  <td className="py-1 pr-2 text-center">{it.quantity ?? '—'}</td>
                                  <td className="py-1 pr-2 text-right">{money(it.lineGross ?? null, o.currency)}</td>
                                  <td className="py-1 text-center">{itemMatchBadge(m.items[i]?.status || 'unmatched')}</td>
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

        {/* Footer */}
        <div className="px-6 py-3 border-t border-[#e0ddd5] flex justify-end">
          <button onClick={onClose} className="px-5 py-2 border border-[#e0ddd5] text-[#4a4a48] rounded-lg text-sm hover:bg-[#f0eeeb]">{t('common.close')}</button>
        </div>

        {/* ===== EC5b 确认 / 结果覆盖层（点击遮罩不关闭，只能走按钮） ===== */}
        {commitPhase && (
          <div className="fixed inset-0 z-[60] flex items-center justify-center bg-black/40 p-4" onClick={(e) => e.stopPropagation()}>
            <div className="bg-white rounded-2xl w-full max-w-lg max-h-[80vh] flex flex-col overflow-hidden">
              {commitPhase !== 'result' ? (
                <>
                  {/* 确认弹窗：明确「将写入销售记录」，估算金额标注估算 */}
                  <div className="px-6 py-4 border-b border-[#e0ddd5]">
                    <h4 className="text-base font-bold text-[#191918]">{t('settings.ecommerce.orders.confirmTitle')}</h4>
                  </div>
                  <div className="flex-1 overflow-y-auto px-6 py-4 space-y-3 text-sm text-[#191918]">
                    <p>{t('settings.ecommerce.orders.confirmCount', { n: selected.size })}</p>
                    {selectedRows.length <= 10 && selectedRows.length > 0 && (
                      <div className="border border-[#e0ddd5] rounded-lg divide-y divide-[#f0eeeb]">
                        {selectedRows.map((o) => (
                          <div key={o.id} className="flex items-center justify-between px-3 py-1.5 text-xs">
                            <span className="text-[#191918] font-medium truncate mr-2">{o.orderNumber || o.externalOrderId}</span>
                            <span className="text-[#5c5c5a] shrink-0">{money(o.totalGross, o.currency)}</span>
                          </div>
                        ))}
                      </div>
                    )}
                    <p className="font-medium">{t('settings.ecommerce.orders.confirmEstimate', { amount: estimatedTotal })}</p>
                    <ul className="text-xs text-amber-800 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2 space-y-1 list-disc list-inside">
                      <li>{t('settings.ecommerce.orders.confirmNotPostedNote')}</li>
                      <li>{t('settings.ecommerce.orders.confirmCurrencyNote')}</li>
                      <li>{t('settings.ecommerce.orders.confirmIrreversibleNote')}</li>
                    </ul>
                  </div>
                  <div className="px-6 py-3 border-t border-[#e0ddd5] flex justify-end gap-2">
                    <button onClick={closeCommitOverlay} disabled={committing}
                      className="px-4 py-2 border border-[#e0ddd5] text-[#4a4a48] rounded-lg text-sm hover:bg-[#f0eeeb] disabled:opacity-50">
                      {t('settings.ecommerce.orders.confirmCancel')}
                    </button>
                    <button onClick={doCommit} disabled={committing}
                      className="px-4 py-2 bg-primary hover:bg-primary-hover text-white rounded-lg text-sm font-medium disabled:opacity-50">
                      {committing
                        ? <><i className="fas fa-spinner fa-spin mr-1.5"></i>{t('settings.ecommerce.orders.committing')}</>
                        : <><i className="fas fa-file-invoice-dollar mr-1.5"></i>{t('settings.ecommerce.orders.confirmProceed')}</>}
                    </button>
                  </div>
                </>
              ) : (
                <>
                  {/* 结果面板：成功=绿色摘要+逐单回执；被拒=全或无说明+逐单本地化拒因；异常=code/message */}
                  {!commitOk && (
                    <div className="px-6 py-4 border-b border-[#e0ddd5]">
                      <h4 className="text-base font-bold text-[#191918]">{t('settings.ecommerce.orders.commitFailedTitle')}</h4>
                    </div>
                  )}
                  <div className="flex-1 overflow-y-auto px-6 py-4 space-y-3 text-sm">
                    {commitOk ? (
                      <>
                        <div className="text-sm px-3 py-2 rounded-lg bg-emerald-50 text-emerald-700">
                          <i className="fas fa-check-circle mr-2"></i>{t('settings.ecommerce.orders.commitSuccess', { n: commitResult?.success ?? 0 })}
                        </div>
                        {(commitResult?.committed || []).map((c) => (
                          <div key={c.stagedId} className="border border-[#e0ddd5] rounded-lg px-3 py-2 text-xs space-y-1">
                            <div className="font-semibold text-[#191918]">{c.orderNumber || c.externalOrderId}</div>
                            <div className="flex flex-wrap gap-x-4 gap-y-0.5 text-[#5c5c5a]">
                              <span>{t('settings.ecommerce.orders.resultPlatformTotal')} {money(c.grandTotalGross, storeCur)}</span>
                              <span>{t('settings.ecommerce.orders.resultCommitted')} <span className="text-[#191918] font-medium">{money(c.committedTotalAmount, storeCur)}</span></span>
                            </div>
                            {c.difference !== 0 && (
                              <div className="text-[#8a8a88]">
                                {t('settings.ecommerce.orders.resultDiffShipping')} {money(c.breakdown?.shippingNotPosted ?? null, storeCur)}
                                {' · '}{t('settings.ecommerce.orders.resultDiffOther')} {money(c.breakdown?.otherDifference ?? null, storeCur)}
                              </div>
                            )}
                            <div className="text-[#8a8a88]">{t('settings.ecommerce.orders.resultLines', { matched: c.lines?.matched ?? 0, descriptionOnly: c.lines?.descriptionOnly ?? 0 })}</div>
                          </div>
                        ))}
                      </>
                    ) : commitResult?.ok ? (
                      <>
                        <div className="text-sm px-3 py-2 rounded-lg bg-rose-50 text-rose-700 font-medium">
                          <i className="fas fa-exclamation-circle mr-2"></i>{t('settings.ecommerce.orders.commitAllOrNothing')}
                        </div>
                        {(commitResult?.errors || []).map((e, i) => (
                          <div key={i} className="border border-rose-200 rounded-lg px-3 py-2 text-xs space-y-1">
                            <div className="font-semibold text-[#191918]">{e.orderNumber || (e.stagedId != null ? `#${e.stagedId}` : '—')}</div>
                            <div className="flex flex-wrap gap-1">
                              {(e.reasons || []).map((code) => (
                                <span key={code} title={code} className="text-[10px] bg-rose-50 text-rose-700 px-1.5 py-0.5 rounded">{reasonText(code)}</span>
                              ))}
                            </div>
                            {e.detail && e.detail.length > 0 && <div className="text-[#8a8a88]">{e.detail.join(' · ')}</div>}
                            {e.message && <div className="text-[10px] text-[#8a8a88] font-mono break-all">{e.message}</div>}
                          </div>
                        ))}
                      </>
                    ) : (
                      <div className="text-sm px-3 py-2 rounded-lg bg-rose-50 text-rose-700">
                        <i className="fas fa-exclamation-circle mr-2"></i>
                        <span className="font-medium">{t('settings.ecommerce.orders.commitFailedTitle')}</span>
                        {(commitResult?.code || commitResult?.message) && (
                          <span className="ml-2 text-[10px] font-mono break-all">{[commitResult?.code, commitResult?.message].filter(Boolean).join(' · ')}</span>
                        )}
                      </div>
                    )}
                  </div>
                  <div className="px-6 py-3 border-t border-[#e0ddd5] flex justify-end">
                    <button onClick={closeCommitOverlay} className="px-5 py-2 border border-[#e0ddd5] text-[#4a4a48] rounded-lg text-sm hover:bg-[#f0eeeb]">{t('common.close')}</button>
                  </div>
                </>
              )}
            </div>
          </div>
        )}
      </div>
    </div>
  );
};

export default EcommerceOrdersModal;
