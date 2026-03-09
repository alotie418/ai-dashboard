
import React, { useState, useEffect } from 'react';
import { fetchSettings, saveSettings } from '../services/api';

const SettingsPage: React.FC = () => {
  const [activeSection, setActiveSection] = useState('company');
  const [isSaving, setIsSaving] = useState(false);
  const [isLoading, setIsLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [saveMessage, setSaveMessage] = useState<{ type: 'success' | 'error'; text: string } | null>(null);

  // Lifted state for all settings — empty defaults, populated from API
  const [companyInfo, setCompanyInfo] = useState({
    name: '',
    creditCode: '',
    legalPerson: '',
    industry: '',
    address: '',
  });
  const [taxAutoAuth, setTaxAutoAuth] = useState(false);
  const [aiAutoInsight, setAiAutoInsight] = useState(true);
  const [notifications, setNotifications] = useState({
    stockZero: true,
    taxDeviation: true,
    priceVolatility: false,
    monthlyReport: true,
  });
  const [vatRate, setVatRate] = useState('13');
  const [aiModel, setAiModel] = useState('gemini-3.1-pro');

  // Apply fetched settings to state
  const applySettings = (s: any) => {
    if (s.company_info) setCompanyInfo(s.company_info);
    if (s.tax_auto_auth !== undefined) setTaxAutoAuth(s.tax_auto_auth);
    if (s.ai_auto_insight !== undefined) setAiAutoInsight(s.ai_auto_insight);
    if (s.notifications) setNotifications(s.notifications);
    if (s.vat_rate !== undefined) setVatRate(String(s.vat_rate));
    if (s.ai_model !== undefined) setAiModel(s.ai_model);
  };

  // Load settings from API on mount
  useEffect(() => {
    setLoadError(null);
    fetchSettings()
      .then(applySettings)
      .catch((err) => {
        console.error('Failed to load settings:', err);
        setLoadError(`加载设置失败：${err.message || '网络错误'}`);
      })
      .finally(() => setIsLoading(false));
  }, []);

  const handleSave = async () => {
    setIsSaving(true);
    setSaveMessage(null);
    try {
      const payload = {
        company_info: companyInfo,
        tax_auto_auth: taxAutoAuth,
        ai_auto_insight: aiAutoInsight,
        notifications,
        vat_rate: vatRate,
        ai_model: aiModel,
      };
      await saveSettings(payload);

      // Re-fetch to confirm persistence
      const verified = await fetchSettings();
      applySettings(verified);

      setSaveMessage({ type: 'success', text: '设置已成功保存！' });
      setTimeout(() => setSaveMessage(null), 3000);
    } catch (err: any) {
      console.error(err);
      setSaveMessage({ type: 'error', text: `保存失败：${err.message || '请重试'}` });
    } finally {
      setIsSaving(false);
    }
  };

  return (
    <div className="max-w-5xl mx-auto animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="flex flex-col md:flex-row gap-8">
        {/* Sidebar Nav */}
        <div className="w-full md:w-64 space-y-2">
          <SettingsNavLink
            active={activeSection === 'company'}
            onClick={() => setActiveSection('company')}
            icon="fa-building"
            label="企业基础信息"
          />
          <SettingsNavLink
            active={activeSection === 'tax'}
            onClick={() => setActiveSection('tax')}
            icon="fa-percent"
            label="税务规则配置"
          />
          <SettingsNavLink
            active={activeSection === 'ai'}
            onClick={() => setActiveSection('ai')}
            icon="fa-microchip"
            label="AI 引擎偏好"
          />
          <SettingsNavLink
            active={activeSection === 'notifications'}
            onClick={() => setActiveSection('notifications')}
            icon="fa-bell"
            label="预警与通知"
          />
          <SettingsNavLink
            active={activeSection === 'security'}
            onClick={() => setActiveSection('security')}
            icon="fa-shield-halved"
            label="账户与安全"
          />
        </div>

        {/* Content Area */}
        <div className="flex-1 space-y-6">
          {/* Toast notification */}
          {saveMessage && (
            <div className={`px-5 py-3 rounded-xl text-sm font-medium flex items-center justify-between transition-all animate-in fade-in slide-in-from-top-2 duration-300 ${saveMessage.type === 'success' ? 'bg-emerald-50 text-emerald-700 border border-emerald-200' : 'bg-red-50 text-red-700 border border-red-200'}`}>
              <span>
                <i className={`fas ${saveMessage.type === 'success' ? 'fa-check-circle' : 'fa-exclamation-circle'} mr-2`}></i>
                {saveMessage.text}
              </span>
              <button onClick={() => setSaveMessage(null)} className="ml-4 opacity-50 hover:opacity-100">
                <i className="fas fa-times"></i>
              </button>
            </div>
          )}

          <div className="bg-white/80 border border-[#e0ddd5] rounded-xl p-8" style={{boxShadow: '0 4px 24px rgba(0,0,0,0.05)'}}>
            {/* Loading state */}
            {isLoading && (
              <div className="flex flex-col items-center justify-center py-16 space-y-4">
                <div className="w-10 h-10 border-3 border-[#d97757]/20 border-t-[#d97757] rounded-full animate-spin"></div>
                <p className="text-sm text-[#5c5c5a]">正在加载设置...</p>
              </div>
            )}

            {/* Load error state */}
            {!isLoading && loadError && (
              <div className="flex flex-col items-center justify-center py-16 space-y-4">
                <div className="w-14 h-14 bg-red-50 rounded-full flex items-center justify-center">
                  <i className="fas fa-exclamation-triangle text-red-400 text-xl"></i>
                </div>
                <p className="text-sm text-red-600 font-medium">{loadError}</p>
                <button
                  onClick={() => {
                    setIsLoading(true);
                    setLoadError(null);
                    fetchSettings()
                      .then(applySettings)
                      .catch((err) => setLoadError(`加载失败：${err.message || '网络错误'}`))
                      .finally(() => setIsLoading(false));
                  }}
                  className="px-5 py-2 bg-[#f9f9f8] hover:bg-[#f0eeeb] text-[#191918] border border-[#e0ddd5] rounded-xl text-sm transition-all"
                >
                  <i className="fas fa-redo mr-2"></i>重试
                </button>
              </div>
            )}

            {!isLoading && !loadError && activeSection === 'company' && (
              <section className="space-y-6">
                <h3 className="text-xl font-bold text-[#191918] mb-6">企业基础信息</h3>
                <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                  <InputGroup label="企业全称" placeholder="AI Dashboard 贸易有限公司" value={companyInfo.name} onChange={(v) => setCompanyInfo(prev => ({ ...prev, name: v }))} />
                  <InputGroup label="统一社会信用代码" placeholder="91110000XXXXXXXXXX" value={companyInfo.creditCode} onChange={(v) => setCompanyInfo(prev => ({ ...prev, creditCode: v }))} />
                  <InputGroup label="法定代表人" placeholder="张晓明" value={companyInfo.legalPerson} onChange={(v) => setCompanyInfo(prev => ({ ...prev, legalPerson: v }))} />
                  <InputGroup label="所属行业" placeholder="通用贸易 / 供应链" value={companyInfo.industry} onChange={(v) => setCompanyInfo(prev => ({ ...prev, industry: v }))} />
                </div>
                <div className="pt-4">
                  <InputGroup label="注册地址" placeholder="北京市朝阳区..." value={companyInfo.address} onChange={(v) => setCompanyInfo(prev => ({ ...prev, address: v }))} />
                </div>
              </section>
            )}

            {!isLoading && !loadError && activeSection === 'tax' && (
              <section className="space-y-6">
                <h3 className="text-xl font-bold text-[#191918] mb-6">税务规则配置</h3>
                <div className="space-y-4">
                  <div className="flex items-center justify-between p-4 bg-[#f9f9f8]/40 rounded-xl border border-[#e0ddd5]">
                    <div>
                      <p className="text-sm font-bold text-[#191918]">增值税标准税率 (VAT)</p>
                      <p className="text-xs text-[#5c5c5a]">用于 OCR 识别和财务预测的默认计算标准</p>
                    </div>
                    <select value={vatRate} onChange={e => setVatRate(e.target.value)} className="bg-white border border-[#d1cdc4] rounded-lg px-3 py-1 text-sm outline-none">
                      <option value="13">13% (标准货物)</option>
                      <option value="9">9% (农产品/交通)</option>
                      <option value="6">6% (服务业)</option>
                    </select>
                  </div>
                  <div className="flex items-center justify-between p-4 bg-[#f9f9f8]/40 rounded-xl border border-[#e0ddd5]">
                    <div>
                      <p className="text-sm font-bold text-[#191918]">进项发票自动认证</p>
                      <p className="text-xs text-[#5c5c5a]">上传后自动同步至税务系统进行认证</p>
                    </div>
                    <ToggleButton checked={taxAutoAuth} onChange={setTaxAutoAuth} />
                  </div>
                </div>
              </section>
            )}

            {!isLoading && !loadError && activeSection === 'ai' && (
              <section className="space-y-6">
                <h3 className="text-xl font-bold text-[#191918] mb-6">AI 引擎偏好</h3>
                <div className="grid grid-cols-1 gap-4">
                  <div className="p-5 border border-[#d97757]/30 bg-[#d97757]/5 rounded-xl">
                    <div className="flex items-center justify-between mb-2">
                      <span className="text-sm font-bold text-[#d97757]">分析模型选择</span>
                      <span className="text-[10px] font-bold bg-[#d97757] px-2 py-0.5 rounded text-white uppercase">PREVIEW</span>
                    </div>
                    <select value={aiModel} onChange={e => setAiModel(e.target.value)} className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:ring-2 focus:ring-[#d97757] outline-none">
                      <option value="gemini-3-pro">Gemini 3 Pro (推荐 - 高精度分析)</option>
                      <option value="gemini-3.1-pro">Gemini 3.1 Pro (增强版 - 更强推理)</option>
                      <option value="gemini-3-flash">Gemini 3 Flash (响应极快 - 轻量任务)</option>
                    </select>
                  </div>
                  <div className="flex items-center justify-between p-4 bg-[#f9f9f8]/40 rounded-xl border border-[#e0ddd5]">
                    <div>
                      <p className="text-sm font-bold text-[#191918]">自主洞察生成</p>
                      <p className="text-xs text-[#5c5c5a]">看板加载时自动运行 AI 分析</p>
                    </div>
                    <ToggleButton checked={aiAutoInsight} onChange={setAiAutoInsight} />
                  </div>
                </div>
              </section>
            )}

            {!isLoading && !loadError && activeSection === 'notifications' && (
              <section className="space-y-6">
                <h3 className="text-xl font-bold text-[#191918] mb-6">预警与通知</h3>
                <div className="space-y-4">
                  <NotificationToggle label="库存跌至零值提醒" checked={notifications.stockZero} onChange={(v) => setNotifications(prev => ({ ...prev, stockZero: v }))} />
                  <NotificationToggle label="税收偏差超过 15% 预警" checked={notifications.taxDeviation} onChange={(v) => setNotifications(prev => ({ ...prev, taxDeviation: v }))} />
                  <NotificationToggle label="异常价格波动监测" checked={notifications.priceVolatility} onChange={(v) => setNotifications(prev => ({ ...prev, priceVolatility: v }))} />
                  <NotificationToggle label="月度财务报告推送" checked={notifications.monthlyReport} onChange={(v) => setNotifications(prev => ({ ...prev, monthlyReport: v }))} />
                </div>
              </section>
            )}

            {!isLoading && !loadError && activeSection === 'security' && (
              <section className="space-y-6 text-center py-10">
                <div className="w-16 h-16 bg-[#f9f9f8] rounded-full flex items-center justify-center mx-auto mb-4 border border-[#e0ddd5]">
                  <i className="fas fa-lock text-[#5c5c5a] text-2xl"></i>
                </div>
                <h3 className="text-lg font-bold text-[#191918]">账户安全性</h3>
                <p className="text-[#5c5c5a] text-sm mb-6 max-w-xs mx-auto">您的数据已通过行业标准 AES-256 加密，仅限授权管理员访问。</p>
                <button className="px-6 py-2 bg-[#f9f9f8] hover:bg-[#f0eeeb] text-[#191918] border border-[#e0ddd5] rounded-xl text-sm transition-all">
                  修改登录密码
                </button>
              </section>
            )}

            {!isLoading && !loadError && (
              <div className="mt-10 pt-6 border-t border-[#e0ddd5] flex justify-end">
                <button
                  onClick={handleSave}
                  disabled={isSaving}
                  className="px-10 py-3 bg-[#d97757] hover:bg-[#c56a4a] text-white font-bold rounded-xl transition-all active:scale-95 disabled:opacity-50 flex items-center" style={{boxShadow: '0 4px 16px rgba(217,119,87,0.15)'}}
                >
                  {isSaving ? <i className="fas fa-spinner animate-spin mr-2"></i> : <i className="fas fa-save mr-2"></i>}
                  保存更改
                </button>
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
};

const SettingsNavLink: React.FC<{ active: boolean, onClick: () => void, icon: string, label: string }> = ({ active, onClick, icon, label }) => (
  <button
    onClick={onClick}
    className={`w-full flex items-center px-6 py-4 rounded-xl transition-all border ${active ? 'bg-[#d97757] text-white border-[#d97757]' : 'bg-white/80 text-[#4a4a48] border-[#e0ddd5] hover:bg-[#f9f9f8] hover:text-[#191918]'}`}
    style={active ? {boxShadow: '0 4px 16px rgba(217,119,87,0.15)'} : {}}
  >
    <i className={`fas ${icon} mr-4 w-5 text-center`}></i>
    <span className="text-sm font-bold">{label}</span>
  </button>
);

const InputGroup: React.FC<{ label: string, placeholder: string, value: string, onChange: (v: string) => void }> = ({ label, placeholder, value, onChange }) => (
  <div className="space-y-2">
    <label className="text-xs font-bold text-[#5c5c5a] uppercase tracking-widest">{label}</label>
    <input
      type="text"
      placeholder={placeholder}
      value={value}
      onChange={(e) => onChange(e.target.value)}
      className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-[#d97757] text-[#191918] transition-all"
    />
  </div>
);

const ToggleButton: React.FC<{ checked: boolean, onChange: (v: boolean) => void }> = ({ checked, onChange }) => (
  <button
    onClick={() => onChange(!checked)}
    className={`w-12 h-6 rounded-full relative transition-colors ${checked ? 'bg-[#d97757]' : 'bg-[#e0ddd5]'}`}
  >
    <div className={`absolute top-1 w-4 h-4 bg-white rounded-full transition-all ${checked ? 'left-7' : 'left-1'}`}></div>
  </button>
);

const NotificationToggle: React.FC<{ label: string, checked: boolean, onChange: (v: boolean) => void }> = ({ label, checked, onChange }) => (
  <div className="flex items-center justify-between p-4 bg-[#f9f9f8]/40 rounded-xl border border-[#e0ddd5]">
    <span className="text-sm text-[#191918]">{label}</span>
    <ToggleButton checked={checked} onChange={onChange} />
  </div>
);

export default SettingsPage;
