import React from 'react';
import { useTranslation } from 'react-i18next';
import { SUPPORTED_LANGUAGES, setLanguage, type LangCode } from '../i18n';

const LanguageSection: React.FC = () => {
  const { t, i18n } = useTranslation();
  const current = i18n.language as LangCode;

  return (
    <section className="space-y-6">
      <div>
        <h3 className="text-xl font-bold text-[#191918]">{t('settings.language.title')}</h3>
        <p className="text-xs text-[#6b6b69] mt-1">{t('settings.language.subtitle')}</p>
      </div>

      {/* Clarification banner */}
      <div className="text-xs text-[#4a4a48] bg-blue-50 border border-blue-200 rounded-lg p-3 space-y-1">
        <div className="font-semibold"><i className="fas fa-language mr-1.5 text-blue-500"></i>{t('settings.language.scopeTitle', 'What this changes')}</div>
        <ul className="list-disc list-inside text-[11px] text-[#5c5c5a] space-y-0.5">
          <li>{t('settings.language.scopeYes1', 'Menus, buttons, labels, help text')}</li>
          {/* MAS build: "AI response language" — hidden. */}
          {!__MAS_BUILD__ && <li>{t('settings.language.scopeYes2', 'AI response language')}</li>}
        </ul>
        <div className="text-[11px] text-[#5c5c5a] mt-1">
          <i className="fas fa-exclamation-circle mr-1 text-amber-500"></i>
          {t('settings.language.scopeNo', 'Does NOT change tax rules, currency, report structure, or categories. Those are controlled by Accounting Basis.')}
        </div>
      </div>

      <div className="grid grid-cols-2 gap-3">
        {SUPPORTED_LANGUAGES.map(lang => {
          const selected = current === lang.code;
          return (
            <button
              key={lang.code}
              type="button"
              onClick={() => setLanguage(lang.code as LangCode)}
              className={`flex items-center p-4 rounded-xl border transition-all ${
                selected
                  ? 'border-primary bg-primary/5'
                  : 'border-[#e0ddd5] bg-white hover:bg-[#f0eeeb]'
              }`}
            >
              <span className="text-2xl mr-3">{lang.flag}</span>
              <div className="flex-1 text-left">
                <div className="text-sm font-semibold text-[#191918]">{lang.label}</div>
                <div className="text-[10px] text-[#5c5c5a] mt-0.5 font-mono">{lang.code}</div>
              </div>
              {selected && <i className="fas fa-check-circle text-primary text-lg"></i>}
            </button>
          );
        })}
      </div>

      <div className="text-[11px] text-[#5c5c5a] bg-[#f9f9f8] border border-[#e0ddd5] rounded-lg p-3">
        <i className="fas fa-info-circle mr-1.5 text-primary"></i>
        {t('settings.language.note')}
      </div>
    </section>
  );
};

export default LanguageSection;
