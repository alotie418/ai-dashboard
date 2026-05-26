
import React, { useState, useEffect } from 'react';
import { useTranslation } from 'react-i18next';
import { fetchSettings, saveSettings } from '../services/api';
import ProvidersSection from './ProvidersSection';
import LanguageSection from './LanguageSection';
import AccountingSection from './AccountingSection';

const SettingsPage: React.FC = () => {
  const { t } = useTranslation();
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
  const [adminExpenseAnnual, setAdminExpenseAnnual] = useState('0');

  // Password change state
  const [showPasswordModal, setShowPasswordModal] = useState(false);
  const [currentPassword, setCurrentPassword] = useState('');
  const [newPassword, setNewPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [passwordError, setPasswordError] = useState('');
  const [passwordSuccess, setPasswordSuccess] = useState('');
  const [changingPassword, setChangingPassword] = useState(false);

  const handleChangePassword = async () => {
    setPasswordError('');
    setPasswordSuccess('');
    if (!currentPassword || !newPassword || !confirmPassword) {
      setPasswordError('请填写所有密码字段');
      return;
    }
    if (newPassword.length < 6) {
      setPasswordError('新密码至少 6 个字符');
      return;
    }
    if (newPassword !== confirmPassword) {
      setPasswordError('两次输入的新密码不一致');
      return;
    }
    setChangingPassword(true);
    try {
      const res = await fetch('/auth/change-password', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        credentials: 'same-origin',
        body: JSON.stringify({ currentPassword, newPassword }),
      });
      const data = await res.json();
      if (!res.ok) {
        setPasswordError(data.error || '修改失败');
        return;
      }
      setPasswordSuccess('密码修改成功！');
      setCurrentPassword('');
      setNewPassword('');
      setConfirmPassword('');
      setTimeout(() => {
        setShowPasswordModal(false);
        setPasswordSuccess('');
      }, 1500);
    } catch {
      setPasswordError('网络错误，请稍后重试');
    } finally {
      setChangingPassword(false);
    }
  };

  // Apply fetched settings to state
  const applySettings = (s: any) => {
    if (s.company_info) setCompanyInfo(s.company_info);
    if (s.tax_auto_auth !== undefined) setTaxAutoAuth(s.tax_auto_auth);
    if (s.ai_auto_insight !== undefined) setAiAutoInsight(s.ai_auto_insight);
    if (s.notifications) setNotifications(s.notifications);
    if (s.vat_rate !== undefined) setVatRate(String(s.vat_rate));
    if (s.admin_expense_annual !== undefined) setAdminExpenseAnnual(String(s.admin_expense_annual));
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
        admin_expense_annual: parseFloat(adminExpenseAnnual) || 0,
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
          <SettingsNavLink active={activeSection === 'company'} onClick={() => setActiveSection('company')} icon="fa-building" label={t('settings.nav.company')} />
          <SettingsNavLink active={activeSection === 'tax'} onClick={() => setActiveSection('tax')} icon="fa-percent" label={t('settings.nav.tax')} />
          <SettingsNavLink active={activeSection === 'ai'} onClick={() => setActiveSection('ai')} icon="fa-microchip" label={t('settings.nav.ai')} />
          <SettingsNavLink active={activeSection === 'language'} onClick={() => setActiveSection('language')} icon="fa-language" label={t('settings.nav.language')} />
          <SettingsNavLink active={activeSection === 'accounting'} onClick={() => setActiveSection('accounting')} icon="fa-balance-scale" label={t('settings.nav.accounting')} />
          <SettingsNavLink active={activeSection === 'notifications'} onClick={() => setActiveSection('notifications')} icon="fa-bell" label={t('settings.nav.notifications')} />
          <SettingsNavLink active={activeSection === 'security'} onClick={() => setActiveSection('security')} icon="fa-shield-halved" label={t('settings.nav.security')} />
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

                  <div className="p-4 bg-[#f9f9f8]/40 rounded-xl border border-[#e0ddd5] space-y-3">
                    <div>
                      <p className="text-sm font-bold text-[#191918]">年度管理费用</p>
                      <p className="text-xs text-[#5c5c5a]">用于损益表净利润计算（含办公、人工、折旧等）</p>
                    </div>
                    <div className="flex items-center space-x-2">
                      <span className="text-sm text-[#5c5c5a]">¥</span>
                      <input
                        type="number"
                        min="0"
                        step="100"
                        value={adminExpenseAnnual}
                        onChange={e => setAdminExpenseAnnual(e.target.value)}
                        placeholder="0"
                        className="flex-1 bg-white border border-[#d1cdc4] rounded-lg px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-[#d97757] text-[#191918]"
                      />
                      <span className="text-xs text-[#5c5c5a]">元/年</span>
                    </div>
                    <p className="text-[10px] text-[#8a8a88]">提示：税金及附加按增值税12%自动计算，所得税按利润总额25%自动计算</p>
                  </div>
                </div>
              </section>
            )}

            {!isLoading && !loadError && activeSection === 'ai' && (
              <div className="space-y-8">
                <ProvidersSection />
                <div className="flex items-center justify-between p-4 bg-[#f9f9f8]/40 rounded-xl border border-[#e0ddd5]">
                  <div>
                    <p className="text-sm font-bold text-[#191918]">{t('settings.ai.autoInsight.title')}</p>
                    <p className="text-xs text-[#5c5c5a]">{t('settings.ai.autoInsight.subtitle')}</p>
                  </div>
                  <ToggleButton checked={aiAutoInsight} onChange={setAiAutoInsight} />
                </div>
              </div>
            )}

            {!isLoading && !loadError && activeSection === 'language' && <LanguageSection />}
            {!isLoading && !loadError && activeSection === 'accounting' && <AccountingSection />}

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
              <section className="space-y-6">
                <h3 className="text-xl font-bold text-[#191918] mb-6">账户与安全</h3>
                <div className="space-y-4">
                  <div className="flex items-center justify-between p-5 bg-[#f9f9f8]/40 rounded-xl border border-[#e0ddd5]">
                    <div>
                      <p className="text-sm font-bold text-[#191918]">登录密码</p>
                      <p className="text-xs text-[#5c5c5a]">定期修改密码以确保账户安全</p>
                    </div>
                    <button
                      onClick={() => { setShowPasswordModal(true); setPasswordError(''); setPasswordSuccess(''); setCurrentPassword(''); setNewPassword(''); setConfirmPassword(''); }}
                      className="px-5 py-2 bg-[#d97757] hover:bg-[#c56a4a] text-white text-sm font-medium rounded-xl transition-all active:scale-95"
                    >
                      修改密码
                    </button>
                  </div>
                  <div className="p-5 bg-[#f9f9f8]/40 rounded-xl border border-[#e0ddd5]">
                    <p className="text-sm font-bold text-[#191918] mb-1">数据加密</p>
                    <p className="text-xs text-[#5c5c5a]">所有数据传输均通过 HTTPS 加密，Session Cookie 启用 HttpOnly + Secure + SameSite 防护。</p>
                  </div>
                </div>

                {/* Password Change Modal */}
                {showPasswordModal && (
                  <div className="fixed inset-0 z-[10001] flex items-center justify-center bg-black/30" onClick={() => setShowPasswordModal(false)}>
                    <div className="bg-white rounded-2xl border border-[#e0ddd5] p-8 w-full max-w-sm" style={{ boxShadow: '0 8px 32px rgba(0,0,0,0.12)' }} onClick={e => e.stopPropagation()}>
                      <h4 className="text-lg font-bold text-[#191918] mb-6">修改登录密码</h4>
                      <div className="space-y-4">
                        <div>
                          <label className="block text-xs font-medium text-[#4a4a48] mb-1.5">当前密码</label>
                          <input type="password" value={currentPassword} onChange={e => setCurrentPassword(e.target.value)} className="w-full px-4 py-3 bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl text-sm outline-none focus:border-[#d97757] transition-colors" autoComplete="current-password" />
                        </div>
                        <div>
                          <label className="block text-xs font-medium text-[#4a4a48] mb-1.5">新密码</label>
                          <input type="password" value={newPassword} onChange={e => setNewPassword(e.target.value)} className="w-full px-4 py-3 bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl text-sm outline-none focus:border-[#d97757] transition-colors" autoComplete="new-password" />
                        </div>
                        <div>
                          <label className="block text-xs font-medium text-[#4a4a48] mb-1.5">确认新密码</label>
                          <input type="password" value={confirmPassword} onChange={e => setConfirmPassword(e.target.value)} className="w-full px-4 py-3 bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl text-sm outline-none focus:border-[#d97757] transition-colors" autoComplete="new-password" />
                        </div>
                        {passwordError && <p className="text-sm text-red-600 bg-red-50 border border-red-200 rounded-lg px-4 py-2">{passwordError}</p>}
                        {passwordSuccess && <p className="text-sm text-emerald-600 bg-emerald-50 border border-emerald-200 rounded-lg px-4 py-2">{passwordSuccess}</p>}
                      </div>
                      <div className="flex space-x-3 mt-6">
                        <button onClick={() => setShowPasswordModal(false)} className="flex-1 py-3 bg-[#f9f9f8] text-[#4a4a48] border border-[#e0ddd5] rounded-xl text-sm font-medium hover:bg-[#f0eeeb] transition-all">取消</button>
                        <button onClick={handleChangePassword} disabled={changingPassword} className="flex-1 py-3 bg-[#d97757] text-white rounded-xl text-sm font-medium hover:bg-[#c56a4a] disabled:opacity-40 transition-all">
                          {changingPassword ? <><i className="fas fa-spinner fa-spin mr-2"></i>修改中...</> : '确认修改'}
                        </button>
                      </div>
                    </div>
                  </div>
                )}
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
