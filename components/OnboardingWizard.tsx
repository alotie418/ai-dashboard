import React, { useEffect, useState } from 'react';
import type { AIProviderConfig, AIProviderId } from '../types';
import { listProviders, saveProvider, setDefaultProvider, testProvider } from '../services/api';
import { KNOWN_MODELS, DEFAULT_MODEL } from './aiProviderModels';

interface Props {
  onComplete: () => void;
}

type Step = 'welcome' | 'providers' | 'company';

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
    color: '#d97757',
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
};

const OnboardingWizard: React.FC<Props> = ({ onComplete }) => {
  const [step, setStep] = useState<Step>('welcome');
  const [providers, setProviders] = useState<AIProviderConfig[]>([]);
  const [forms, setForms] = useState<Record<AIProviderId, ProviderFormState>>({} as any);
  const [expandedProvider, setExpandedProvider] = useState<AIProviderId | null>(null);
  const [defaultProvider, setDefaultProviderState] = useState<AIProviderId | null>(null);

  const [companyName, setCompanyName] = useState('');
  const [industry, setIndustry] = useState('');
  const [companySaving, setCompanySaving] = useState(false);
  const [companyError, setCompanyError] = useState('');
  const [loadError, setLoadError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  // 初始加载所有 provider 元信息
  useEffect(() => {
    listProviders().then(list => {
      console.log('[renderer providers:list]', list);
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
          errorMsg: r.error || r.providerMessage || '连接失败',
          errorStatus: r.status,
          errorCode: r.code,
          testing: false,
        });
      }
    } catch (e: any) {
      updateForm(id, { testResult: 'fail', errorMsg: e?.message || '连接失败', testing: false });
    }
  };

  const handleSave = async (id: AIProviderId) => {
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
      updateForm(id, { errorMsg: e?.message || '保存失败', saving: false });
    }
  };

  const handleSetDefault = async (id: AIProviderId) => {
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
      setCompanyError(e?.message || '保存失败');
    } finally {
      setCompanySaving(false);
    }
  };

  return (
    <div className="min-h-screen flex items-center justify-center bg-[#f9f9f8] px-6 py-8">
      <div className="w-full max-w-2xl bg-white border border-[#e0ddd5] rounded-2xl p-10" style={{ boxShadow: '0 8px 48px rgba(0,0,0,0.06)' }}>
        {/* Logo */}
        <div className="flex items-center justify-center mb-7">
          <div className="w-12 h-12 bg-[#d97757] rounded-xl flex items-center justify-center mr-3 shadow-lg" style={{ boxShadow: '0 4px 24px rgba(217,119,87,0.2)' }}>
            <i className="fas fa-layer-group text-white text-xl"></i>
          </div>
          <div>
            <h1 className="text-2xl font-bold text-[#191918] tracking-tight">SoloLedger</h1>
            <p className="text-xs text-[#6b6b69]">独账 · 一人公司的智能账本</p>
          </div>
        </div>

        {/* Progress dots */}
        <div className="flex items-center justify-center mb-8 space-x-2">
          {(['welcome', 'providers', 'company'] as Step[]).map((s, i) => (
            <React.Fragment key={s}>
              <div className={`w-2 h-2 rounded-full transition-all ${s === step ? 'bg-[#d97757] w-6' : (['welcome', 'providers', 'company'].indexOf(step) > i ? 'bg-[#d97757]/40' : 'bg-[#e0ddd5]')}`}></div>
              {i < 2 && <div className="w-4 h-px bg-[#e0ddd5]"></div>}
            </React.Fragment>
          ))}
        </div>

        {step === 'welcome' && (
          <div className="space-y-6">
            <h2 className="text-xl font-semibold text-[#191918]">欢迎使用 SoloLedger</h2>
            <p className="text-sm text-[#4a4a48] leading-relaxed">
              SoloLedger 是为一人公司、个体户和 Solo SaaS 创始人打造的智能账本应用。所有数据存储在本地，AI 能力由你自带的 API Key 驱动 — 我们看不到你的任何数据。
            </p>
            <ul className="space-y-3 text-sm text-[#4a4a48]">
              <li className="flex items-start">
                <i className="fas fa-shield-alt text-[#d97757] mt-1 mr-3 w-4 text-center"></i>
                <span>本地 SQLite 存储，所有数据存在你的 Mac 上</span>
              </li>
              <li className="flex items-start">
                <i className="fas fa-key text-[#d97757] mt-1 mr-3 w-4 text-center"></i>
                <span>支持 <b>Claude</b> · <b>ChatGPT</b> · <b>Gemini</b>，可配置多个，按需切换默认</span>
              </li>
              <li className="flex items-start">
                <i className="fas fa-lock text-[#d97757] mt-1 mr-3 w-4 text-center"></i>
                <span>API Key 使用系统 Keychain 加密，永远不离开你的设备</span>
              </li>
              <li className="flex items-start">
                <i className="fas fa-cloud-download-alt text-[#d97757] mt-1 mr-3 w-4 text-center"></i>
                <span>支持发票 OCR、经营分析、智能告警、应收应付管理</span>
              </li>
            </ul>
            <button
              onClick={() => setStep('providers')}
              className="w-full bg-[#d97757] text-white py-3 rounded-lg font-medium hover:bg-[#c4694d] transition-colors"
            >
              开始配置
            </button>
          </div>
        )}

        {step === 'providers' && (
          <div className="space-y-5">
            <div>
              <h2 className="text-xl font-semibold text-[#191918] mb-2">配置 AI 服务商</h2>
              <p className="text-sm text-[#6b6b69]">至少配置一个即可开始使用。配置多个时可在设置中切换默认。</p>
            </div>

            {loading && (
              <div className="flex items-center justify-center py-10 text-sm text-[#6b6b69]">
                <i className="fas fa-spinner fa-spin mr-2 text-[#d97757]"></i>正在加载 Provider 列表...
              </div>
            )}

            {loadError && (
              <div className="bg-rose-50 border border-rose-200 rounded-lg p-4 text-sm text-rose-700">
                <div className="font-medium mb-1"><i className="fas fa-exclamation-triangle mr-2"></i>无法加载 AI 服务商配置</div>
                <div className="text-xs break-all">{loadError}</div>
                <div className="text-xs mt-2 text-rose-600">如果你刚刚升级了 SoloLedger，请完全退出应用（Cmd+Q）后重新启动。</div>
              </div>
            )}

            {!loading && !loadError && providers.length === 0 && (
              <div className="bg-amber-50 border border-amber-200 rounded-lg p-4 text-sm text-amber-700">
                Provider 列表为空。请完全退出 SoloLedger（Cmd+Q）后重新启动。
              </div>
            )}

            <div className="space-y-3">
              {providers.map(p => {
                const doc = PROVIDER_DOCS[p.provider];
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
                        <div className="w-9 h-9 rounded-lg flex items-center justify-center mr-3" style={{ backgroundColor: `${doc.color}15`, color: doc.color }}>
                          <i className={`fas ${doc.icon}`}></i>
                        </div>
                        <div>
                          <div className="text-sm font-semibold text-[#191918]">{doc.label}</div>
                          <div className="text-[11px] text-[#7a7a78]">
                            {form.saved ? '✓ 已保存' : '点击展开配置'}
                            {p.supportsTTS && <span className="ml-2 text-[#d97757]">支持 TTS</span>}
                          </div>
                        </div>
                      </div>
                      <div className="flex items-center space-x-2">
                        {form.saved && defaultProvider === p.provider && (
                          <span className="text-[10px] font-bold bg-[#d97757] text-white px-2 py-1 rounded uppercase">默认</span>
                        )}
                        <i className={`fas fa-chevron-${expanded ? 'up' : 'down'} text-[#7a7a78] text-xs`}></i>
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
                            className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm focus:outline-none focus:border-[#d97757] focus:ring-2 focus:ring-[#d97757]/20"
                          />
                          <a href={doc.getKeyUrl} target="_blank" rel="noreferrer" className="inline-flex items-center text-[11px] mt-1.5 hover:underline" style={{ color: doc.color }}>
                            <i className="fas fa-external-link-alt mr-1 text-[9px]"></i>
                            如何获取 {doc.label} Key
                          </a>
                        </div>

                        <div>
                          <label className="block text-xs font-medium text-[#4a4a48] mb-2">模型选择</label>
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
                            <summary className="text-[#7a7a78] cursor-pointer hover:text-[#4a4a48] select-none">
                              <i className="fas fa-code text-[10px] mr-1"></i>
                              高级：手动输入 model ID
                            </summary>
                            <input
                              type="text"
                              value={form.model}
                              onChange={e => updateForm(p.provider, { model: e.target.value, testResult: null })}
                              placeholder={p.defaultModel}
                              className="w-full mt-2 px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm bg-white focus:outline-none focus:border-[#d97757] font-mono"
                            />
                            <p className="text-[10px] text-[#7a7a78] mt-1">
                              当前传给 API 的 model ID: <code className="bg-[#f0eeeb] px-1.5 py-0.5 rounded">{form.model}</code>
                            </p>
                          </details>
                        </div>

                        {form.testResult === 'ok' && (
                          <div className="flex items-center text-xs text-emerald-600 bg-emerald-50 px-3 py-2 rounded-lg">
                            <i className="fas fa-check-circle mr-2"></i>
                            模型可调用，Key 与 model ID 均通过
                          </div>
                        )}
                        {form.testResult === 'fail' && (
                          <div className="flex items-start text-xs text-rose-600 bg-rose-50 px-3 py-2 rounded-lg">
                            <i className="fas fa-exclamation-circle mr-2 mt-0.5"></i>
                            <div className="flex-1">
                              <div className="font-medium">
                                测试失败
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
                            {form.testing ? <><i className="fas fa-spinner fa-spin mr-1.5"></i>测试中</> : '测试连接'}
                          </button>
                          {!form.saved ? (
                            <button
                              onClick={() => handleSave(p.provider)}
                              disabled={!form.apiKey.trim() || form.saving}
                              className="flex-1 text-white py-2 rounded-lg text-sm font-medium disabled:opacity-50 transition-colors"
                              style={{ backgroundColor: doc.color }}
                            >
                              {form.saving ? <><i className="fas fa-spinner fa-spin mr-1.5"></i>保存中</> : '保存'}
                            </button>
                          ) : (
                            defaultProvider !== p.provider && (
                              <button
                                onClick={() => handleSetDefault(p.provider)}
                                className="flex-1 text-[#d97757] border border-[#d97757] py-2 rounded-lg text-sm font-medium hover:bg-[#d97757]/5 transition-colors"
                              >
                                设为默认
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
                上一步
              </button>
              <button
                onClick={() => setStep('company')}
                disabled={savedCount === 0}
                className="flex-1 bg-[#d97757] text-white py-2.5 rounded-lg font-medium hover:bg-[#c4694d] disabled:opacity-40 transition-colors"
              >
                {savedCount > 0 ? `下一步（已配置 ${savedCount} 个）` : '至少配置一个服务商'}
              </button>
            </div>
          </div>
        )}

        {step === 'company' && (
          <div className="space-y-5">
            <div>
              <h2 className="text-xl font-semibold text-[#191918] mb-2">填写公司信息</h2>
              <p className="text-sm text-[#6b6b69]">用于 AI 分析时提供企业上下文，可随时在系统设置里修改。</p>
            </div>

            <div>
              <label className="block text-xs font-medium text-[#4a4a48] mb-2">公司名称</label>
              <input
                type="text"
                value={companyName}
                onChange={e => setCompanyName(e.target.value)}
                placeholder="例如：上海独角兽贸易有限公司"
                className="w-full px-4 py-2.5 border border-[#e0ddd5] rounded-lg text-sm focus:outline-none focus:border-[#d97757] focus:ring-2 focus:ring-[#d97757]/20"
              />
            </div>

            <div>
              <label className="block text-xs font-medium text-[#4a4a48] mb-2">所属行业 <span className="text-[#7a7a78] font-normal">（可选）</span></label>
              <input
                type="text"
                value={industry}
                onChange={e => setIndustry(e.target.value)}
                placeholder="例如：化工贸易 / 软件开发 / 设计咨询"
                className="w-full px-4 py-2.5 border border-[#e0ddd5] rounded-lg text-sm focus:outline-none focus:border-[#d97757] focus:ring-2 focus:ring-[#d97757]/20"
              />
            </div>

            {companyError && (
              <div className="text-sm text-rose-600 bg-rose-50 px-4 py-2.5 rounded-lg">{companyError}</div>
            )}

            <div className="flex space-x-3">
              <button
                onClick={() => setStep('providers')}
                className="px-6 border border-[#e0ddd5] text-[#4a4a48] py-2.5 rounded-lg font-medium hover:bg-[#f0eeeb] transition-colors"
              >
                上一步
              </button>
              <button
                onClick={finish}
                disabled={companySaving}
                className="flex-1 bg-[#d97757] text-white py-2.5 rounded-lg font-medium hover:bg-[#c4694d] disabled:opacity-50 transition-colors"
              >
                {companySaving ? <><i className="fas fa-spinner fa-spin mr-2"></i>保存中</> : '完成并进入应用'}
              </button>
            </div>

            <button onClick={finish} className="w-full text-xs text-[#7a7a78] hover:text-[#4a4a48] py-1">
              暂时跳过公司信息，稍后在设置中填写
            </button>
          </div>
        )}
      </div>
    </div>
  );
};

export default OnboardingWizard;
