// AI 服务商管理面板 — 给 SettingsPage 用
// 支持增删改、测试连接、切换默认 provider
import React, { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import type { AIProviderConfig, AIProviderId } from '../types';
import {
  listProviders,
  saveProvider,
  removeProvider,
  setDefaultProvider,
  testProvider,
  fetchSettings,
} from '../services/api';
import { getTaxLabel } from './accountingHelpers';
import { aiErrorMessage, aiErrorMessageFromCode, looksLikeModelError } from '../services/aiErrors';
import { DEFAULT_MODEL, modelLabelFor, findModelOption, shouldAutoMigrate } from './aiProviderModels';
import { providerLogo } from './providerLogos';
import { getProviderDisplayName } from './providerDisplay';

const PROVIDER_DOCS: Record<AIProviderId, { label: string; getKeyUrl: string; placeholder: string; icon: string; color: string }> = {
  anthropic: { label: 'Claude · Anthropic', getKeyUrl: 'https://console.anthropic.com/settings/keys', placeholder: 'sk-ant-api03-...', icon: 'fa-feather', color: '#274C92' },
  openai: { label: 'ChatGPT · OpenAI', getKeyUrl: 'https://platform.openai.com/api-keys', placeholder: 'sk-proj-...', icon: 'fa-robot', color: '#10a37f' },
  gemini: { label: 'Gemini · Google', getKeyUrl: 'https://aistudio.google.com/app/apikey', placeholder: 'AIzaSy...', icon: 'fa-gem', color: '#4285f4' },
  deepseek: { label: 'DeepSeek · 深度求索', getKeyUrl: 'https://platform.deepseek.com/api_keys', placeholder: 'sk-...', icon: 'fa-bolt', color: '#4D6BFE' },
  qwen: { label: '通义千问 · 阿里云', getKeyUrl: 'https://bailian.console.aliyun.com/?apiKey=1', placeholder: 'sk-...', icon: 'fa-cloud', color: '#615CED' },
  kimi: { label: 'Kimi · 月之暗面', getKeyUrl: 'https://platform.moonshot.cn/console/api-keys', placeholder: 'sk-...', icon: 'fa-moon', color: '#7C3AED' },
  glm: { label: 'GLM · 智谱 AI', getKeyUrl: 'https://bigmodel.cn/usercenter/proj-mgmt/apikeys', placeholder: 'xxxxxxxx.xxxxxxxxxxxxxxxx', icon: 'fa-brain', color: '#3859FF' },
  doubao: { label: '豆包 · 火山方舟', getKeyUrl: 'https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey', placeholder: 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx', icon: 'fa-seedling', color: '#12B5A5' },
};

interface RowState {
  editing: boolean;       // 是否在编辑（输入新 Key）
  apiKey: string;
  model: string;
  testing: boolean;
  testResult: 'ok' | 'fail' | null;
  errorMsg: string;
  errorStatus?: number;
  errorCode?: string;
  errorProviderMessage?: string; // 主进程已脱敏的原始错误（仅用于「疑似模型问题」判定，不渲染）
  saving: boolean;
}

const initRow = (model: string): RowState => ({
  editing: false, apiKey: '', model, testing: false, testResult: null, errorMsg: '', saving: false,
});

const ProvidersSection: React.FC = () => {
  const { t, i18n } = useTranslation();
  const [accLocale, setAccLocale] = useState('CN');
  useEffect(() => { fetchSettings().then((s: any) => { if (s?.accounting_locale) setAccLocale(s.accounting_locale); }).catch(() => {}); }, []);
  // US accountingLocale shows US wording (密钥 / 联网检索); other locales unchanged.
  const usLabel = (taxKey: string, i18nKey: string) => accLocale === 'US' ? getTaxLabel(accLocale, i18n.language, taxKey) : t(i18nKey);
  const [providers, setProviders] = useState<AIProviderConfig[]>([]);
  const [rowStates, setRowStates] = useState<Record<AIProviderId, RowState>>({} as any);
  const [globalMessage, setGlobalMessage] = useState<{ type: 'success' | 'error'; text: string } | null>(null);
  const [confirmDelete, setConfirmDelete] = useState<AIProviderId | null>(null);

  const reload = async () => {
    try {
      let list = await listProviders();
      console.log('[renderer providers:list]', list);

      // 兜底迁移：若主进程未重启来不及跑 migrateOldModels，这里强制把旧 ID 改写为新 ID
      const toMigrate = list.filter(p => p.hasKey && shouldAutoMigrate(p.model));
      if (toMigrate.length > 0) {
        console.log('[renderer] auto-migrating stale model IDs:', toMigrate.map(p => `${p.provider}: ${p.model} → ${shouldAutoMigrate(p.model)}`));
        for (const p of toMigrate) {
          const newId = shouldAutoMigrate(p.model)!;
          try {
            await saveProvider({ provider: p.provider, apiKey: '', model: newId, enabled: true });
          } catch (e) {
            console.error('[renderer] auto-migrate failed:', p.provider, e);
          }
        }
        list = await listProviders();
        console.log('[renderer providers:list (after migrate)]', list);
      }

      setProviders(list);
      setRowStates(prev => {
        const next: Record<string, RowState> = {};
        for (const p of list) next[p.provider] = prev[p.provider] ? { ...prev[p.provider], model: p.model } : initRow(p.model || DEFAULT_MODEL[p.provider]);
        return next as Record<AIProviderId, RowState>;
      });
    } catch (e: any) {
      setGlobalMessage({ type: 'error', text: e?.message || t('settings.ai.loadError') });
    }
  };

  useEffect(() => { reload(); }, []);

  const flash = (type: 'success' | 'error', text: string) => {
    setGlobalMessage({ type, text });
    setTimeout(() => setGlobalMessage(null), 2500);
  };

  const updateRow = (id: AIProviderId, patch: Partial<RowState>) => {
    setRowStates(prev => ({ ...prev, [id]: { ...prev[id], ...patch } }));
  };

  const startEdit = (p: AIProviderConfig) => {
    updateRow(p.provider, { editing: true, apiKey: '', testResult: null, errorMsg: '' });
  };

  const cancelEdit = (id: AIProviderId) => {
    const provider = providers.find(p => p.provider === id);
    updateRow(id, { editing: false, apiKey: '', testResult: null, errorMsg: '', model: provider?.model || '' });
  };

  const handleTest = async (id: AIProviderId) => {
    const r = rowStates[id];
    const p = providers.find(x => x.provider === id);
    // 已配置 Key 的 provider 可不重输 Key 直接测试（apiKey 传空串 → 后端用本地已存 Key）。
    if (!r?.apiKey.trim() && !p?.hasKey) return;
    updateRow(id, { testing: true, testResult: null, errorMsg: '', errorStatus: undefined, errorCode: undefined });
    try {
      const result = await testProvider({ provider: id, apiKey: r.apiKey.trim(), model: r.model.trim() });
      if (result.ok) {
        updateRow(id, { testResult: 'ok', testing: false });
      } else {
        updateRow(id, {
          testResult: 'fail',
          // R3c：按稳定 code 映射 i18n（随 uiLanguage），不再展示主进程的中文 friendly。
          errorMsg: aiErrorMessageFromCode(result.code, t),
          errorStatus: result.status,
          errorCode: result.code,
          // 仅用于渲染时判定「疑似模型不可用」并高亮 model ID 输入 + 显示提示（不渲染原文）。
          errorProviderMessage: result.providerMessage,
          testing: false,
        });
      }
    } catch (e: any) {
      updateRow(id, { testResult: 'fail', errorMsg: aiErrorMessage(e, t), testing: false });
    }
  };

  // saveMode: 'full' (Key + model) | 'modelOnly' (沿用现有 Key 仅改 model)
  // modelOverride: 传值时强制用该值（如"重置为默认"按钮）
  const handleSave = async (id: AIProviderId, saveMode: 'full' | 'modelOnly' = 'full', modelOverride?: string) => {
    const r = rowStates[id];
    const p = providers.find(x => x.provider === id);
    if (saveMode === 'full' && !r?.apiKey.trim()) return;
    if (saveMode === 'modelOnly' && !p?.hasKey) return;
    updateRow(id, { saving: true, errorMsg: '' });
    try {
      await saveProvider({
        provider: id,
        // 仅改模型时 apiKey 传空字符串，后端会沿用现有 Key
        apiKey: saveMode === 'full' ? r.apiKey.trim() : '',
        model: (modelOverride && modelOverride.trim()) || r?.model.trim() || DEFAULT_MODEL[id] || p?.defaultModel || '',
        enabled: true,
      });
      flash('success', saveMode === 'full'
        ? t('settings.ai.providerSavedToast', { name: PROVIDER_DOCS[id].label })
        : t('settings.ai.modelUpdatedToast', { name: PROVIDER_DOCS[id].label }));
      await reload();
      updateRow(id, { editing: false, apiKey: '', testResult: null, saving: false });
    } catch (e: any) {
      updateRow(id, { errorMsg: e?.message || t('settings.ai.saveError'), saving: false });
    }
  };

  const handleDelete = async (id: AIProviderId) => {
    try {
      await removeProvider(id);
      flash('success', t('settings.ai.providerRemovedToast', { name: PROVIDER_DOCS[id].label }));
      await reload();
    } catch (e: any) {
      flash('error', e?.message || t('settings.ai.deleteError'));
    } finally {
      setConfirmDelete(null);
    }
  };

  const handleSetDefault = async (id: AIProviderId) => {
    try {
      await setDefaultProvider(id);
      flash('success', t('settings.ai.defaultSetToast'));
      await reload();
    } catch (e: any) {
      flash('error', e?.message || t('settings.ai.setDefaultError'));
    }
  };

  return (
    <section className="space-y-6">
      <div>
        <h3 className="text-xl font-bold text-[#191918]">{t('settings.ai.title')}</h3>
        <p className="text-xs text-[#6b6b69] mt-1">{t('settings.ai.subtitle')}</p>
      </div>

      {globalMessage && (
        <div className={`px-4 py-2.5 rounded-lg text-sm ${globalMessage.type === 'success' ? 'bg-emerald-50 text-emerald-700' : 'bg-rose-50 text-rose-700'}`}>
          <i className={`fas ${globalMessage.type === 'success' ? 'fa-check-circle' : 'fa-exclamation-circle'} mr-2`}></i>
          {globalMessage.text}
        </div>
      )}

      <div className="space-y-3">
        {providers.map(p => {
          const doc = PROVIDER_DOCS[p.provider];
          const logo = providerLogo(p.provider);
          const name = getProviderDisplayName(p.provider, i18n.language);
          const row = rowStates[p.provider] || initRow(p.model || DEFAULT_MODEL[p.provider]);
          // 上次测试失败且疑似「模型不可用」→ 引导用户去高级 model ID 输入框改填可用 ID。
          const modelHintActive = row.testResult === 'fail' && looksLikeModelError(row.errorCode, row.errorProviderMessage);

          return (
            <div key={p.provider} className={`border rounded-xl ${p.isDefault ? 'border-primary bg-primary/5' : 'border-[#e0ddd5] bg-white'}`}>
              <div className="p-5">
                <div className="flex items-start justify-between gap-3 flex-wrap mb-4">
                  <div className="flex items-center min-w-0 flex-1">
                    {logo ? (
                      <div className="w-10 h-10 rounded-lg flex items-center justify-center mr-3 bg-[#f5f5f4]">
                        <img src={logo} alt={name} className="w-6 h-6 object-contain" />
                      </div>
                    ) : (
                      <div className="w-10 h-10 rounded-lg flex items-center justify-center mr-3" style={{ backgroundColor: `${doc.color}15`, color: doc.color }}>
                        <i className={`fas ${doc.icon}`}></i>
                      </div>
                    )}
                    <div className="min-w-0">
                      <div className="flex items-center space-x-2">
                        <h4 className="text-sm font-semibold text-[#191918]">{name}</h4>
                        {p.isDefault && <span className="text-[10px] font-bold bg-primary text-white px-2 py-0.5 rounded uppercase">{t('common.default')}</span>}
                        {p.hasKey && !p.isDefault && <span className="text-[10px] font-bold text-emerald-600 bg-emerald-50 px-2 py-0.5 rounded uppercase">{t('settings.ai.configured')}</span>}
                        {!p.hasKey && <span className="text-[10px] font-bold text-[#5c5c5a] bg-[#f0eeeb] px-2 py-0.5 rounded uppercase">{t('settings.ai.notConfigured')}</span>}
                      </div>
                      {/* 用前端白名单解析 label，与 chip 渲染同源 */}
                      {(() => {
                        const known = findModelOption(p.provider, p.model);
                        const label = known ? known.label : modelLabelFor(p.provider, p.model);
                        const isKnown = !!known;
                        const fallbackDefault = DEFAULT_MODEL[p.provider];
                        return (
                          <>
                            <div className="text-[11px] text-[#5c5c5a] mt-0.5">
                              {t('settings.ai.modelLabel')} <span className="font-medium text-[#4a4a48]">{label}</span>
                              {isKnown && (
                                <code className="ml-1.5 bg-[#f0eeeb] px-1.5 py-0.5 rounded text-[10px]">{p.model}</code>
                              )}
                              {p.supportsWebGrounding && <span className="ml-2 text-primary">{usLabel('setWebGrounding', 'settings.ai.supportsWebGrounding')}</span>}
                            </div>
                            {!isKnown && p.hasKey && (
                              <div className="text-[10px] text-amber-700 bg-amber-50 border border-amber-200 rounded px-2 py-1 mt-1.5">
                                <i className="fas fa-info-circle mr-1"></i>
                                {t('settings.ai.staleModelHint')}
                                <button
                                  onClick={() => handleSave(p.provider, 'modelOnly', fallbackDefault)}
                                  disabled={row.saving}
                                  className="ml-1 underline hover:text-amber-900"
                                >
                                  {t('settings.ai.resetTo', { model: fallbackDefault })}
                                </button>
                              </div>
                            )}
                          </>
                        );
                      })()}
                    </div>
                  </div>

                  <div className="flex items-center gap-2 flex-wrap shrink-0">
                    {p.hasKey && !p.isDefault && (
                      <button onClick={() => handleSetDefault(p.provider)} className="text-xs px-3 py-1.5 border border-primary text-primary rounded-lg hover:bg-primary/5 whitespace-nowrap">
                        {t('settings.ai.setAsDefault')}
                      </button>
                    )}
                    {!row.editing ? (
                      <button onClick={() => startEdit(p)} className="text-xs px-3 py-1.5 border border-[#e0ddd5] text-[#4a4a48] rounded-lg hover:bg-[#f0eeeb] whitespace-nowrap">
                        <i className={`fas ${p.hasKey ? 'fa-edit' : 'fa-plus'} mr-1.5`}></i>
                        {p.hasKey ? usLabel('setEditKey', 'settings.ai.editKey') : usLabel('setAddKey', 'settings.ai.addKey')}
                      </button>
                    ) : (
                      <button onClick={() => cancelEdit(p.provider)} className="text-xs px-3 py-1.5 border border-[#e0ddd5] text-[#4a4a48] rounded-lg hover:bg-[#f0eeeb] whitespace-nowrap">
                        {t('common.cancel')}
                      </button>
                    )}
                    {p.hasKey && !row.editing && (
                      confirmDelete === p.provider ? (
                        <div className="flex items-center space-x-1.5 bg-rose-50 px-2 py-1 rounded-lg whitespace-nowrap">
                          <span className="text-xs text-rose-600">{t('settings.ai.removeConfirm')}</span>
                          <button onClick={() => handleDelete(p.provider)} className="text-xs px-2 py-0.5 bg-rose-600 text-white rounded whitespace-nowrap">{t('common.delete')}</button>
                          <button onClick={() => setConfirmDelete(null)} className="text-xs px-2 py-0.5 border border-rose-300 text-rose-600 rounded whitespace-nowrap">{t('common.cancel')}</button>
                        </div>
                      ) : (
                        <button onClick={() => setConfirmDelete(p.provider)} className="text-xs px-3 py-1.5 border border-rose-200 text-rose-600 rounded-lg hover:bg-rose-50 whitespace-nowrap">
                          <i className="fas fa-trash mr-1.5"></i>{t('common.delete')}
                        </button>
                      )
                    )}
                  </div>
                </div>

                {row.editing && (
                  <div className="space-y-3 pt-3 border-t border-[#e0ddd5]/60">
                    <div>
                      <label className="block text-xs font-medium text-[#4a4a48] mb-2">
                        {t('settings.ai.apiKeyLabel')} {p.hasKey && <span className="text-[#5c5c5a] font-normal">{t('settings.ai.apiKeyOverrideHint')}</span>}
                      </label>
                      <input
                        type="password"
                        value={row.apiKey}
                        onChange={e => updateRow(p.provider, { apiKey: e.target.value, testResult: null })}
                        placeholder={doc.placeholder}
                        className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm focus:outline-none focus:border-primary focus:ring-2 focus:ring-primary/20"
                      />
                      <a href={doc.getKeyUrl} target="_blank" rel="noreferrer" className="inline-flex items-center text-[11px] mt-1.5 hover:underline" style={{ color: doc.color }}>
                        <i className="fas fa-external-link-alt mr-1 text-[9px]"></i>
                        {t('settings.ai.getKeyLink')}
                      </a>
                    </div>

                    <div>
                      <label className="block text-xs font-medium text-[#4a4a48] mb-2">{t('settings.ai.modelIdLabel')}</label>
                      {/* 唯一入口：手动输入 model ID（填账号当前可用的 ID）。model 列表数据仍服务卡片头 label + 引导页 chips。 */}
                      <input
                        type="text"
                        value={row.model}
                        onChange={e => updateRow(p.provider, { model: e.target.value, testResult: null })}
                        placeholder={DEFAULT_MODEL[p.provider] || p.defaultModel}
                        className={`w-full px-3 py-2 border rounded-lg text-sm bg-white focus:outline-none focus:border-primary font-mono ${modelHintActive ? 'border-amber-400 ring-1 ring-amber-300' : 'border-[#e0ddd5]'}`}
                      />
                      <p className="text-[10px] text-[#5c5c5a] mt-1.5">{t('settings.ai.modelIdDesc')}</p>
                    </div>

                    {row.testResult === 'ok' && (
                      <div className="flex items-center text-xs text-emerald-600 bg-emerald-50 px-3 py-2 rounded-lg">
                        <i className="fas fa-check-circle mr-2"></i>{t('settings.ai.testOk')}
                      </div>
                    )}
                    {row.testResult === 'fail' && (
                      <div className="text-xs text-rose-600 bg-rose-50 px-3 py-2 rounded-lg">
                        <div className="font-medium">
                          <i className="fas fa-exclamation-circle mr-1.5"></i>
                          {t('settings.ai.testFail')}
                          {row.errorStatus ? ` · HTTP ${row.errorStatus}` : ''}
                          {row.errorCode ? ` · ${row.errorCode}` : ''}
                        </div>
                        <div className="mt-1 break-all">{row.errorMsg}</div>
                        {/* 服务商原始返回（主进程已 redactSecrets 脱敏，UI 再截断）——让 unknown 等泛化错误也有可读线索。 */}
                        {row.errorProviderMessage && (
                          <div className="mt-1 pt-1 border-t border-rose-200/60 break-all font-mono text-[10px] text-rose-500">
                            {t('settings.ai.providerErrorDetail')}: {row.errorProviderMessage.slice(0, 240)}
                          </div>
                        )}
                      </div>
                    )}
                    {modelHintActive && (
                      <div className="text-xs text-amber-800 bg-amber-50 border border-amber-200 px-3 py-2 rounded-lg">
                        <i className="fas fa-lightbulb mr-1.5"></i>
                        {t('settings.ai.modelMaybeUnavailable')}
                      </div>
                    )}
                    {row.errorMsg && row.testResult !== 'fail' && (
                      <div className="text-xs text-rose-600 bg-rose-50 px-3 py-2 rounded-lg">{row.errorMsg}</div>
                    )}

                    <div className="flex space-x-2">
                      <button
                        onClick={() => handleTest(p.provider)}
                        disabled={(!row.apiKey.trim() && !p.hasKey) || row.testing}
                        className="flex-1 border border-[#e0ddd5] text-[#4a4a48] py-2 rounded-lg text-sm font-medium hover:bg-[#f0eeeb] disabled:opacity-50"
                        title={(!row.apiKey.trim() && !p.hasKey) ? t('settings.ai.enterKeyFirst') : ''}
                      >
                        {row.testing ? <><i className="fas fa-spinner fa-spin mr-1.5"></i>{t('common.testing')}</> : t('settings.ai.testConnection')}
                      </button>
                      <button
                        onClick={() => handleSave(p.provider, 'full')}
                        disabled={!row.apiKey.trim() || row.saving}
                        className="flex-1 text-white py-2 rounded-lg text-sm font-medium disabled:opacity-50"
                        style={{ backgroundColor: doc.color }}
                      >
                        {row.saving ? <><i className="fas fa-spinner fa-spin mr-1.5"></i>{t('common.saving')}</> : (p.hasKey ? t('settings.ai.updateBoth') : t('common.save'))}
                      </button>
                    </div>
                    {/* Bug 4: model-only save. Shown as a prominent primary-style button (matching
                        the main save) only when the model actually changed on an already-keyed
                        provider — so switching model has a clear, enabled Save without re-entering
                        the API key. Hidden when the model is unchanged. Reuses handleSave('modelOnly'). */}
                    {p.hasKey && row.model.trim() !== p.model && (
                      <button
                        onClick={() => handleSave(p.provider, 'modelOnly')}
                        disabled={row.saving}
                        className="w-full text-white py-2 rounded-lg text-sm font-medium disabled:opacity-50"
                        style={{ backgroundColor: doc.color }}
                      >
                        {row.saving ? <><i className="fas fa-spinner fa-spin mr-1.5"></i>{t('common.saving')}</> : t('settings.ai.modelOnly')}
                      </button>
                    )}
                  </div>
                )}
              </div>
            </div>
          );
        })}
      </div>

      <div className="text-xs text-[#5c5c5a] bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl p-4">
        <div className="font-semibold text-[#4a4a48] mb-2">
          <i className="fas fa-shield-alt mr-1.5 text-primary"></i>
          {t('settings.ai.security.title')}
        </div>
        <ul className="space-y-1 list-disc list-inside">
          <li>{t('settings.ai.security.item1')}</li>
          <li>{t('settings.ai.security.item2')}</li>
          <li>{t('settings.ai.security.item3')}</li>
        </ul>
      </div>
    </section>
  );
};

export default ProvidersSection;
