import React, { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { ACCOUNTING_PROFILES, ACCOUNTING_LOCALES, getProfile, DEFAULT_ACCOUNTING_LOCALE } from './accountingProfiles';
import type { LangCode } from '../i18n';
import { fetchSettings, saveSettings } from '../services/api';

const AccountingSection: React.FC = () => {
  const { t, i18n } = useTranslation();
  const lang = i18n.language as LangCode;
  const [currentLocale, setCurrentLocale] = useState<string>(DEFAULT_ACCOUNTING_LOCALE);
  const [vatRate, setVatRate] = useState<number>(13);
  const [surchargeRate, setSurchargeRate] = useState<number>(12);
  const [incomeTaxRate, setIncomeTaxRate] = useState<number>(25);
  const [currency, setCurrency] = useState<string>('CNY');
  const [saving, setSaving] = useState(false);
  const [toast, setToast] = useState<{ type: 'success' | 'error'; text: string } | null>(null);

  useEffect(() => {
    fetchSettings().then((s: any) => {
      if (s.accounting_locale) setCurrentLocale(s.accounting_locale);
      if (s.vat_rate !== undefined) setVatRate(Number(s.vat_rate));
      if (s.surcharge_rate !== undefined) setSurchargeRate(Number(s.surcharge_rate));
      if (s.income_tax_rate !== undefined) setIncomeTaxRate(Number(s.income_tax_rate));
      if (s.currency) setCurrency(s.currency);
    }).catch(() => {});
  }, []);

  const profile = getProfile(currentLocale);

  const applyProfile = async (localeCode: string) => {
    const p = getProfile(localeCode);
    setSaving(true);
    try {
      await saveSettings({
        accounting_locale: localeCode,
        vat_rate: p.vatRate,
        surcharge_rate: p.surchargeRate,
        income_tax_rate: p.incomeTaxRate,
        currency: p.currency,
      } as any);
      setCurrentLocale(localeCode);
      setVatRate(p.vatRate);
      setSurchargeRate(p.surchargeRate);
      setIncomeTaxRate(p.incomeTaxRate);
      setCurrency(p.currency);
      setToast({ type: 'success', text: `${p.name[lang] || p.name['en']} ✓` });
    } catch (e: any) {
      setToast({ type: 'error', text: e?.message || 'Save failed' });
    } finally {
      setSaving(false);
      setTimeout(() => setToast(null), 2500);
    }
  };

  return (
    <section className="space-y-6">
      <div>
        <h3 className="text-xl font-bold text-[#191918]">{t('settings.accounting.title')}</h3>
        <p className="text-xs text-[#6b6b69] mt-1">{t('settings.accounting.subtitle')}</p>
      </div>

      {toast && (
        <div className={`px-4 py-2.5 rounded-lg text-sm ${toast.type === 'success' ? 'bg-emerald-50 text-emerald-700' : 'bg-rose-50 text-rose-700'}`}>
          <i className={`fas ${toast.type === 'success' ? 'fa-check-circle' : 'fa-exclamation-circle'} mr-2`}></i>
          {toast.text}
        </div>
      )}

      {/* 6 国预设卡片 */}
      <div className="grid grid-cols-2 lg:grid-cols-3 gap-3">
        {ACCOUNTING_LOCALES.map(code => {
          const p = ACCOUNTING_PROFILES[code];
          const selected = currentLocale === code;
          const name = p.name[lang] || p.name['en'];
          const taxLabel = p.taxLabel[lang] || p.taxLabel['en'];
          return (
            <button
              key={code}
              type="button"
              disabled={saving}
              onClick={() => applyProfile(code)}
              className={`p-4 rounded-xl border text-left transition-all ${
                selected
                  ? 'border-[#d97757] bg-[#d97757]/5'
                  : 'border-[#e0ddd5] bg-white hover:bg-[#f0eeeb]'
              } disabled:opacity-50`}
            >
              <div className="flex items-center justify-between mb-2">
                <div className="flex items-center">
                  <span className="text-2xl mr-2">{p.flag}</span>
                  <span className="text-sm font-semibold text-[#191918]">{name}</span>
                </div>
                {selected && <i className="fas fa-check-circle text-[#d97757]"></i>}
              </div>
              <div className="space-y-1 text-[11px] text-[#5c5c5a]">
                <div>{taxLabel}: <span className="font-mono font-semibold text-[#191918]">{p.vatRate}%</span></div>
                <div>{t('settings.accounting.incomeTax')}: <span className="font-mono font-semibold text-[#191918]">{p.incomeTaxRate}%</span></div>
                <div>{t('settings.accounting.currency')}: <span className="font-mono font-semibold text-[#191918]">{p.currency} ({p.currencySymbol})</span></div>
              </div>
            </button>
          );
        })}
      </div>

      {/* 当前生效参数（可手动微调） */}
      <div className="border border-[#e0ddd5] rounded-xl p-5 bg-[#f9f9f8]/30 space-y-3">
        <div className="text-sm font-semibold text-[#191918]">
          {t('settings.accounting.currentLocale')}: {profile.name[lang] || profile.name['en']} {profile.flag}
        </div>
        <div className="grid grid-cols-2 gap-3">
          <div>
            <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{profile.taxLabel[lang] || profile.taxLabel['en']} (%)</label>
            <input type="number" step="0.1" value={vatRate} onChange={e => setVatRate(Number(e.target.value))}
              className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
          </div>
          <div>
            <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('settings.accounting.surcharge')} (%)</label>
            <input type="number" step="0.1" value={surchargeRate} onChange={e => setSurchargeRate(Number(e.target.value))}
              className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
          </div>
          <div>
            <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('settings.accounting.incomeTax')} (%)</label>
            <input type="number" step="0.1" value={incomeTaxRate} onChange={e => setIncomeTaxRate(Number(e.target.value))}
              className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
          </div>
          <div>
            <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('settings.accounting.currency')}</label>
            <input type="text" value={currency} onChange={e => setCurrency(e.target.value)}
              className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white font-mono" />
          </div>
        </div>
        <button
          onClick={async () => {
            setSaving(true);
            try {
              await saveSettings({ vat_rate: vatRate, surcharge_rate: surchargeRate, income_tax_rate: incomeTaxRate, currency } as any);
              setToast({ type: 'success', text: t('settings.savedToast') });
            } catch (e: any) {
              setToast({ type: 'error', text: e?.message || 'Save failed' });
            } finally {
              setSaving(false);
              setTimeout(() => setToast(null), 2500);
            }
          }}
          disabled={saving}
          className="text-xs px-3 py-1.5 border border-[#d97757] text-[#d97757] rounded-lg hover:bg-[#d97757]/5 disabled:opacity-50"
        >
          {saving ? <><i className="fas fa-spinner fa-spin mr-1.5"></i>{t('common.saving')}</> : t('common.save')}
        </button>
        {profile.notes && (
          <div className="text-[10px] text-[#7a7a78] bg-white border border-[#e0ddd5] rounded p-2 mt-2">
            <i className="fas fa-info-circle mr-1 text-[#d97757]"></i>
            {profile.notes}
          </div>
        )}
      </div>

      <div className="text-[11px] text-amber-700 bg-amber-50 border border-amber-200 rounded-lg p-3">
        <i className="fas fa-exclamation-triangle mr-1.5"></i>
        {t('settings.accounting.warning')}
      </div>
    </section>
  );
};

export default AccountingSection;
