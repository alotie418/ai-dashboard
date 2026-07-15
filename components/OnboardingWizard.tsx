import React, { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import type { AIProviderConfig, AIProviderId } from '../types';
import { listProviders, saveProvider, setDefaultProvider, testProvider, saveSettings } from '../services/api';
import { aiErrorMessage, aiErrorMessageFromCode } from '../services/aiErrors';
import { KNOWN_MODELS, DEFAULT_MODEL } from './aiProviderModels';
import { providerLogo } from './providerLogos';
import { getProviderDisplayName } from './providerDisplay';
import { SUPPORTED_LANGUAGES, setLanguage, type LangCode } from '../i18n';
import { ACCOUNTING_LOCALES, type AccountingLocaleId } from './accountingLocaleConfig';
import { ACCOUNTING_PROFILES } from './accountingProfiles';

interface Props {
  onComplete: () => void;
}

type Step = 'welcome' | 'locale' | 'providers' | 'company';

const electronAPI = typeof window !== 'undefined' ? (window as any).electronAPI : null;

// 每个 provider 一行表单：apiKey + 测试连接 + 保存
interface ProviderFormState {
  apiKey: string;
  model: string;
  testing: boolean;
  testResult: 'ok' | 'fail' | null;
  errorMsg: string;
  errorStatus?: number;
  errorCode?: string;
  saving: boolean;
  saved: boolean;
}

const initialForm = (model: string): ProviderFormState => ({
  apiKey: '',
  model,
  testing: false,
  testResult: null,
  errorMsg: '',
  saving: false,
  saved: false,
});

const PROVIDER_DOCS: Record<AIProviderId, { label: string; getKeyUrl: string; placeholder: string; icon: string; color: string }> = {
  anthropic: {
    label: 'Claude · Anthropic',
    getKeyUrl: 'https://console.anthropic.com/settings/keys',
    placeholder: 'sk-ant-api03-...',
    icon: 'fa-feather',
    color: '#274C92',
  },
  openai: {
    label: 'ChatGPT · OpenAI',
    getKeyUrl: 'https://platform.openai.com/api-keys',
    placeholder: 'sk-proj-...',
    icon: 'fa-robot',
    color: '#10a37f',
  },
  gemini: {
    label: 'Gemini · Google',
    getKeyUrl: 'https://aistudio.google.com/app/apikey',
    placeholder: 'AIzaSy...',
    icon: 'fa-gem',
    color: '#4285f4',
  },
  deepseek: {
    label: 'DeepSeek · 深度求索',
    getKeyUrl: 'https://platform.deepseek.com/api_keys',
    placeholder: 'sk-...',
    icon: 'fa-bolt',
    color: '#4D6BFE',
  },
  qwen: {
    label: '通义千问 · 阿里云',
    getKeyUrl: 'https://bailian.console.aliyun.com/?apiKey=1',
    placeholder: 'sk-...',
    icon: 'fa-cloud',
    color: '#615CED',
  },
  kimi: {
    label: 'Kimi · 月之暗面',
    getKeyUrl: 'https://platform.moonshot.cn/console/api-keys',
    placeholder: 'sk-...',
    icon: 'fa-moon',
    color: '#7C3AED',
  },
  glm: {
    label: 'GLM · 智谱 AI',
    getKeyUrl: 'https://bigmodel.cn/usercenter/proj-mgmt/apikeys',
    placeholder: 'xxxxxxxx.xxxxxxxxxxxxxxxx',
    icon: 'fa-brain',
    color: '#3859FF',
  },
  doubao: {
    label: '豆包 · 火山方舟',
    getKeyUrl: 'https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey',
    placeholder: 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx',
    icon: 'fa-seedling',
    color: '#12B5A5',
  },
};

const OnboardingWizard: React.FC<Props> = ({ onComplete }) => {
  const { t, i18n } = useTranslation();
  const [step, setStep] = useState<Step>('welcome');
  // MAS build: no external-AI provider step — a slimmed welcome → locale → company flow.
  // (The 'providers' step and all its AI/BYOK logic below are dead-code-eliminated.)
  const STEPS: Step[] = __MAS_BUILD__ ? ['welcome', 'locale', 'company'] : ['welcome', 'locale', 'providers', 'company'];
  const [providers, setProviders] = useState<AIProviderConfig[]>([]);
  const [forms, setForms] = useState<Record<AIProviderId, ProviderFormState>>({} as any);
  const [expandedProvider, setExpandedProvider] = useState<AIProviderId | null>(null);
  const [defaultProvider, setDefaultProviderState] = useState<AIProviderId | null>(null);

  // Locale step state — UI Language and Accounting Locale are independent
  const [selectedUILang, setSelectedUILang] = useState<string>(i18n.language || 'zh-CN');
  const [selectedAccLocale, setSelectedAccLocale] = useState<string>('CN');

  const [companyName, setCompanyName] = useState('');
  const [industry, setIndustry] = useState('');
  const [companySaving, setCompanySaving] = useState(false);
  const [companyError, setCompanyError] = useState('');
  const [loadError, setLoadError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  // 初始加载所有 provider 元信息
  useEffect(() => {
    // MAS build: no AI providers — skip the fetch entirely (listProviders + its channel are
    // excluded). Everything below is dead-code-eliminated.
    if (__MAS_BUILD__) { setLoading(false); return; }
    listProviders().then(list => {
      setProviders(list);
      const initForms: Record<string, ProviderFormState> = {};
      // 用前端白名单的默认值初始化，不依赖主进程返回的 defaultModel
      // （主进程可能跑旧代码，返回旧的 default）
      for (const p of list) initForms[p.provider] = initialForm(DEFAULT_MODEL[p.provider] || p.defaultModel);
      setForms(initForms as Record<AIProviderId, ProviderFormState>);
      if (list.length > 0) setExpandedProvider(list[0].provider);
      setLoadError(null);
    }).catch(e => {
      const msg = e?.message || String(e);
      setLoadError(msg);
      console.error('[Onboarding] listProviders failed:', e);
    }).finally(() => setLoading(false));
  }, []);

  const savedCount = Object.values(forms).filter(f => f.saved).length;

  const updateForm = (id: AIProviderId, patch: Partial<ProviderFormState>) => {
    setForms(prev => ({ ...prev, [id]: { ...prev[id], ...patch } }));
  };

  const handleTest = async (id: AIProviderId) => {
    if (__MAS_BUILD__) return; // MAS: no external-AI — DCE'd
    const form = forms[id];
    if (!form?.apiKey.trim()) return;
    updateForm(id, { testing: true, testResult: null, errorMsg: '', errorStatus: undefined, errorCode: undefined });
    try {
      const r = await testProvider({ provider: id, apiKey: form.apiKey.trim(), model: form.model.trim() });
      if (r.ok) {
        updateForm(id, { testResult: 'ok', testing: false });
      } else {
        updateForm(id, {
          testResult: 'fail',
          // R3c：按稳定 code 映射 i18n（随 uiLanguage），不再展示主进程的中文 friendly。
          errorMsg: aiErrorMessageFromCode(r.code, t),
          errorStatus: r.status,
          errorCode: r.code,
          testing: false,
        });
      }
    } catch (e: any) {
      updateForm(id, { testResult: 'fail', errorMsg: aiErrorMessage(e, t), testing: false });
    }
  };

  const handleSave = async (id: AIProviderId) => {
    if (__MAS_BUILD__) return; // MAS: no external-AI — DCE'd
    const form = forms[id];
    if (!form?.apiKey.trim()) return;
    updateForm(id, { saving: true, errorMsg: '' });
    try {
      await saveProvider({
        provider: id,
        apiKey: form.apiKey.trim(),
        model: form.model,
        enabled: true,
        setAsDefault: defaultProvider == null, // 第一个保存的自动设为默认
      });
      if (defaultProvider == null) setDefaultProviderState(id);
      updateForm(id, { saved: true, saving: false, apiKey: '••••••••••••••' });
      // 折起当前，展开下一个未保存的
      const remaining = providers.find(p => p.provider !== id && !forms[p.provider]?.saved);
      setExpandedProvider(remaining?.provider || null);
    } catch (e: any) {
      updateForm(id, { errorMsg: e?.message || t('settings.ai.saveError'), saving: false });
    }
  };

  const handleSetDefault = async (id: AIProviderId) => {
    if (__MAS_BUILD__) return; // MAS: no external-AI — DCE'd
    try {
      await setDefaultProvider(id);
      setDefaultProviderState(id);
    } catch (e: any) {
      console.error(e);
    }
  };

  const finish = async () => {
    setCompanySaving(true);
    setCompanyError('');
    try {
      if (companyName.trim()) {
        await electronAPI.invoke('api:request', {
          method: 'PUT',
          path: '/api/settings',
          body: {
            company_info: {
              name: companyName.trim(),
              creditCode: '',
              legalPerson: '',
              industry: industry.trim(),
              address: '',
            },
          },
        });
      }
      onComplete();
    } catch (e: any) {
      setCompanyError(e?.message || t('settings.ai.saveError'));
    } finally {
      setCompanySaving(false);
    }
  };

  return (
    <div className="min-h-screen flex items-center justify-center bg-[#f9f9f8] px-6 py-8">
      <div className="w-full max-w-2xl bg-white border border-[#e0ddd5] rounded-2xl p-10" style={{ boxShadow: '0 8px 48px rgba(0,0,0,0.06)' }}>
        {/* Logo */}
        <div className="flex items-center justify-center mb-7">
          <div className="w-12 h-12 bg-primary rounded-xl flex items-center justify-center mr-3 shadow-lg" style={{ boxShadow: '0 4px 24px rgba(39,76,146,0.2)' }}>
            <i className="fas fa-layer-group text-white text-xl"></i>
          </div>
          <div>
            <h1 className="text-2xl font-bold text-[#191918] tracking-tight">SoloLedger</h1>
            <p className="text-xs text-[#6b6b69]">{t('onboarding.brandTagline')}</p>
          </div>
        </div>

        {/* Progress dots */}
        <div className="flex items-center justify-center mb-8 space-x-2">
          {STEPS.map((s, i) => (
            <React.Fragment key={s}>
              <div className={`w-2 h-2 rounded-full transition-all ${s === step ? 'bg-primary w-6' : (STEPS.indexOf(step) > i ? 'bg-primary/40' : 'bg-[#e0ddd5]')}`}></div>
              {i < STEPS.length - 1 && <div className="w-4 h-px bg-[#e0ddd5]"></div>}
            </React.Fragment>
          ))}
        </div>

        {step === 'welcome' && (
          <div className="space-y-6">
            <h2 className="text-xl font-semibold text-[#191918]">{t('onboarding.welcomeTitle')}</h2>
            <p className="text-sm text-[#4a4a48] leading-relaxed">
              {t('onboarding.welcomeDescription')}
            </p>
            <ul className="space-y-3 text-sm text-[#4a4a48]">
              <li className="flex items-start">
                <i className="fas fa-shield-alt text-primary mt-1 mr-3 w-4 text-center"></i>
                <span>{t('onboarding.feature1')}</span>
              </li>
              {/* MAS build: no BYOK / API-key feature — hide this value prop. */}
              {!__MAS_BUILD__ && (
                <li className="flex items-start">
                  <i className="fas fa-key text-primary mt-1 mr-3 w-4 text-center"></i>
                  <span>{t('onboarding.feature2')}</span>
                </li>
              )}
              <li className="flex items-start">
                <i className="fas fa-lock text-primary mt-1 mr-3 w-4 text-center"></i>
                <span>{t('onboarding.feature3')}</span>
              </li>
              <li className="flex items-start">
                <i className="fas fa-cloud-download-alt text-primary mt-1 mr-3 w-4 text-center"></i>
                <span>{t('onboarding.feature4')}</span>
              </li>
            </ul>
            <button
              onClick={() => setStep('locale')}
              className="w-full bg-primary text-white py-3 rounded-lg font-medium hover:bg-primary-hover transition-colors"
            >
              {t('onboarding.startConfig')}
            </button>
          </div>
        )}

        {/* Step: Language + Accounting Locale (independent) */}
        {step === 'locale' && (
          <div className="space-y-5">
            <div>
              <h2 className="text-xl font-semibold text-[#191918] mb-2">{t('settings.language.title', 'Interface Language')} & {t('settings.accounting.title', 'Accounting Basis')}</h2>
              <p className="text-sm text-[#6b6b69]">{t('onboarding.localeDesc', 'These are independent settings. UI language controls menus and labels. Accounting basis controls tax rules, currency, and reports.')}</p>
            </div>

            {/* UI Language */}
            <div>
              <label className="block text-xs font-semibold text-[#4a4a48] mb-2">
                <i className="fas fa-language mr-1.5 text-blue-500"></i>
                {t('settings.language.title', 'Interface Language')}
                <span className="text-[#5c5c5a] font-normal ml-2">— {t('settings.language.scopeNo', 'Only affects menus, buttons, labels')}</span>
              </label>
              <div className="grid grid-cols-3 gap-2">
                {SUPPORTED_LANGUAGES.map(lang => {
                  const sel = selectedUILang === lang.code;
                  return (
                    <button key={lang.code} type="button"
                      onClick={() => { setSelectedUILang(lang.code); setLanguage(lang.code as LangCode); }}
                      className={`flex items-center p-3 rounded-lg border text-sm transition-all ${sel ? 'border-primary bg-primary/5' : 'border-[#e0ddd5] bg-white hover:bg-[#f0eeeb]'}`}>
                      <span className="text-lg mr-2">{lang.flag}</span>
                      <span className="font-medium text-[#191918]">{lang.label}</span>
                      {sel && <i className="fas fa-check-circle text-primary ml-auto"></i>}
                    </button>
                  );
                })}
              </div>
            </div>

            {/* Accounting Locale */}
            <div>
              <label className="block text-xs font-semibold text-[#4a4a48] mb-2">
                <i className="fas fa-balance-scale mr-1.5 text-emerald-500"></i>
                {t('settings.accounting.title', 'Accounting Basis')}
                <span className="text-[#5c5c5a] font-normal ml-2">— {t('settings.accounting.scopeNo', 'Controls tax rules, currency, reports')}</span>
              </label>
              <div className="grid grid-cols-3 gap-2">
                {(Object.keys(ACCOUNTING_PROFILES) as string[]).map(code => {
                  const p = ACCOUNTING_PROFILES[code as keyof typeof ACCOUNTING_PROFILES];
                  const sel = selectedAccLocale === code;
                  const name = p.name[selectedUILang] || p.name['en'] || code;
                  return (
                    <button key={code} type="button"
                      onClick={() => setSelectedAccLocale(code)}
                      className={`flex items-center p-3 rounded-lg border text-sm transition-all ${sel ? 'border-emerald-500 bg-emerald-50' : 'border-[#e0ddd5] bg-white hover:bg-[#f0eeeb]'}`}>
                      <span className="text-lg mr-2">{p.flag}</span>
                      <div className="flex-1 text-left">
                        <span className="font-medium text-[#191918]">{name}</span>
                        <div className="text-[10px] text-[#5c5c5a]">{p.currency} {p.currencySymbol}</div>
                      </div>
                      {sel && <i className="fas fa-check-circle text-emerald-500 ml-auto"></i>}
                    </button>
                  );
                })}
              </div>
            </div>

            <div className="flex space-x-3 pt-2">
              <button onClick={() => setStep('welcome')} className="px-5 border border-[#e0ddd5] text-[#4a4a48] py-2.5 rounded-lg font-medium hover:bg-[#f0eeeb] transition-colors">
                {t('common.back')}
              </button>
              <button
                onClick={async () => {
                  // Save accounting locale to DB (UI language already saved via setLanguage)
                  try {
                    const p = ACCOUNTING_PROFILES[selectedAccLocale as keyof typeof ACCOUNTING_PROFILES];
                    await saveSettings({
                      accounting_locale: selectedAccLocale,
                      vat_rate: p.vatRate,
                      surcharge_rate: p.surchargeRate,
                      income_tax_rate: p.incomeTaxRate,
                      currency: p.currency,
                    } as any);
                  } catch { /* ignore */ }
                  setStep(__MAS_BUILD__ ? 'company' : 'providers');
                }}
                className="flex-1 bg-primary text-white py-2.5 rounded-lg font-medium hover:bg-primary-hover transition-colors"
              >
                {t('common.next')}
              </button>
            </div>
          </div>
        )}

        {!__MAS_BUILD__ && step === 'providers' && (
          <div className="space-y-5">
            <div>
              <h2 className="text-xl font-semibold text-[#191918] mb-2">{t('onboarding.providerTitle')}</h2>
              <p className="text-sm text-[#6b6b69]">{t('onboarding.providerSubtitle')}</p>
            </div>

            {loading && (
              <div className="flex items-center justify-center py-10 text-sm text-[#6b6b69]">
                <i className="fas fa-spinner fa-spin mr-2 text-primary"></i>{t('onboarding.loadingProviders')}
              </div>
            )}

            {loadError && (
              <div className="bg-rose-50 border border-rose-200 rounded-lg p-4 text-sm text-rose-700">
                <div className="font-medium mb-1"><i className="fas fa-exclamation-triangle mr-2"></i>{t('onboarding.loadFailedTitle')}</div>
                <div className="text-xs break-all">{loadError}</div>
                <div className="text-xs mt-2 text-rose-600">{t('onboarding.loadFailedHint')}</div>
              </div>
            )}

            {!loading && !loadError && providers.length === 0 && (
              <div className="bg-amber-50 border border-amber-200 rounded-lg p-4 text-sm text-amber-700">
                {t('onboarding.providersEmpty')}
              </div>
            )}

            <div className="space-y-3">
              {providers.map(p => {
                const doc = PROVIDER_DOCS[p.provider];
                const logo = providerLogo(p.provider);
                const name = getProviderDisplayName(p.provider, i18n.language);
                const form = forms[p.provider];
                const expanded = expandedProvider === p.provider;
                if (!form) return null;

                return (
                  <div key={p.provider} className={`border rounded-xl transition-all ${form.saved ? 'border-emerald-300 bg-emerald-50/30' : 'border-[#e0ddd5] bg-white'}`}>
                    <button
                      onClick={() => setExpandedProvider(expanded ? null : p.provider)}
                      className="w-full flex items-center justify-between p-4 text-left"
                    >
                      <div className="flex items-center">
                        {logo ? (
                          <div className="w-9 h-9 rounded-lg flex items-center justify-center mr-3 bg-[#f5f5f4]">
                            <img src={logo} alt={name} className="w-5 h-5 object-contain" />
                          </div>
                        ) : (
                          <div className="w-9 h-9 rounded-lg flex items-center justify-center mr-3" style={{ backgroundColor: `${doc.color}15`, color: doc.color }}>
                            <i className={`fas ${doc.icon}`}></i>
                          </div>
                        )}
                        <div>
                          <div className="text-sm font-semibold text-[#191918]">{name}</div>
                          <div className="text-[11px] text-[#5c5c5a]">
                            {form.saved ? t('onboarding.savedBadge') : t('onboarding.clickToExpand')}
                          </div>
                        </div>
                      </div>
                      <div className="flex items-center space-x-2">
                        {form.saved && defaultProvider === p.provider && (
                          <span className="text-[10px] font-bold bg-primary text-white px-2 py-1 rounded uppercase">{t('onboarding.defaultBadge')}</span>
                        )}
                        <i className={`fas fa-chevron-${expanded ? 'up' : 'down'} text-[#5c5c5a] text-xs`}></i>
                      </div>
                    </button>

                    {expanded && (
                      <div className="px-4 pb-4 space-y-3 border-t border-[#e0ddd5]/60 pt-4">
                        <div>
                          <label className="block text-xs font-medium text-[#4a4a48] mb-2">API Key</label>
                          <input
                            type="password"
                            value={form.apiKey}
                            onChange={e => updateForm(p.provider, { apiKey: e.target.value, testResult: null, saved: false })}
                            placeholder={doc.placeholder}
                            className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm focus:outline-none focus:border-primary focus:ring-2 focus:ring-primary/20"
                          />
                          <a href={doc.getKeyUrl} target="_blank" rel="noreferrer" className="inline-flex items-center text-[11px] mt-1.5 hover:underline" style={{ color: doc.color }}>
                            <i className="fas fa-external-link-alt mr-1 text-[9px]"></i>
                            {t('onboarding.howToGetKey', { provider: name })}
                          </a>
                        </div>

                        <div>
                          <label className="block text-xs font-medium text-[#4a4a48] mb-2">{t('settings.ai.modelSection')}</label>
                          {/* 数据源：前端白名单 KNOWN_MODELS，不依赖主进程 META，避免主进程缓存陈旧数据污染 UI */}
                          <div className="flex flex-wrap gap-2 mb-2">
                            {KNOWN_MODELS[p.provider].map(opt => {
                              const selected = form.model === opt.value;
                              return (
                                <button
                                  key={opt.value}
                                  type="button"
                                  onClick={() => updateForm(p.provider, { model: opt.value, testResult: null })}
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
                          {/* 自由编辑 model ID（高级用法：代理网关 / 自定义模型） */}
                          <details className="text-xs">
                            <summary className="text-[#5c5c5a] cursor-pointer hover:text-[#4a4a48] select-none">
                              <i className="fas fa-code text-[10px] mr-1"></i>
                              {t('settings.ai.advancedInput')}
                            </summary>
                            <input
                              type="text"
                              value={form.model}
                              onChange={e => updateForm(p.provider, { model: e.target.value, testResult: null })}
                              placeholder={p.defaultModel}
                              className="w-full mt-2 px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm bg-white focus:outline-none focus:border-primary font-mono"
                            />
                            <p className="text-[10px] text-[#5c5c5a] mt-1">
                              {t('settings.ai.currentModelId')}: <code className="bg-[#f0eeeb] px-1.5 py-0.5 rounded">{form.model}</code>
                            </p>
                          </details>
                        </div>

                        {form.testResult === 'ok' && (
                          <div className="flex items-center text-xs text-emerald-600 bg-emerald-50 px-3 py-2 rounded-lg">
                            <i className="fas fa-check-circle mr-2"></i>
                            {t('settings.ai.testOk')}
                          </div>
                        )}
                        {form.testResult === 'fail' && (
                          <div className="flex items-start text-xs text-rose-600 bg-rose-50 px-3 py-2 rounded-lg">
                            <i className="fas fa-exclamation-circle mr-2 mt-0.5"></i>
                            <div className="flex-1">
                              <div className="font-medium">
                                {t('settings.ai.testFail')}
                                {form.errorStatus ? ` · HTTP ${form.errorStatus}` : ''}
                                {form.errorCode ? ` · ${form.errorCode}` : ''}
                              </div>
                              <div className="mt-0.5 break-all">{form.errorMsg}</div>
                            </div>
                          </div>
                        )}
                        {form.errorMsg && form.testResult !== 'fail' && (
                          <div className="text-xs text-rose-600 bg-rose-50 px-3 py-2 rounded-lg">{form.errorMsg}</div>
                        )}

                        <div className="flex space-x-2">
                          <button
                            onClick={() => handleTest(p.provider)}
                            disabled={!form.apiKey.trim() || form.testing || form.saved}
                            className="flex-1 border border-[#e0ddd5] text-[#4a4a48] py-2 rounded-lg text-sm font-medium hover:bg-[#f0eeeb] disabled:opacity-50 transition-colors"
                          >
                            {form.testing ? <><i className="fas fa-spinner fa-spin mr-1.5"></i>{t('onboarding.testing')}</> : t('settings.ai.testConnection')}
                          </button>
                          {!form.saved ? (
                            <button
                              onClick={() => handleSave(p.provider)}
                              disabled={!form.apiKey.trim() || form.saving}
                              className="flex-1 text-white py-2 rounded-lg text-sm font-medium disabled:opacity-50 transition-colors"
                              style={{ backgroundColor: doc.color }}
                            >
                              {form.saving ? <><i className="fas fa-spinner fa-spin mr-1.5"></i>{t('onboarding.saving')}</> : t('onboarding.saveBtn')}
                            </button>
                          ) : (
                            defaultProvider !== p.provider && (
                              <button
                                onClick={() => handleSetDefault(p.provider)}
                                className="flex-1 text-primary border border-primary py-2 rounded-lg text-sm font-medium hover:bg-primary/5 transition-colors"
                              >
                                {t('settings.ai.setAsDefault')}
                              </button>
                            )
                          )}
                        </div>
                      </div>
                    )}
                  </div>
                );
              })}
            </div>

            <div className="flex space-x-3 pt-2">
              <button
                onClick={() => setStep('welcome')}
                className="px-5 border border-[#e0ddd5] text-[#4a4a48] py-2.5 rounded-lg font-medium hover:bg-[#f0eeeb] transition-colors"
              >
                {t('common.back')}
              </button>
              <button
                onClick={() => setStep('company')}
                disabled={savedCount === 0}
                className="flex-1 bg-primary text-white py-2.5 rounded-lg font-medium hover:bg-primary-hover disabled:opacity-40 transition-colors"
              >
                {savedCount > 0 ? t('onboarding.configuredCount', { count: savedCount }) : t('onboarding.atLeastOneRequired')}
              </button>
            </div>

            {/* AI Key 不是使用门槛（本地记账为核心）：无已存 provider 时提供跳过路径，
                与 company 步骤的 skipCompany 同构；无 Key 时 AI 入口由 aiError.noProvider 引导 */}
            {savedCount === 0 && (
              <button
                onClick={() => setStep('company')}
                className="w-full text-xs text-[#5c5c5a] hover:text-[#4a4a48] py-1"
              >
                {t('onboarding.skipProviders')}
              </button>
            )}
          </div>
        )}

        {step === 'company' && (
          <div className="space-y-5">
            <div>
              <h2 className="text-xl font-semibold text-[#191918] mb-2">{t('onboarding.companyTitle')}</h2>
              <p className="text-sm text-[#6b6b69]">{t('onboarding.companySubtitle')}</p>
            </div>

            <div>
              <label className="block text-xs font-medium text-[#4a4a48] mb-2">{t('onboarding.companyName')}</label>
              <input
                type="text"
                value={companyName}
                onChange={e => setCompanyName(e.target.value)}
                placeholder={t('onboarding.companyNamePlaceholder')}
                className="w-full px-4 py-2.5 border border-[#e0ddd5] rounded-lg text-sm focus:outline-none focus:border-primary focus:ring-2 focus:ring-primary/20"
              />
            </div>

            <div>
              <label className="block text-xs font-medium text-[#4a4a48] mb-2">{t('onboarding.industry')} <span className="text-[#5c5c5a] font-normal">{t('onboarding.optional')}</span></label>
              <input
                type="text"
                value={industry}
                onChange={e => setIndustry(e.target.value)}
                placeholder={t('onboarding.industryPlaceholder')}
                className="w-full px-4 py-2.5 border border-[#e0ddd5] rounded-lg text-sm focus:outline-none focus:border-primary focus:ring-2 focus:ring-primary/20"
              />
            </div>

            {companyError && (
              <div className="text-sm text-rose-600 bg-rose-50 px-4 py-2.5 rounded-lg">{companyError}</div>
            )}

            <div className="flex space-x-3">
              <button
                onClick={() => setStep(__MAS_BUILD__ ? 'locale' : 'providers')}
                className="px-6 border border-[#e0ddd5] text-[#4a4a48] py-2.5 rounded-lg font-medium hover:bg-[#f0eeeb] transition-colors"
              >
                {t('common.back')}
              </button>
              <button
                onClick={finish}
                disabled={companySaving}
                className="flex-1 bg-primary text-white py-2.5 rounded-lg font-medium hover:bg-primary-hover disabled:opacity-50 transition-colors"
              >
                {companySaving ? <><i className="fas fa-spinner fa-spin mr-2"></i>{t('onboarding.saving')}</> : t('onboarding.finishAndEnter')}
              </button>
            </div>

            <button onClick={finish} className="w-full text-xs text-[#5c5c5a] hover:text-[#4a4a48] py-1">
              {t('onboarding.skipCompany')}
            </button>
          </div>
        )}
      </div>
    </div>
  );
};

export default OnboardingWizard;
