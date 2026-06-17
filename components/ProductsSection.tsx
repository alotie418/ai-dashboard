// 设置页 → 商品 / 服务项目管理（Phase 1）
// 商品/服务基础资料 + 每项单位。服务类(is_service)后续不参与库存。
// 显示纯 UI 语言驱动（i18n + getProductUnitLabel），不读 accountingLocale。
import React, { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import type { LangCode } from '../i18n';
import { listProducts, createProduct, updateProduct, deleteProduct, type Product } from '../services/api';
import { getSystemErrorText } from '../services/systemErrors';
import { PRODUCT_UNIT_KEYS, getProductUnitLabel } from './accountingHelpers';

const ProductsSection: React.FC = () => {
  const { t, i18n } = useTranslation();
  const lang = i18n.language as LangCode;
  const [items, setItems] = useState<Product[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showAddForm, setShowAddForm] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null);

  const [newName, setNewName] = useState('');
  const [newUnit, setNewUnit] = useState('piece');
  const [newCost, setNewCost] = useState<number>(0);
  const [newIsService, setNewIsService] = useState(false);
  const [saving, setSaving] = useState(false);

  useEffect(() => { reload(); }, []);

  const reload = async () => {
    setLoading(true);
    setError(null);
    try {
      setItems(await listProducts());
    } catch (e: any) {
      console.error(e);
      setError(t('common.operationFailed'));
    } finally {
      setLoading(false);
    }
  };

  const handleAdd = async () => {
    if (!newName.trim()) return;
    setSaving(true);
    try {
      await createProduct({ name: newName.trim(), unit: newUnit, default_unit_cost: newCost, is_service: newIsService });
      setShowAddForm(false);
      setNewName(''); setNewUnit('piece'); setNewCost(0); setNewIsService(false);
      reload();
    } catch (e: any) {
      console.error(e);
      setError(getSystemErrorText(e, t) || t('common.operationFailed'));
    } finally {
      setSaving(false);
    }
  };

  const handleToggleActive = async (p: Product) => {
    try { await updateProduct(p.id, { is_active: !p.is_active }); reload(); }
    catch (e: any) { console.error(e); setError(getSystemErrorText(e, t) || t('common.operationFailed')); }
  };

  const handleDelete = async (id: string) => {
    try { await deleteProduct(id); setConfirmDelete(null); reload(); }
    catch (e: any) { console.error(e); setError(getSystemErrorText(e, t) || t('common.operationFailed')); setConfirmDelete(null); }
  };

  return (
    <section className="space-y-6">
      <div>
        <h3 className="text-xl font-bold text-[#191918]">{t('products.title')}</h3>
        <p className="text-xs text-[#6b6b69] mt-1">{t('products.subtitle')}</p>
      </div>

      {error && (
        <div className="text-sm text-rose-600 bg-rose-50 border border-rose-200 rounded-lg px-3 py-2">
          <i className="fas fa-exclamation-circle mr-2"></i>{error}
        </div>
      )}

      {loading ? (
        <div className="text-sm text-[#7a7a78] py-6 text-center">
          <i className="fas fa-spinner fa-spin mr-2"></i>{t('common.loading')}
        </div>
      ) : (
        <div className="border border-[#e0ddd5] rounded-xl overflow-hidden">
          <div className="overflow-x-auto">
          <table className="w-full text-sm data-table">
            <thead className="bg-[#f9f9f8] text-[10px] uppercase tracking-wider text-[#4a4a48]">
              <tr>
                <th className="text-left px-4 py-2.5">{t('products.name')}</th>
                <th className="text-left px-4 py-2.5">{t('products.unit')}</th>
                <th className="text-left px-4 py-2.5">{t('products.type')}</th>
                <th className="text-right px-4 py-2.5">{t('products.cost')}</th>
                <th className="text-left px-4 py-2.5">{t('products.status')}</th>
                <th className="text-right px-4 py-2.5 w-20"></th>
              </tr>
            </thead>
            <tbody>
              {items.length === 0 && (
                <tr><td colSpan={6} className="text-center text-[#7a7a78] py-6 text-xs">{t('products.empty')}</td></tr>
              )}
              {items.map(p => (
                <tr key={p.id} className="border-t border-[#e0ddd5]/70 hover:bg-[#f9f9f8]/40">
                  <td className="px-4 py-2 text-[#191918] col-name">{p.name}</td>
                  <td className="px-4 py-2 text-[11px] text-[#5c5c5a]">{getProductUnitLabel(p.unit, lang)}</td>
                  <td className="px-4 py-2 text-[11px]">
                    {p.is_service
                      ? <span className="text-[10px] bg-violet-100 text-violet-700 px-1.5 py-0.5 rounded">{t('products.service')}</span>
                      : <span className="text-[10px] bg-blue-100 text-blue-700 px-1.5 py-0.5 rounded">{t('products.product')}</span>}
                  </td>
                  <td className="px-4 py-2 text-right text-[11px] text-[#5c5c5a]">{p.default_unit_cost > 0 ? p.default_unit_cost : '—'}</td>
                  <td className="px-4 py-2 text-[11px]">
                    <button onClick={() => handleToggleActive(p)} className={p.is_active ? 'text-emerald-600' : 'text-[#a8a8a6]'}>
                      <i className={`fas ${p.is_active ? 'fa-toggle-on' : 'fa-toggle-off'} mr-1`}></i>{p.is_active ? t('products.active') : t('products.inactive')}
                    </button>
                  </td>
                  <td className="px-4 py-2 text-right">
                    {confirmDelete === p.id ? (
                      <div className="inline-flex items-center space-x-1">
                        <button onClick={() => handleDelete(p.id)} className="text-[10px] px-2 py-0.5 bg-rose-600 text-white rounded">{t('common.delete')}</button>
                        <button onClick={() => setConfirmDelete(null)} className="text-[10px] px-2 py-0.5 border border-rose-300 text-rose-600 rounded">{t('common.cancel')}</button>
                      </div>
                    ) : (
                      <button onClick={() => setConfirmDelete(p.id)} className="text-[10px] text-rose-600 hover:text-rose-700">
                        <i className="fas fa-trash mr-1"></i>{t('common.delete')}
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          </div>
        </div>
      )}

      {showAddForm ? (
        <div className="border border-primary/30 bg-primary/5 rounded-xl p-4 space-y-3">
          <div className="text-sm font-semibold text-[#191918]">{t('products.addTitle')}</div>
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('products.name')}</label>
              <input value={newName} onChange={e => setNewName(e.target.value)} placeholder={t('products.namePlaceholder')}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('products.unit')}</label>
              <select value={newUnit} onChange={e => setNewUnit(e.target.value)}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white">
                {PRODUCT_UNIT_KEYS.map(k => (<option key={k} value={k}>{getProductUnitLabel(k, lang)}</option>))}
              </select>
            </div>
            <div>
              <label className="block text-[11px] font-medium text-[#4a4a48] mb-1">{t('products.cost')}</label>
              <input type="number" min="0" step="0.01" value={newCost} onChange={e => setNewCost(Number(e.target.value))}
                className="w-full px-3 py-1.5 border border-[#e0ddd5] rounded-lg text-sm bg-white" />
            </div>
            <div className="flex items-end">
              <label className="inline-flex items-center text-[11px] text-[#4a4a48]">
                <input type="checkbox" checked={newIsService} onChange={e => setNewIsService(e.target.checked)} className="mr-2" />
                {t('products.isService')}
              </label>
            </div>
          </div>
          <div className="flex space-x-2">
            <button onClick={() => setShowAddForm(false)} className="text-xs px-4 py-1.5 border border-[#e0ddd5] text-[#4a4a48] rounded-lg hover:bg-[#f0eeeb]">
              {t('common.cancel')}
            </button>
            <button onClick={handleAdd} disabled={!newName.trim() || saving}
              className="text-xs px-4 py-1.5 bg-primary text-white rounded-lg hover:bg-primary-hover disabled:opacity-50">
              {t('common.save')}
            </button>
          </div>
        </div>
      ) : (
        <button onClick={() => setShowAddForm(true)} className="w-full border-2 border-dashed border-[#e0ddd5] text-sm text-[#7a7a78] hover:text-primary hover:border-primary/50 rounded-xl py-3 transition-colors">
          <i className="fas fa-plus mr-1.5"></i>{t('products.addButton')}
        </button>
      )}
    </section>
  );
};

export default ProductsSection;
