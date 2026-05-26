// 设置页 → 类别管理（国际化数据模型 v4）
// 按当前 accounting_locale 列出预置类别，允许新增 / 编辑 / 删除（仅用户类别可删）
import React, { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import type { LangCode } from '../i18n';
import {
  listCategories, createCategory, updateCategory, deleteCategory,
  type AccountingLocale, type Category, type CategoryType,
  fetchSettings,
} from '../services/api';
import { ACCOUNTING_PROFILES } from './accountingProfiles';

const CategoriesSection: React.FC = () => {
  const { t, i18n } = useTranslation();
  const lang = i18n.language as LangCode;
  const [locale, setLocale] = useState<AccountingLocale>('CN');
  const [activeType, setActiveType] = useState<CategoryType>('expense');
  const [cats, setCats] = useState<Category[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showAddForm, setShowAddForm] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null);

  // Add form state
  const [newSlug, setNewSlug] = useState('');
  const [newLabel, setNewLabel] = useState('');
  const [newScheduleLine, setNewScheduleLine] = useState('');
  const [newDeductiblePct, setNewDeductiblePct] = useState<number>(100);

  useEffect(() => {
    fetchSettings().then((s: any) => {
      if (s.accounting_locale) setLocale(s.accounting_locale);
    }).finally(() => {
      reload();
    });
  }, []);

  useEffect(() => {
    reload();
  }, [locale, activeType, lang]);

  const reload = async () => {
    setLoading(true);
    setError(null);
    try {
      const list = await listCategories({ locale, type: activeType, lang });
      setCats(list);
    } catch (e: any) {
      setError(e?.message || 'Load failed');
    } finally {
      setLoading(false);
    }
  };

  const handleAdd = async () => {
    if (!newSlug.trim() || !newLabel.trim()) return;
    try {
      await createCategory({
        locale,
        type: activeType,
        slug: newSlug.trim().toLowerCase(),
        label_en: newLabel.trim(),
        label_zh_cn: newLabel.trim(),
        schedule_line: newScheduleLine.trim() || undefined,
        deductible_pct: newDeductiblePct,
      });
      setShowAddForm(false);
      setNewSlug(''); setNewLabel(''); setNewScheduleLine(''); setNewDeductiblePct(100);
      reload();
    } catch (e: any) {
      setError(e?.message || 'Create failed');
    }
  };

  const handleDelete = async (id: string) => {
    try {
      await deleteCategory(id);
      setConfirmDelete(null);
      reload();
    } catch (e: any) {
      setError(e?.message || 'Delete failed');
      setConfirmDelete(null);
    }
  };

  const profile = ACCOUNTING_PROFILES[locale];
  const localeName = profile?.name[lang] || profile?.name['en'] || locale;
  const localeFlag = profile?.flag || '';

  return (
    <section className="space-y-6">
      <div>
        <h3 className="text-xl font-bold text-[#191918]">{t('settings.categories.title', '会计类别')}</h3>
        <p className="text-xs text-[#6b6b69] mt-1">
          {t('settings.categories.subtitle', '按当前会计制度展示预置类别。可新增自定义类别，但系统预置类别不能删除。')}
        </p>
      </div>

      {/* Locale 切换器 */}
      <div className="flex items-center justify-between">
        <div className="flex items-center text-sm">
          <span className="text-[#7a7a78] mr-2">{t('settings.accounting.currentLocale', '当前制度')}:</span>
          <span className="text-2xl mr-1.5">{localeFlag}</span>
          <span className="font-semibold text-[#191918]">{localeName}</span>
        </div>
        <select
          value={locale}
          onChange={e => setLocale(e.target.value as AccountingLocale)}
          className="text-xs px-2 py-1 border border-[#e0ddd5] rounded bg-white"
        >
          {Object.entries(ACCOUNTING_PROFILES).map(([code, p]) => (
            <option key={code} value={code}>{p.flag} {p.name[lang] || p.name['en']}</option>
          ))}
        </select>
      </div>

      {/* Income / Expense Tab */}
      <div className="flex border-b border-[#e0ddd5]">
        {(['expense', 'income'] as CategoryType[]).map(t_ => (
          <button
            key={t_}
            onClick={() => setActiveType(t_)}
            className={`px-4 py-2 text-sm font-medium border-b-2 transition-colors ${
              activeType === t_ ? 'border-[#d97757] text-[#d97757]' : 'border-transparent text-[#7a7a78] hover:text-[#4a4a48]'
            }`}
          >
            {t_ === 'expense' ? t('settings.categories.expense', '支出') : t('settings.categories.income', '收入')}
          </button>
        ))}
      </div>

      {error && (
        <div className="text-sm text-rose-600 bg-rose-50 border border-rose-200 rounded-lg px-3 py-2">
          <i className="fas fa-exclamation-circle mr-2"></i>{error}
        </div>
      )}

      {/* 类别列表 */}
      {loading ? (
        <div className="text-sm text-[#7a7a78] py-6 text-center">
          <i className="fas fa-spinner fa-spin mr-2"></i>{t('common.loading')}
        </div>
      ) : (
        <div className="border border-[#e0ddd5] rounded-xl overflow-hidden">
          <table className="w-full text-sm">
            <thead className="bg-[#f9f9f8] text-[10px] uppercase tracking-wider text-[#4a4a48]">
              <tr>
                <th className="text-left px-4 py-2.5">{t('settings.categories.label', '名称')}</th>
                <th className="text-left px-4 py-2.5">Slug</th>
                <th className="text-left px-4 py-2.5">{t('settings.categories.scheduleLine', '报表行')}</th>
                <th className="text-right px-4 py-2.5">{t('settings.categories.deductible', '可抵扣')}</th>
                <th className="text-right px-4 py-2.5 w-24"></th>
              </tr>
            </thead>
            <tbody>
              {cats.length === 0 && (
                <tr><td colSpan={5} className="text-center text-[#7a7a78] py-6 text-xs">{t('settings.categories.empty', '该制度暂无此类型的类别')}</td></tr>
              )}
              {cats.map(c => (
                <tr key={c.id} className="border-t border-[#e0ddd5]/70 hover:bg-[#f9f9f8]/40">
                  <td className="px-4 py-2 text-[#191918]">
                    {c.displayLabel}
                    {!c.is_system && <span className="ml-2 text-[10px] bg-[#d97757]/10 text-[#d97757] px-1.5 py-0.5 rounded">{t('settings.categories.userMade', '自建')}</span>}
                  </td>
                  <td className="px-4 py-2 font-mono text-[11px] text-[#7a7a78]">{c.slug}</td>
                  <td className="px-4 py-2 text-[11px] text-[#5c5c5a]">{c.schedule_line || '—'}</td>
                  <td className="px-4 py-2 text-right text-[11px]">
                    {c.is_deductible ? (
                      <span className="text-emerald-600">{c.deductible_pct < 100 ? `${c.deductible_pct}%` : '✓'}</span>
                    ) : (
                      <span className="text-[#7a7a78]">—</span>
                    )}
                  </td>
                  <td className="px-4 py-2 text-right">
                    {!c.is_system && (
                      confirmDelete === c.id ? (
                        <div className="inline-flex items-center space-x-1">
                          <button onClick={() => handleDelete(c.id)} className="text-[10px] px-2 py-0.5 bg-rose-600 text-white rounded">{t('common.delete')}</button>
                          <button onClick={() => setConfirmDelete(null)} className="text-[10px] px-2 py-0.5 border border-rose-300 text-rose-600 rounded">{t('common.cancel')}</button>
                        </div>
                      ) : (
                        <button onClick={() => setConfirmDelete(c.id)} className="text-[10px] text-rose-600 hover:text-rose-700">
                          <i className="fas fa-trash mr-1"></i>{t('common.delete')}
                        </button>
                      )
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {/* 新增类别表单 */}
      {showAddForm ? (
        <div className="border border-[#d97757]/30 bg-[#d97757]/5 rounded-xl p-4 space-y-3">
          <div className="text-sm font-semibold text-[#191918]">
            {t('settings.categories.addNew', '新增类别')} · {activeType === 'expense' ? t('settings.categories.expense') : t('settings.categories.income')} · {localeFlag} {localeName}
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('settings.categories.label', '名称')}</label>
              <input value={newLabel} onChange={e => setNewLabel(e.target.value)} placeholder="e.g. Software Subscriptions"
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">Slug (lowercase-only)</label>
              <input value={newSlug} onChange={e => setNewSlug(e.target.value.toLowerCase().replace(/[^a-z0-9-]/g, ''))} placeholder="e.g. software"
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white font-mono" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('settings.categories.scheduleLine', '报表行')} <span className="text-[#7a7a78]">({t('common.optional')})</span></label>
              <input value={newScheduleLine} onChange={e => setNewScheduleLine(e.target.value)} placeholder="e.g. Schedule C Line 22"
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('settings.categories.deductiblePct', '可抵扣比例 (%)')}</label>
              <input type="number" min="0" max="100" value={newDeductiblePct} onChange={e => setNewDeductiblePct(Number(e.target.value))}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
          </div>
          <div className="flex space-x-2">
            <button onClick={() => setShowAddForm(false)} className="text-xs px-4 py-1.5 border border-[#e0ddd5] text-[#4a4a48] rounded-lg hover:bg-[#f0eeeb]">
              {t('common.cancel')}
            </button>
            <button onClick={handleAdd} disabled={!newSlug.trim() || !newLabel.trim()}
              className="text-xs px-4 py-1.5 bg-[#d97757] text-white rounded-lg hover:bg-[#c4694d] disabled:opacity-50">
              {t('common.save')}
            </button>
          </div>
        </div>
      ) : (
        <button onClick={() => setShowAddForm(true)} className="w-full border-2 border-dashed border-[#e0ddd5] text-sm text-[#7a7a78] hover:text-[#d97757] hover:border-[#d97757]/50 rounded-xl py-3 transition-colors">
          <i className="fas fa-plus mr-1.5"></i>
          {t('settings.categories.addNewButton', '新增自定义类别')}
        </button>
      )}

      <div className="text-[10px] text-[#7a7a78] bg-[#f9f9f8] border border-[#e0ddd5] rounded-lg p-3">
        <i className="fas fa-info-circle mr-1.5 text-[#d97757]"></i>
        {t('settings.categories.systemNote', '系统预置类别由 SoloLedger 维护，与官方报表行对应，不可删除（但可改名）。自建类别完全由你掌控。')}
      </div>
    </section>
  );
};

export default CategoriesSection;
