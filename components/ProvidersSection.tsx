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
import { aiErrorMessage, aiErrorMessageFromCode } from '../services/aiErrors';
import { KNOWN_MODELS, DEFAULT_MODEL, modelLabelFor, findModelOption, shouldAutoMigrate } from './aiProviderModels';

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
    if (!r?.apiKey.trim()) return;
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
          const row = rowStates[p.provider] || initRow(p.model || DEFAULT_MODEL[p.provider]);

          return (
            <div key={p.provider} className={`border rounded-xl ${p.isDefault ? 'border-primary bg-primary/5' : 'border-[#e0ddd5] bg-white'}`}>
              <div className="p-5">
                <div className="flex items-start justify-between mb-4">
                  <div className="flex items-center">
                    <div className="w-10 h-10 rounded-lg flex items-center justify-center mr-3" style={{ backgroundColor: `${doc.color}15`, color: doc.color }}>
                      <i className={`fas ${doc.icon}`}></i>
                    </div>
                    <div>
                      <div className="flex items-center space-x-2">
                        <h4 className="text-sm font-semibold text-[#191918]">{doc.label}</h4>
                        {p.isDefault && <span className="text-[10px] font-bold bg-primary text-white px-2 py-0.5 rounded uppercase">{t('common.default')}</span>}
                        {p.hasKey && !p.isDefault && <span className="text-[10px] font-bold text-emerald-600 bg-emerald-50 px-2 py-0.5 rounded uppercase">{t('settings.ai.configured')}</span>}
                        {!p.hasKey && <span className="text-[10px] font-bold text-[#7a7a78] bg-[#f0eeeb] px-2 py-0.5 rounded uppercase">{t('settings.ai.notConfigured')}</span>}
                      </div>
                      {/* 用前端白名单解析 label，与 chip 渲染同源 */}
                      {(() => {
                        const known = findModelOption(p.provider, p.model);
                        const label = known ? known.label : modelLabelFor(p.provider, p.model);
                        const isKnown = !!known;
                        const fallbackDefault = DEFAULT_MODEL[p.provider];
                        return (
                          <>
                            <div className="text-[11px] text-[#7a7a78] mt-0.5">
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

                  <div className="flex items-center space-x-2">
                    {p.hasKey && !p.isDefault && (
                      <button onClick={() => handleSetDefault(p.provider)} className="text-xs px-3 py-1.5 border border-primary text-primary rounded-lg hover:bg-primary/5">
                        {t('settings.ai.setAsDefault')}
                      </button>
                    )}
                    {!row.editing ? (
                      <button onClick={() => startEdit(p)} className="text-xs px-3 py-1.5 border border-[#e0ddd5] text-[#4a4a48] rounded-lg hover:bg-[#f0eeeb]">
                        <i className={`fas ${p.hasKey ? 'fa-edit' : 'fa-plus'} mr-1.5`}></i>
                        {p.hasKey ? usLabel('setEditKey', 'settings.ai.editKey') : usLabel('setAddKey', 'settings.ai.addKey')}
                      </button>
                    ) : (
                      <button onClick={() => cancelEdit(p.provider)} className="text-xs px-3 py-1.5 border border-[#e0ddd5] text-[#4a4a48] rounded-lg hover:bg-[#f0eeeb]">
                        {t('common.cancel')}
                      </button>
                    )}
                    {p.hasKey && !row.editing && (
                      confirmDelete === p.provider ? (
                        <div className="flex items-center space-x-1.5 bg-rose-50 px-2 py-1 rounded-lg">
                          <span className="text-xs text-rose-600">{t('settings.ai.removeConfirm')}</span>
                          <button onClick={() => handleDelete(p.provider)} className="text-xs px-2 py-0.5 bg-rose-600 text-white rounded">{t('common.delete')}</button>
                          <button onClick={() => setConfirmDelete(null)} className="text-xs px-2 py-0.5 border border-rose-300 text-rose-600 rounded">{t('common.cancel')}</button>
                        </div>
                      ) : (
                        <button onClick={() => setConfirmDelete(p.provider)} className="text-xs px-3 py-1.5 border border-rose-200 text-rose-600 rounded-lg hover:bg-rose-50">
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
                        {t('settings.ai.apiKeyLabel')} {p.hasKey && <span className="text-[#7a7a78] font-normal">{t('settings.ai.apiKeyOverrideHint')}</span>}
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
                      <label className="block text-xs font-medium text-[#4a4a48] mb-2">{t('settings.ai.modelSection')}</label>
                      {/* 数据源：前端白名单 KNOWN_MODELS，不依赖主进程 META */}
                      <div className="flex flex-wrap gap-2 mb-2">
                        {KNOWN_MODELS[p.provider].map(opt => {
                          const selected = row.model === opt.value;
                          return (
                            <button
                              key={opt.value}
                              type="button"
                              onClick={() => updateRow(p.provider, { model: opt.value, testResult: null })}
                              title={opt.value}
                              className={`text-sm font-medium px-4 py-2 rounded-full border transition-colors ${
                                selected
                                  ? 'text-white border-transparent shadow-sm'
                                  : 'bg-white border-[#e0ddd5] text-[#4a4a48] hover:bg-[#f0eeeb]'
                              }`}
                              style={selected ? { backgroundColor: doc.color } : {}}
                            >
                              {opt.label}
                            </button>
                          );
                        })}
                      </div>
                      <details className="text-xs">
                        <summary className="text-[#7a7a78] cursor-pointer hover:text-[#4a4a48] select-none">
                          <i className="fas fa-code text-[10px] mr-1"></i>
                          {t('settings.ai.advancedInput')}
                        </summary>
                        <input
                          type="text"
                          value={row.model}
                          onChange={e => updateRow(p.provider, { model: e.target.value, testResult: null })}
                          placeholder={DEFAULT_MODEL[p.provider] || p.defaultModel}
                          className="w-full mt-2 px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm bg-white focus:outline-none focus:border-primary font-mono"
                        />
                        <p className="text-[10px] text-[#7a7a78] mt-1">
                          {t('settings.ai.currentModelId')}: <code className="bg-[#f0eeeb] px-1.5 py-0.5 rounded">{row.model}</code>
                        </p>
                      </details>
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
                      </div>
                    )}
                    {row.errorMsg && row.testResult !== 'fail' && (
                      <div className="text-xs text-rose-600 bg-rose-50 px-3 py-2 rounded-lg">{row.errorMsg}</div>
                    )}

                    <div className="flex space-x-2">
                      <button
                        onClick={() => handleTest(p.provider)}
                        disabled={!row.apiKey.trim() || row.testing}
                        className="flex-1 border border-[#e0ddd5] text-[#4a4a48] py-2 rounded-lg text-sm font-medium hover:bg-[#f0eeeb] disabled:opacity-50"
                        title={!row.apiKey.trim() ? t('settings.ai.enterKeyFirst') : ''}
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
                    {p.hasKey && (
                      <button
                        onClick={() => handleSave(p.provider, 'modelOnly')}
                        disabled={row.saving || row.model.trim() === p.model}
                        className="w-full text-xs text-[#7a7a78] hover:text-[#4a4a48] disabled:opacity-40 py-1"
                      >
                        {t('settings.ai.modelOnly')}
                      </button>
                    )}
                  </div>
                )}
              </div>
            </div>
          );
        })}
      </div>

      <div className="text-xs text-[#7a7a78] bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl p-4">
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
