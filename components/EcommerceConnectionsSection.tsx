// 电商平台接入 — 设置页区域（平台目录 · MVP：仅连接设置）
// 平台目录（11 平台·三档·状态徽标）；一档(Shopify/WooCommerce)可添加连接、测试、启停、删除；
// 二/三档仅展示状态、不给凭证输入。凭证在主进程 safeStorage 加密；渲染端只拿状态标志。
// 本区域不拉单、不写账本——仅保存连接并测试可达性；绝不收集平台账号密码。
import React, { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import {
  isDesktop,
  listEcommerceProviders,
  listEcommerceConnections,
  saveEcommerceConnection,
  setEcommerceConnectionEnabled,
  removeEcommerceConnection,
  testEcommerceConnection,
  type EcommerceProviderMeta,
  type EcommerceConnection,
} from '../services/api';
import EcommerceOrdersModal from './ecommerce/EcommerceOrdersModal';

interface FormState {
  open: boolean;
  mode: 'new' | 'edit';
  id?: string;
  platform: string;
  label: string;
  shop: string;
  creds: Record<string, string>;   // token | consumerKey/consumerSecret
  testing: boolean;
  testResult: 'ok' | 'fail' | null;
  testMsg: string;
  saving: boolean;
}

const EMPTY_FORM: FormState = {
  open: false, mode: 'new', platform: '', label: '', shop: '', creds: {},
  testing: false, testResult: null, testMsg: '', saving: false,
};

// Which credential field keys each auth mode collects (drives required/test/save).
const CRED_KEYS: Record<string, string[]> = {
  manual_token: ['token'],
  key_secret: ['consumerKey', 'consumerSecret'],
};

const EcommerceConnectionsSection: React.FC = () => {
  const { t } = useTranslation();
  const desktop = isDesktop();
  const [providers, setProviders] = useState<EcommerceProviderMeta[]>([]);
  const [connections, setConnections] = useState<EcommerceConnection[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [form, setForm] = useState<FormState>(EMPTY_FORM);
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null);
  const [rowTest, setRowTest] = useState<Record<string, { testing: boolean; result: 'ok' | 'fail' | null; msg: string }>>({});
  const [globalMessage, setGlobalMessage] = useState<{ type: 'success' | 'error'; text: string } | null>(null);
  const [ordersFor, setOrdersFor] = useState<EcommerceConnection | null>(null);

  const activeProvider = providers.find((p) => p.id === form.platform) || null;
  const activeCredKeys = activeProvider ? (CRED_KEYS[activeProvider.authMode] || []) : [];

  const flash = (type: 'success' | 'error', text: string) => {
    setGlobalMessage({ type, text });
    setTimeout(() => setGlobalMessage(null), 2800);
  };

  const reload = async () => {
    try {
      const [prov, conns] = await Promise.all([listEcommerceProviders(), listEcommerceConnections()]);
      setProviders(prov);
      setConnections(conns);
    } catch (e: any) {
      setLoadError(t('settings.ecommerce.loadError', { msg: e?.message || t('common.error') }));
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    if (!desktop) { setLoading(false); return; }
    reload();
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const patchForm = (patch: Partial<FormState>) => setForm((prev) => ({ ...prev, ...patch }));
  const patchCred = (key: string, val: string) =>
    setForm((prev) => ({ ...prev, creds: { ...prev.creds, [key]: val }, testResult: null }));

  const openAdd = (platform: string) => setForm({ ...EMPTY_FORM, open: true, mode: 'new', platform, creds: {} });
  const openEdit = (c: EcommerceConnection) => setForm({
    ...EMPTY_FORM, open: true, mode: 'edit', id: c.id, platform: c.platform,
    label: c.label || '', shop: c.shopIdentifier || '', creds: {},
  });
  const closeForm = () => setForm(EMPTY_FORM);

  const describeTestFail = (r: { code?: string | null; providerMessage?: string | null; status?: number | null }) => {
    const parts: string[] = [];
    if (r.status) parts.push(`HTTP ${r.status}`);
    if (r.code) parts.push(r.code);
    if (r.providerMessage) parts.push(r.providerMessage);
    return parts.join(' · ') || t('settings.ecommerce.testFail');
  };

  const nonEmptyCreds = (): Record<string, string> => {
    const out: Record<string, string> = {};
    for (const k of activeCredKeys) { const v = (form.creds[k] || '').trim(); if (v) out[k] = v; }
    return out;
  };
  const anyCredEntered = () => activeCredKeys.some((k) => (form.creds[k] || '').trim());
  const allCredsFilled = () => activeCredKeys.length > 0 && activeCredKeys.every((k) => (form.creds[k] || '').trim());
  const canSave = !!form.shop.trim() && (form.mode === 'edit' || allCredsFilled());

  const doFormTest = async () => {
    patchForm({ testing: true, testResult: null, testMsg: '' });
    try {
      // 编辑态且未重输凭证 → 传 id，后端用已存凭证测试；否则用表单内联凭证。
      const useStored = form.mode === 'edit' && !anyCredEntered();
      const result = await testEcommerceConnection(
        useStored
          ? { id: form.id, platform: form.platform, shopIdentifier: form.shop.trim() }
          : { platform: form.platform, shopIdentifier: form.shop.trim(), credentials: nonEmptyCreds() },
      );
      if (result.ok) patchForm({ testing: false, testResult: 'ok', testMsg: result.storeInfo?.name || '' });
      else patchForm({ testing: false, testResult: 'fail', testMsg: describeTestFail(result) });
    } catch (e: any) {
      patchForm({ testing: false, testResult: 'fail', testMsg: e?.message || t('settings.ecommerce.testFail') });
    }
  };

  const doFormSave = async () => {
    if (!canSave) return;
    patchForm({ saving: true });
    try {
      const creds = nonEmptyCreds();
      await saveEcommerceConnection({
        id: form.mode === 'edit' ? form.id : undefined,
        platform: form.platform,
        label: form.label.trim(),
        shopIdentifier: form.shop.trim(),
        credentials: Object.keys(creds).length ? creds : undefined,
      });
      flash('success', t('settings.ecommerce.savedToast'));
      closeForm();
      await reload();
    } catch (e: any) {
      patchForm({ saving: false });
      flash('error', t('settings.ecommerce.saveError', { msg: e?.message || t('common.error') }));
    }
  };

  const doRowTest = async (c: EcommerceConnection) => {
    setRowTest((prev) => ({ ...prev, [c.id]: { testing: true, result: null, msg: '' } }));
    try {
      const result = await testEcommerceConnection({ id: c.id, platform: c.platform });
      setRowTest((prev) => ({
        ...prev,
        [c.id]: result.ok
          ? { testing: false, result: 'ok', msg: result.storeInfo?.name || '' }
          : { testing: false, result: 'fail', msg: describeTestFail(result) },
      }));
      await reload();
    } catch (e: any) {
      setRowTest((prev) => ({ ...prev, [c.id]: { testing: false, result: 'fail', msg: e?.message || t('settings.ecommerce.testFail') } }));
    }
  };

  const doToggleEnabled = async (c: EcommerceConnection) => {
    try { await setEcommerceConnectionEnabled(c.id, !c.enabled); await reload(); }
    catch (e: any) { flash('error', e?.message || t('common.error')); }
  };

  const doDelete = async (id: string) => {
    try {
      await removeEcommerceConnection(id);
      flash('success', t('settings.ecommerce.removedToast'));
      await reload();
    } catch (e: any) {
      flash('error', t('settings.ecommerce.deleteError', { msg: e?.message || t('common.error') }));
    } finally { setConfirmDelete(null); }
  };

  const fmtTime = (iso: string | null) => {
    if (!iso) return '';
    try { return new Date(iso.includes('T') ? iso : iso.replace(' ', 'T') + 'Z').toLocaleString(); }
    catch { return iso; }
  };

  const statusBadge = (status: string) => {
    if (status === 'available') return <span className="text-[10px] font-bold text-emerald-600 bg-emerald-50 px-2 py-0.5 rounded uppercase">{t('settings.ecommerce.statusAvailable')}</span>;
    if (status === 'needs_authorization') return <span className="text-[10px] font-bold text-amber-700 bg-amber-50 px-2 py-0.5 rounded uppercase">{t('settings.ecommerce.statusNeedsAuth')}</span>;
    return <span className="text-[10px] font-bold text-[#5c5c5a] bg-[#f0eeeb] px-2 py-0.5 rounded uppercase">{t('settings.ecommerce.statusPlanned')}</span>;
  };
  const tierLabel = (tier: number) => tier === 1 ? t('settings.ecommerce.tier1Label') : tier === 2 ? t('settings.ecommerce.tier2Label') : t('settings.ecommerce.tier3Label');

  return (
    <section className="space-y-6">
      <div>
        <h3 className="text-xl font-bold text-[#191918]">{t('settings.ecommerce.title')}</h3>
        <p className="text-xs text-[#6b6b69] mt-1">{t('settings.ecommerce.subtitle')}</p>
      </div>

      <div className="text-xs text-amber-800 bg-amber-50 border border-amber-200 rounded-xl px-4 py-3">
        <i className="fas fa-circle-info mr-1.5"></i>{t('settings.ecommerce.mvpNotice')}
      </div>

      {!desktop && (
        <div className="text-sm text-[#5c5c5a] bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl px-4 py-4">
          <i className="fas fa-desktop mr-2"></i>{t('settings.ecommerce.desktopOnly')}
        </div>
      )}

      {globalMessage && (
        <div className={`px-4 py-2.5 rounded-lg text-sm ${globalMessage.type === 'success' ? 'bg-emerald-50 text-emerald-700' : 'bg-rose-50 text-rose-700'}`}>
          <i className={`fas ${globalMessage.type === 'success' ? 'fa-check-circle' : 'fa-exclamation-circle'} mr-2`}></i>
          {globalMessage.text}
        </div>
      )}

      {desktop && loadError && (
        <div className="text-sm text-rose-600 bg-rose-50 border border-rose-200 rounded-xl px-4 py-3">{loadError}</div>
      )}
      {desktop && loading && (
        <div className="flex items-center text-sm text-[#5c5c5a] py-6"><i className="fas fa-spinner fa-spin mr-2"></i>{t('common.loading')}</div>
      )}

      {desktop && !loading && (
        <>
          {/* 已保存连接 */}
          {connections.length > 0 && (
            <div className="space-y-3">
              {connections.map((c) => {
                const rt = rowTest[c.id];
                return (
                  <div key={c.id} className="border border-[#e0ddd5] bg-white rounded-xl p-5">
                    <div className="flex items-start justify-between gap-3 flex-wrap">
                      <div className="flex items-center min-w-0 flex-1">
                        <div className="w-10 h-10 rounded-lg flex items-center justify-center mr-3 bg-[#eef2fb] text-primary"><i className="fas fa-store"></i></div>
                        <div className="min-w-0">
                          <div className="flex items-center gap-2 flex-wrap">
                            <h4 className="text-sm font-semibold text-[#191918]">{c.label || c.platformName}</h4>
                            <span className="text-[10px] font-bold text-[#5c5c5a] bg-[#f0eeeb] px-2 py-0.5 rounded">{c.platformName}</span>
                            {c.enabled
                              ? <span className="text-[10px] font-bold text-emerald-600 bg-emerald-50 px-2 py-0.5 rounded uppercase">{t('settings.ecommerce.statusEnabled')}</span>
                              : <span className="text-[10px] font-bold text-[#5c5c5a] bg-[#f0eeeb] px-2 py-0.5 rounded uppercase">{t('settings.ecommerce.statusDisabled')}</span>}
                          </div>
                          <div className="text-[11px] text-[#5c5c5a] mt-0.5 break-all"><i className="fas fa-link mr-1 text-[9px]"></i>{c.shopIdentifier || '—'}</div>
                          <div className="text-[11px] text-[#8a8a88] mt-0.5">
                            {c.lastTestAt
                              ? <>{t('settings.ecommerce.lastTest', { time: fmtTime(c.lastTestAt) })}
                                  <span className={c.lastTestOk ? 'text-emerald-600 ml-1' : 'text-rose-600 ml-1'}>
                                    {c.lastTestOk ? t('settings.ecommerce.lastTestOk') : t('settings.ecommerce.lastTestFail')}
                                  </span></>
                              : t('settings.ecommerce.neverTested')}
                          </div>
                          {rt?.result === 'ok' && <div className="text-[11px] text-emerald-600 mt-1"><i className="fas fa-check-circle mr-1"></i>{t('settings.ecommerce.testOk', { name: rt.msg })}</div>}
                          {rt?.result === 'fail' && <div className="text-[11px] text-rose-600 mt-1 break-all"><i className="fas fa-exclamation-circle mr-1"></i>{rt.msg}</div>}
                        </div>
                      </div>
                      <div className="flex items-center gap-2 flex-wrap shrink-0">
                        {c.enabled && (
                          <button onClick={() => setOrdersFor(c)} className="text-xs px-3 py-1.5 border border-primary/40 text-primary rounded-lg hover:bg-primary/5 whitespace-nowrap">
                            <i className="fas fa-cloud-arrow-down mr-1.5"></i>{t('settings.ecommerce.orders.viewOrders')}
                          </button>
                        )}
                        <button onClick={() => doRowTest(c)} disabled={rt?.testing} className="text-xs px-3 py-1.5 border border-[#e0ddd5] text-[#4a4a48] rounded-lg hover:bg-[#f0eeeb] disabled:opacity-50 whitespace-nowrap">
                          {rt?.testing ? <><i className="fas fa-spinner fa-spin mr-1.5"></i>{t('common.testing')}</> : <><i className="fas fa-plug mr-1.5"></i>{t('settings.ecommerce.testConnection')}</>}
                        </button>
                        <button onClick={() => doToggleEnabled(c)} className="text-xs px-3 py-1.5 border border-[#e0ddd5] text-[#4a4a48] rounded-lg hover:bg-[#f0eeeb] whitespace-nowrap">
                          {c.enabled ? t('settings.ecommerce.disable') : t('settings.ecommerce.enable')}
                        </button>
                        <button onClick={() => openEdit(c)} className="text-xs px-3 py-1.5 border border-[#e0ddd5] text-[#4a4a48] rounded-lg hover:bg-[#f0eeeb] whitespace-nowrap"><i className="fas fa-edit mr-1.5"></i>{t('common.edit')}</button>
                        {confirmDelete === c.id ? (
                          <div className="flex items-center space-x-1.5 bg-rose-50 px-2 py-1 rounded-lg whitespace-nowrap">
                            <span className="text-xs text-rose-600">{t('settings.ecommerce.removeConfirm')}</span>
                            <button onClick={() => doDelete(c.id)} className="text-xs px-2 py-0.5 bg-rose-600 text-white rounded">{t('common.delete')}</button>
                            <button onClick={() => setConfirmDelete(null)} className="text-xs px-2 py-0.5 border border-rose-300 text-rose-600 rounded">{t('common.cancel')}</button>
                          </div>
                        ) : (
                          <button onClick={() => setConfirmDelete(c.id)} className="text-xs px-3 py-1.5 border border-rose-200 text-rose-600 rounded-lg hover:bg-rose-50 whitespace-nowrap"><i className="fas fa-trash mr-1.5"></i>{t('common.delete')}</button>
                        )}
                      </div>
                    </div>
                  </div>
                );
              })}
            </div>
          )}

          {/* 添加 / 编辑表单（仅可连接平台） */}
          {form.open && activeProvider?.connectable && (
            <div className="border border-primary/40 bg-primary/5 rounded-xl p-5 space-y-4">
              <h4 className="text-sm font-bold text-[#191918]">
                {form.mode === 'edit' ? t('common.edit') : t('settings.ecommerce.connect')} · {activeProvider.name}
              </h4>

              <div>
                <label className="block text-xs font-medium text-[#4a4a48] mb-1.5">{t('settings.ecommerce.labelLabel')}</label>
                <input type="text" value={form.label} onChange={(e) => patchForm({ label: e.target.value })} placeholder={t('settings.ecommerce.labelPlaceholder')}
                  className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm focus:outline-none focus:border-primary focus:ring-2 focus:ring-primary/20" />
              </div>

              {/* 店铺标识 */}
              <div>
                <label className="block text-xs font-medium text-[#4a4a48] mb-1.5">
                  {activeProvider.authMode === 'key_secret' ? t('settings.ecommerce.storeUrlLabel') : t('settings.ecommerce.shopDomainLabel')}
                </label>
                <input type="text" value={form.shop} onChange={(e) => patchForm({ shop: e.target.value, testResult: null })}
                  placeholder={activeProvider.authMode === 'key_secret' ? t('settings.ecommerce.storeUrlPlaceholder') : t('settings.ecommerce.shopDomainPlaceholder')}
                  className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm font-mono focus:outline-none focus:border-primary focus:ring-2 focus:ring-primary/20" />
                <p className="text-[10px] text-[#5c5c5a] mt-1">
                  {activeProvider.authMode === 'key_secret' ? t('settings.ecommerce.storeUrlDesc') : t('settings.ecommerce.shopDomainDesc')}
                </p>
              </div>

              {/* 凭证：manual_token 或 key_secret */}
              {activeProvider.authMode === 'manual_token' && (
                <div>
                  <label className="block text-xs font-medium text-[#4a4a48] mb-1.5">
                    {t('settings.ecommerce.tokenLabel')}
                    {form.mode === 'edit' && <span className="text-[#5c5c5a] font-normal ml-1">{t('settings.ecommerce.credsOverrideHint')}</span>}
                  </label>
                  <input type="password" value={form.creds.token || ''} onChange={(e) => patchCred('token', e.target.value)} placeholder={t('settings.ecommerce.tokenPlaceholder')}
                    className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm font-mono focus:outline-none focus:border-primary focus:ring-2 focus:ring-primary/20" />
                  <a href={activeProvider.docsUrl} target="_blank" rel="noreferrer" className="inline-flex items-center text-[11px] mt-1.5 text-primary hover:underline"><i className="fas fa-external-link-alt mr-1 text-[9px]"></i>{t('settings.ecommerce.getTokenLink')}</a>
                </div>
              )}

              {activeProvider.authMode === 'key_secret' && (
                <>
                  {form.mode === 'edit' && <p className="text-[10px] text-[#5c5c5a] -mb-1">{t('settings.ecommerce.credsOverrideHint')}</p>}
                  <div>
                    <label className="block text-xs font-medium text-[#4a4a48] mb-1.5">{t('settings.ecommerce.consumerKeyLabel')}</label>
                    <input type="password" value={form.creds.consumerKey || ''} onChange={(e) => patchCred('consumerKey', e.target.value)} placeholder={t('settings.ecommerce.consumerKeyPlaceholder')}
                      className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm font-mono focus:outline-none focus:border-primary focus:ring-2 focus:ring-primary/20" />
                  </div>
                  <div>
                    <label className="block text-xs font-medium text-[#4a4a48] mb-1.5">{t('settings.ecommerce.consumerSecretLabel')}</label>
                    <input type="password" value={form.creds.consumerSecret || ''} onChange={(e) => patchCred('consumerSecret', e.target.value)} placeholder={t('settings.ecommerce.consumerSecretPlaceholder')}
                      className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm font-mono focus:outline-none focus:border-primary focus:ring-2 focus:ring-primary/20" />
                    <a href={activeProvider.docsUrl} target="_blank" rel="noreferrer" className="inline-flex items-center text-[11px] mt-1.5 text-primary hover:underline"><i className="fas fa-external-link-alt mr-1 text-[9px]"></i>{t('settings.ecommerce.getKeysLink')}</a>
                  </div>
                </>
              )}

              {form.testResult === 'ok' && (
                <div className="flex items-center text-xs text-emerald-600 bg-emerald-50 px-3 py-2 rounded-lg"><i className="fas fa-check-circle mr-2"></i>{t('settings.ecommerce.testOk', { name: form.testMsg })}</div>
              )}
              {form.testResult === 'fail' && (
                <div className="text-xs text-rose-600 bg-rose-50 px-3 py-2 rounded-lg break-all"><i className="fas fa-exclamation-circle mr-1.5"></i>{t('settings.ecommerce.testFail')} · {form.testMsg}</div>
              )}

              <div className="flex space-x-2 pt-1">
                <button onClick={doFormTest} disabled={!form.shop.trim() || (form.mode === 'new' && !allCredsFilled()) || form.testing}
                  className="flex-1 border border-[#e0ddd5] text-[#4a4a48] py-2 rounded-lg text-sm font-medium hover:bg-[#f0eeeb] disabled:opacity-50">
                  {form.testing ? <><i className="fas fa-spinner fa-spin mr-1.5"></i>{t('common.testing')}</> : t('settings.ecommerce.testConnection')}
                </button>
                <button onClick={doFormSave} disabled={!canSave || form.saving}
                  className="flex-1 bg-primary hover:bg-primary-hover text-white py-2 rounded-lg text-sm font-medium disabled:opacity-50">
                  {form.saving ? <><i className="fas fa-spinner fa-spin mr-1.5"></i>{t('common.saving')}</> : t('common.save')}
                </button>
                <button onClick={closeForm} className="px-4 border border-[#e0ddd5] text-[#4a4a48] rounded-lg text-sm hover:bg-[#f0eeeb]">{t('common.cancel')}</button>
              </div>
            </div>
          )}

          {/* 平台目录（11 平台 · 三档） */}
          <div className="space-y-4">
            <h4 className="text-sm font-bold text-[#191918]">{t('settings.ecommerce.catalogTitle')}</h4>
            {[1, 2, 3].map((tier) => {
              const items = providers.filter((p) => p.tier === tier);
              if (!items.length) return null;
              return (
                <div key={tier} className="space-y-2">
                  <p className="text-[11px] font-semibold text-[#8a8a88] uppercase tracking-wide">{tierLabel(tier)}</p>
                  <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
                    {items.map((p) => (
                      <div key={p.id} className={`border rounded-xl p-3 flex items-center justify-between gap-2 ${p.connectable ? 'border-[#e0ddd5] bg-white' : 'border-[#ece9e2] bg-[#faf9f7]'}`}>
                        <div className="min-w-0">
                          <div className="flex items-center gap-2 flex-wrap">
                            <span className={`text-sm font-semibold ${p.connectable ? 'text-[#191918]' : 'text-[#6b6b69]'}`}>{p.name}</span>
                            {statusBadge(p.status)}
                          </div>
                          {p.status === 'needs_authorization' && <p className="text-[10px] text-[#8a8a88] mt-0.5">{t('settings.ecommerce.comingSoonHint')}</p>}
                          {p.status === 'planned' && <p className="text-[10px] text-[#8a8a88] mt-0.5">{t('settings.ecommerce.plannedHint')}</p>}
                        </div>
                        <div className="shrink-0">
                          {p.connectable ? (
                            <button onClick={() => openAdd(p.id)} className="text-xs px-3 py-1.5 border border-primary text-primary rounded-lg hover:bg-primary/5 whitespace-nowrap"><i className="fas fa-plus mr-1.5"></i>{t('settings.ecommerce.connect')}</button>
                          ) : p.docsUrl ? (
                            <a href={p.docsUrl} target="_blank" rel="noreferrer" className="text-[11px] text-[#8a8a88] hover:text-primary hover:underline whitespace-nowrap"><i className="fas fa-external-link-alt mr-1 text-[9px]"></i>{t('settings.ecommerce.getTokenLink')}</a>
                          ) : null}
                        </div>
                      </div>
                    ))}
                  </div>
                </div>
              );
            })}
          </div>

          {/* 安全说明 */}
          <div className="text-xs text-[#5c5c5a] bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl p-4">
            <div className="font-semibold text-[#4a4a48] mb-2"><i className="fas fa-shield-alt mr-1.5 text-primary"></i>{t('settings.ecommerce.security.title')}</div>
            <ul className="space-y-1 list-disc list-inside">
              <li>{t('settings.ecommerce.security.item1')}</li>
              <li>{t('settings.ecommerce.security.item2')}</li>
              <li>{t('settings.ecommerce.security.item3')}</li>
            </ul>
          </div>
        </>
      )}

      {ordersFor && <EcommerceOrdersModal connection={ordersFor} onClose={() => setOrdersFor(null)} />}
    </section>
  );
};

export default EcommerceConnectionsSection;
