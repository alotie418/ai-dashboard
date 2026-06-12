
import React, { useState, useEffect } from 'react';
import { useTranslation } from 'react-i18next';
import { fetchSettings, saveSettings } from '../services/api';
import { getTaxLabel, getCurrencySymbol } from './accountingHelpers';
import ProvidersSection from './ProvidersSection';
import LanguageSection from './LanguageSection';
import AccountingSection from './AccountingSection';
import CategoriesSection from './CategoriesSection';
import ProductsSection from './ProductsSection';
import DataMigrationSection from './DataMigrationSection';
import DataBackupSection from './DataBackupSection';

const SettingsPage: React.FC = () => {
  const { t, i18n } = useTranslation();
  const [activeSection, setActiveSection] = useState('company');
  const [accLocale, setAccLocale] = useState('CN');
  // Every non-CN accountingLocale (US/JP/KR/TW/EU) shows its own regime framing
  // (tax-ID field, tax-rate label, currency, owner/operator wording) from the
  // accounting-locale taxConcepts; only CN keeps the China-GAAP settings.* i18n
  // values (统一社会信用代码 / 法定代表人 / 增值税 / 进项认证 / 税金及附加). usLabel(taxKey,
  // i18nKey) returns the locale taxConcept when non-CN, else the default i18n value.
  const usLabel = (taxKey: string, i18nKey: string) => accLocale !== 'CN' ? getTaxLabel(accLocale, i18n.language, taxKey) : t(i18nKey);
  // For hardcoded (non-i18n) placeholders: locale taxConcept when non-CN, else the literal fallback.
  const usPh = (taxKey: string, fallback: string) => accLocale !== 'CN' ? getTaxLabel(accLocale, i18n.language, taxKey) : fallback;
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
      setPasswordError(t('settings.security.errorAllFields'));
      return;
    }
    if (newPassword.length < 6) {
      setPasswordError(t('settings.security.errorMinLength'));
      return;
    }
    if (newPassword !== confirmPassword) {
      setPasswordError(t('settings.security.errorMismatch'));
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
        setPasswordError(data.error || t('settings.security.errorChangeFailed'));
        return;
      }
      setPasswordSuccess(t('settings.security.passwordChanged'));
      setCurrentPassword('');
      setNewPassword('');
      setConfirmPassword('');
      setTimeout(() => {
        setShowPasswordModal(false);
        setPasswordSuccess('');
      }, 1500);
    } catch {
      setPasswordError(t('settings.security.errorNetwork'));
    } finally {
      setChangingPassword(false);
    }
  };

  // Apply fetched settings to state
  const applySettings = (s: any) => {
    if (s.accounting_locale) setAccLocale(s.accounting_locale);
    if (s.company_info) setCompanyInfo(s.company_info);
    if (s.tax_auto_auth !== undefined) setTaxAutoAuth(s.tax_auto_auth);
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
        setLoadError(t('settings.loadError', { msg: err.message || t('common.error') }));
      })
      .finally(() => setIsLoading(false));
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const handleSave = async () => {
    setIsSaving(true);
    setSaveMessage(null);
    try {
      const payload = {
        company_info: companyInfo,
        tax_auto_auth: taxAutoAuth,
        notifications,
        vat_rate: vatRate,
        admin_expense_annual: parseFloat(adminExpenseAnnual) || 0,
      };
      await saveSettings(payload);

      // Re-fetch to confirm persistence
      const verified = await fetchSettings();
      applySettings(verified);

      setSaveMessage({ type: 'success', text: t('settings.savedToast') });
      setTimeout(() => setSaveMessage(null), 3000);
    } catch (err: any) {
      console.error(err);
      setSaveMessage({ type: 'error', text: t('settings.saveError', { msg: err.message || t('common.retry') }) });
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
          <SettingsNavLink active={activeSection === 'ai'} onClick={() => setActiveSection('ai')} icon="fa-microchip" label={usLabel('setNavAi', 'settings.nav.ai')} />
          <SettingsNavLink active={activeSection === 'language'} onClick={() => setActiveSection('language')} icon="fa-language" label={t('settings.nav.language')} />
          <SettingsNavLink active={activeSection === 'accounting'} onClick={() => setActiveSection('accounting')} icon="fa-balance-scale" label={t('settings.nav.accounting')} />
          <SettingsNavLink active={activeSection === 'categories'} onClick={() => setActiveSection('categories')} icon="fa-tags" label={t('settings.nav.categories')} />
          <SettingsNavLink active={activeSection === 'products'} onClick={() => setActiveSection('products')} icon="fa-box" label={t('settings.nav.products')} />
          <SettingsNavLink active={activeSection === 'dataMigration'} onClick={() => setActiveSection('dataMigration')} icon="fa-database" label={t('settings.nav.dataMigration')} />
          <SettingsNavLink active={activeSection === 'dataBackup'} onClick={() => setActiveSection('dataBackup')} icon="fa-box-archive" label={t('settings.nav.dataBackup')} />
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
                <div className="w-10 h-10 border-3 border-primary/20 border-t-primary rounded-full animate-spin"></div>
                <p className="text-sm text-[#5c5c5a]">{t('settings.loadingHint')}</p>
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
                      .catch((err) => setLoadError(t('settings.loadError', { msg: err.message || t('common.error') })))
                      .finally(() => setIsLoading(false));
                  }}
                  className="px-5 py-2 bg-[#f9f9f8] hover:bg-[#f0eeeb] text-[#191918] border border-[#e0ddd5] rounded-xl text-sm transition-all"
                >
                  <i className="fas fa-redo mr-2"></i>{t('common.retry')}
                </button>
              </div>
            )}

            {!isLoading && !loadError && activeSection === 'company' && (
              <section className="space-y-6">
                <h3 className="text-xl font-bold text-[#191918] mb-6">{t('settings.company.title')}</h3>
                <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                  <InputGroup label={t('settings.company.name')} placeholder={usPh('setCompanyNamePh', 'AI Dashboard 贸易有限公司')} value={companyInfo.name} onChange={(v) => setCompanyInfo(prev => ({ ...prev, name: v }))} />
                  <InputGroup label={usLabel('setCreditCodeLabel', 'settings.company.creditCode')} placeholder={usPh('setCreditCodePh', '91110000XXXXXXXXXX')} value={companyInfo.creditCode} onChange={(v) => setCompanyInfo(prev => ({ ...prev, creditCode: v }))} />
                  <InputGroup label={usLabel('setLegalPersonLabel', 'settings.company.legalPerson')} placeholder={usPh('setLegalPersonPh', '张晓明')} value={companyInfo.legalPerson} onChange={(v) => setCompanyInfo(prev => ({ ...prev, legalPerson: v }))} />
                  <InputGroup label={t('settings.company.industry')} placeholder={usPh('setIndustryPh', '通用贸易 / 供应链')} value={companyInfo.industry} onChange={(v) => setCompanyInfo(prev => ({ ...prev, industry: v }))} />
                </div>
                <div className="pt-4">
                  <InputGroup label={t('settings.company.address')} placeholder={usPh('setAddressPh', '北京市朝阳区...')} value={companyInfo.address} onChange={(v) => setCompanyInfo(prev => ({ ...prev, address: v }))} />
                </div>
              </section>
            )}

            {!isLoading && !loadError && activeSection === 'tax' && (
              <section className="space-y-6">
                <h3 className="text-xl font-bold text-[#191918] mb-6">{t('settings.tax.title')}</h3>
                <div className="space-y-4">
                  <div className="flex items-center justify-between p-4 bg-[#f9f9f8]/40 rounded-xl border border-[#e0ddd5]">
                    <div>
                      <p className="text-sm font-bold text-[#191918]">{usLabel('setVatRateLabel', 'settings.tax.vatRate')}</p>
                      <p className="text-xs text-[#5c5c5a]">{t('settings.tax.vatRateDesc')}</p>
                    </div>
                    <select value={vatRate} onChange={e => setVatRate(e.target.value)} className="bg-white border border-[#d1cdc4] rounded-lg px-3 py-1 text-sm outline-none">
                      <option value="13">{usLabel('setRateByState', 'settings.tax.rate13')}</option>
                      <option value="9">{usLabel('setRateCustom', 'settings.tax.rate9')}</option>
                      <option value="6">{usLabel('setRateZero', 'settings.tax.rate6')}</option>
                    </select>
                  </div>
                  <div className="flex items-center justify-between p-4 bg-[#f9f9f8]/40 rounded-xl border border-[#e0ddd5]">
                    <div>
                      <p className="text-sm font-bold text-[#191918]">{usLabel('setAutoAuthLabel', 'settings.tax.autoAuth')}</p>
                      <p className="text-xs text-[#5c5c5a]">{usLabel('setAutoAuthDesc', 'settings.tax.autoAuthDesc')}</p>
                    </div>
                    <ToggleButton checked={taxAutoAuth} onChange={setTaxAutoAuth} />
                  </div>

                  <div className="p-4 bg-[#f9f9f8]/40 rounded-xl border border-[#e0ddd5] space-y-3">
                    <div>
                      <p className="text-sm font-bold text-[#191918]">{usLabel('setAdminExpenseLabel', 'settings.tax.adminExpense')}</p>
                      <p className="text-xs text-[#5c5c5a]">{t('settings.tax.adminExpenseDesc')}</p>
                    </div>
                    <div className="flex items-center space-x-2">
                      <span className="text-sm text-[#5c5c5a]">{getCurrencySymbol(accLocale)}</span>
                      <input
                        type="number"
                        min="0"
                        step="100"
                        value={adminExpenseAnnual}
                        onChange={e => setAdminExpenseAnnual(e.target.value)}
                        placeholder="0"
                        className="flex-1 bg-white border border-[#d1cdc4] rounded-lg px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-primary text-[#191918]"
                      />
                      <span className="text-xs text-[#5c5c5a]">{usLabel('setPerYear', 'settings.tax.perYear')}</span>
                    </div>
                    <p className="text-[10px] text-[#8a8a88]">{usLabel('setTaxHint', 'settings.tax.hint')}</p>
                  </div>
                </div>
              </section>
            )}

            {!isLoading && !loadError && activeSection === 'ai' && (
              <div className="space-y-8">
                <ProvidersSection />
              </div>
            )}

            {!isLoading && !loadError && activeSection === 'language' && <LanguageSection />}
            {!isLoading && !loadError && activeSection === 'accounting' && <AccountingSection />}
            {!isLoading && !loadError && activeSection === 'categories' && <CategoriesSection />}
            {!isLoading && !loadError && activeSection === 'products' && <ProductsSection />}
            {!isLoading && !loadError && activeSection === 'dataMigration' && <DataMigrationSection />}
            {!isLoading && !loadError && activeSection === 'dataBackup' && <DataBackupSection />}

            {!isLoading && !loadError && activeSection === 'notifications' && (
              <section className="space-y-6">
                <h3 className="text-xl font-bold text-[#191918] mb-6">{t('settings.notifications.title')}</h3>
                <div className="space-y-4">
                  <NotificationToggle label={usLabel('notifStockZero', 'settings.notifications.stockZero')} checked={notifications.stockZero} onChange={(v) => setNotifications(prev => ({ ...prev, stockZero: v }))} />
                  <NotificationToggle label={usLabel('notifTaxDeviation', 'settings.notifications.taxDeviation')} checked={notifications.taxDeviation} onChange={(v) => setNotifications(prev => ({ ...prev, taxDeviation: v }))} />
                  <NotificationToggle label={usLabel('notifPriceVolatility', 'settings.notifications.priceVolatility')} checked={notifications.priceVolatility} onChange={(v) => setNotifications(prev => ({ ...prev, priceVolatility: v }))} />
                  <NotificationToggle label={usLabel('notifMonthlyReport', 'settings.notifications.monthlyReport')} checked={notifications.monthlyReport} onChange={(v) => setNotifications(prev => ({ ...prev, monthlyReport: v }))} />
                </div>
              </section>
            )}

            {!isLoading && !loadError && activeSection === 'security' && (
              <section className="space-y-6">
                <h3 className="text-xl font-bold text-[#191918] mb-6">{t('settings.security.title')}</h3>
                <div className="space-y-4">
                  <div className="flex items-center justify-between p-5 bg-[#f9f9f8]/40 rounded-xl border border-[#e0ddd5]">
                    <div>
                      <p className="text-sm font-bold text-[#191918]">{t('settings.security.password')}</p>
                      <p className="text-xs text-[#5c5c5a]">{t('settings.security.passwordDesc')}</p>
                    </div>
                    <button
                      onClick={() => { setShowPasswordModal(true); setPasswordError(''); setPasswordSuccess(''); setCurrentPassword(''); setNewPassword(''); setConfirmPassword(''); }}
                      className="px-5 py-2 bg-primary hover:bg-primary-hover text-white text-sm font-medium rounded-xl transition-all active:scale-95"
                    >
                      {t('settings.security.changePassword')}
                    </button>
                  </div>
                  <div className="p-5 bg-[#f9f9f8]/40 rounded-xl border border-[#e0ddd5]">
                    <p className="text-sm font-bold text-[#191918] mb-1">{t('settings.security.encryption')}</p>
                    <p className="text-xs text-[#5c5c5a]">{t('settings.security.encryptionDesc')}</p>
                  </div>
                </div>

                {/* Password Change Modal */}
                {showPasswordModal && (
                  <div className="fixed inset-0 z-[10001] flex items-center justify-center bg-black/30" onClick={() => setShowPasswordModal(false)}>
                    <div className="bg-white rounded-2xl border border-[#e0ddd5] p-8 w-full max-w-sm" style={{ boxShadow: '0 8px 32px rgba(0,0,0,0.12)' }} onClick={e => e.stopPropagation()}>
                      <h4 className="text-lg font-bold text-[#191918] mb-6">{t('settings.security.modalTitle')}</h4>
                      <div className="space-y-4">
                        <div>
                          <label className="block text-xs font-medium text-[#4a4a48] mb-1.5">{t('settings.security.currentPassword')}</label>
                          <input type="password" value={currentPassword} onChange={e => setCurrentPassword(e.target.value)} className="w-full px-4 py-3 bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl text-sm outline-none focus:border-primary transition-colors" autoComplete="current-password" />
                        </div>
                        <div>
                          <label className="block text-xs font-medium text-[#4a4a48] mb-1.5">{t('settings.security.newPassword')}</label>
                          <input type="password" value={newPassword} onChange={e => setNewPassword(e.target.value)} className="w-full px-4 py-3 bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl text-sm outline-none focus:border-primary transition-colors" autoComplete="new-password" />
                        </div>
                        <div>
                          <label className="block text-xs font-medium text-[#4a4a48] mb-1.5">{t('settings.security.confirmPassword')}</label>
                          <input type="password" value={confirmPassword} onChange={e => setConfirmPassword(e.target.value)} className="w-full px-4 py-3 bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl text-sm outline-none focus:border-primary transition-colors" autoComplete="new-password" />
                        </div>
                        {passwordError && <p className="text-sm text-red-600 bg-red-50 border border-red-200 rounded-lg px-4 py-2">{passwordError}</p>}
                        {passwordSuccess && <p className="text-sm text-emerald-600 bg-emerald-50 border border-emerald-200 rounded-lg px-4 py-2">{passwordSuccess}</p>}
                      </div>
                      <div className="flex space-x-3 mt-6">
                        <button onClick={() => setShowPasswordModal(false)} className="flex-1 py-3 bg-[#f9f9f8] text-[#4a4a48] border border-[#e0ddd5] rounded-xl text-sm font-medium hover:bg-[#f0eeeb] transition-all">{t('common.cancel')}</button>
                        <button onClick={handleChangePassword} disabled={changingPassword} className="flex-1 py-3 bg-primary text-white rounded-xl text-sm font-medium hover:bg-primary-hover disabled:opacity-40 transition-all">
                          {changingPassword ? <><i className="fas fa-spinner fa-spin mr-2"></i>{t('settings.security.changing')}</> : t('settings.security.confirmChange')}
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
                  className="px-10 py-3 bg-primary hover:bg-primary-hover text-white font-bold rounded-xl transition-all active:scale-95 disabled:opacity-50 flex items-center" style={{boxShadow: '0 4px 16px rgba(39,76,146,0.15)'}}
                >
                  {isSaving ? <i className="fas fa-spinner animate-spin mr-2"></i> : <i className="fas fa-save mr-2"></i>}
                  {t('settings.saveButton')}
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
    className={`w-full flex items-center px-6 py-4 rounded-xl transition-all border ${active ? 'bg-primary text-white border-primary' : 'bg-white/80 text-[#4a4a48] border-[#e0ddd5] hover:bg-[#f9f9f8] hover:text-[#191918]'}`}
    style={active ? {boxShadow: '0 4px 16px rgba(39,76,146,0.15)'} : {}}
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
      className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all"
    />
  </div>
);

const ToggleButton: React.FC<{ checked: boolean, onChange: (v: boolean) => void }> = ({ checked, onChange }) => (
  <button
    onClick={() => onChange(!checked)}
    className={`w-12 h-6 rounded-full relative transition-colors ${checked ? 'bg-primary' : 'bg-[#e0ddd5]'}`}
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
