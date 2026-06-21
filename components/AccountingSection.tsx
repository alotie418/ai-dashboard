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
  // PR-7B P2 收尾：经营主体类型 + 期初未分配利润（管理口径概览权益用；仅影响概览标签，非法定主体认定）。
  const [entityType, setEntityType] = useState<'individual' | 'company'>('individual');
  const [openingRetained, setOpeningRetained] = useState<number>(0);
  const [saving, setSaving] = useState(false);
  const [toast, setToast] = useState<{ type: 'success' | 'error'; text: string } | null>(null);

  useEffect(() => {
    fetchSettings().then((s: any) => {
      const loc = s.accounting_locale || DEFAULT_ACCOUNTING_LOCALE;
      const p = getProfile(loc);
      if (s.accounting_locale) setCurrentLocale(loc);
      if (s.vat_rate !== undefined) {
        // Default-value protection: a persisted rate outside the current regime's
        // option range (e.g. CN's 13% lingering after switching to US, whose
        // options top out at 10) falls back to the regime default instead of
        // leaking across. CN keeps 13 (within its own range).
        const v = Number(s.vat_rate);
        const opts = p.vatRateOptions;
        setVatRate(v < Math.min(...opts) || v > Math.max(...opts) ? p.vatRate : v);
      }
      if (s.surcharge_rate !== undefined) setSurchargeRate(Number(s.surcharge_rate));
      if (s.income_tax_rate !== undefined) setIncomeTaxRate(Number(s.income_tax_rate));
      if (s.currency) setCurrency(s.currency);
      // PR-7B P2 收尾：读取主体类型（缺/非法→individual）与期初未分配利润（NaN→0，允许负）。
      if (s.entity_type === 'company' || s.entity_type === 'individual') setEntityType(s.entity_type);
      if (s.opening_retained_earnings !== undefined) {
        const n = Number(s.opening_retained_earnings);
        setOpeningRetained(Number.isFinite(n) ? n : 0);
      }
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

      {/* Clarification banner */}
      <div className="text-xs text-[#4a4a48] bg-blue-50 border border-blue-200 rounded-lg p-3 space-y-1">
        <div className="font-semibold"><i className="fas fa-balance-scale mr-1.5 text-blue-500"></i>{t('settings.accounting.scopeTitle', 'What this changes')}</div>
        <ul className="list-disc list-inside text-[11px] text-[#5c5c5a] space-y-0.5">
          <li>{t('settings.accounting.scopeYes1', 'Tax regime, tax rates, and tax concepts')}</li>
          <li>{t('settings.accounting.scopeYes2', 'Default currency and report structure')}</li>
          <li>{t('settings.accounting.scopeYes3', 'Dashboard metrics, categories, and AI finance context')}</li>
        </ul>
        <div className="text-[11px] text-[#5c5c5a] mt-1">
          <i className="fas fa-exclamation-circle mr-1 text-amber-500"></i>
          {t('settings.accounting.scopeNo', 'Does NOT change the display language. Menus and labels stay in your chosen UI Language.')}
        </div>
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
                  ? 'border-primary bg-primary/5'
                  : 'border-[#e0ddd5] bg-white hover:bg-[#f0eeeb]'
              } disabled:opacity-50`}
            >
              <div className="flex items-center justify-between mb-2">
                <div className="flex items-center">
                  <span className="text-2xl mr-2">{p.flag}</span>
                  <span className="text-sm font-semibold text-[#191918]">{name}</span>
                </div>
                {selected && <i className="fas fa-check-circle text-primary"></i>}
              </div>
              <div className="space-y-1 text-[11px] text-[#5c5c5a]">
                <div>{taxLabel}: <span className="font-mono font-semibold text-[#191918]">{p.vatRateDisplay?.[lang] ?? `${p.vatRate}%`}</span></div>
                <div>{t('settings.accounting.incomeTax')}: <span className="font-mono font-semibold text-[#191918]">{p.incomeTaxRate}%</span></div>
                <div>{t('settings.accounting.currency')}: <span className="font-mono font-semibold text-[#191918]">{p.currency} ({p.currencySymbol})</span></div>
              </div>
            </button>
          );
        })}
      </div>

      {/* PR-E1: preset rates are reference values; verify against current official rates. */}
      <p className="text-[11px] text-[#5c5c5a] leading-snug"><i className="fas fa-circle-info mr-1.5"></i>{t('disclaimer.rates')}</p>

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
            <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{(profile.surchargeLabel?.[lang] ?? t('settings.accounting.surcharge'))} (%)</label>
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
          className="text-xs px-3 py-1.5 border border-primary text-primary rounded-lg hover:bg-primary/5 disabled:opacity-50"
        >
          {saving ? <><i className="fas fa-spinner fa-spin mr-1.5"></i>{t('common.saving')}</> : t('common.save')}
        </button>
        {(profile.notesByLang?.[lang] || profile.notes) && (
          <div className="text-[10px] text-[#5c5c5a] bg-white border border-[#e0ddd5] rounded p-2 mt-2">
            <i className="fas fa-info-circle mr-1 text-primary"></i>
            {profile.notesByLang?.[lang] || profile.notes}
          </div>
        )}
      </div>

      {/* PR-7B P2 收尾：经营主体与期初权益（管理口径概览权益用；select 主体类型 + 期初未分配利润，允许负=累计亏损） */}
      <div className="border border-[#e0ddd5] rounded-xl p-5 bg-[#f9f9f8]/30 space-y-3">
        <div className="text-sm font-semibold text-[#191918]">{t('settings.accounting.entitySectionTitle')}</div>
        <div className="grid grid-cols-2 gap-3">
          <div>
            <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('settings.accounting.entityTypeLabel')}</label>
            <select value={entityType} onChange={e => setEntityType(e.target.value as 'individual' | 'company')}
              className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white">
              <option value="individual">{t('settings.accounting.entityTypeIndividual')}</option>
              <option value="company">{t('settings.accounting.entityTypeCompany')}</option>
            </select>
          </div>
          <div>
            <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('settings.accounting.openingRetainedLabel')} ({currency})</label>
            <input type="number" step="0.01" value={openingRetained} onChange={e => setOpeningRetained(Number(e.target.value))}
              className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white font-mono" />
          </div>
        </div>
        <p className="text-[10px] text-[#5c5c5a] leading-snug"><i className="fas fa-circle-info mr-1.5"></i>{t('settings.accounting.entityTypeHint')}</p>
        <p className="text-[10px] text-[#5c5c5a] leading-snug"><i className="fas fa-circle-info mr-1.5"></i>{t('settings.accounting.openingRetainedHint')}</p>
        <button
          onClick={async () => {
            setSaving(true);
            try {
              await saveSettings({ entity_type: entityType, opening_retained_earnings: openingRetained } as any);
              setToast({ type: 'success', text: t('settings.savedToast') });
            } catch (e: any) {
              setToast({ type: 'error', text: e?.message || 'Save failed' });
            } finally {
              setSaving(false);
              setTimeout(() => setToast(null), 2500);
            }
          }}
          disabled={saving}
          className="text-xs px-3 py-1.5 border border-primary text-primary rounded-lg hover:bg-primary/5 disabled:opacity-50"
        >
          {saving ? <><i className="fas fa-spinner fa-spin mr-1.5"></i>{t('common.saving')}</> : t('common.save')}
        </button>
      </div>

      <div className="text-[11px] text-amber-700 bg-amber-50 border border-amber-200 rounded-lg p-3">
        <i className="fas fa-exclamation-triangle mr-1.5"></i>
        {t('settings.accounting.warning')}
      </div>
    </section>
  );
};

export default AccountingSection;
