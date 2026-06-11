// 业务单据 页面（Phase A CRUD + Phase B PDF 导出）— 报价单/销售单/形式发票/商业发票/对账单
// 仅内部业务单据：非税务发票开具，不接税控/税局，正式发票号码永不自动生成；
// PDF 页脚固定携带「非正式税务发票」免责声明。
// 仅桌面版可用（web 模式无 /api/documents 路由）：非 Electron 显示提示、不发请求。
// 列表金额与 PDF 用每张单据「冻结的会计制度」acc_locale 渲染（不随设置切换漂移）。
// UI-language-only 文案走 documents.*；税种标签经 getTaxLabel（仅显示，零计算口径）。
// PDF 复用 #97 通用 IPC app:exportReportPdf（主进程零改动），模板见 documentPdf.ts。

import React, { useCallback, useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import {
  isDesktop, fetchSettings, listProducts, listDocuments, getDocument, updateDocument, deleteDocument,
  exportReportPdf,
  type BusinessDocument, type BusinessDocType, type Product,
} from '../services/api';
import { formatMoney, getTaxLabel, getProductUnitLabel } from './accountingHelpers';
import { buildDocumentHtml } from './documentPdf';
import DocumentModal from './DocumentModal';

const TYPE_LABEL_KEYS: Record<BusinessDocType, string> = {
  quotation: 'documents.typeQuotation',
  sales_order: 'documents.typeSalesOrder',
  proforma_invoice: 'documents.typeProforma',
  commercial_invoice: 'documents.typeCommercial',
  statement: 'documents.typeStatement',
};

const STATUS_LABEL_KEYS: Record<string, string> = {
  draft: 'documents.statusDraft',
  issued: 'documents.statusIssued',
  void: 'documents.statusVoid',
};

const STATUS_BADGE_CLS: Record<string, string> = {
  draft: 'bg-amber-500/10 text-amber-600 border border-amber-500/20',
  issued: 'bg-emerald-500/10 text-emerald-600 border border-emerald-500/20',
  void: 'bg-gray-400/10 text-gray-500 border border-gray-400/20',
};

const FILTERS: Array<'all' | BusinessDocType> = ['all', 'quotation', 'sales_order', 'proforma_invoice', 'commercial_invoice', 'statement'];

const DocumentsPage: React.FC = () => {
  const { t, i18n } = useTranslation();
  const desktop = isDesktop();
  const [accLocale, setAccLocale] = useState('CN');
  const [filter, setFilter] = useState<'all' | BusinessDocType>('all');
  const [docs, setDocs] = useState<BusinessDocument[]>([]);
  const [isLoading, setIsLoading] = useState(desktop);
  const [error, setError] = useState<string | null>(null);
  const [showModal, setShowModal] = useState(false);
  const [editing, setEditing] = useState<BusinessDocument | null>(null);
  const [products, setProducts] = useState<Product[]>([]);
  const [pdfBusyId, setPdfBusyId] = useState<string | null>(null);
  const [pdfMsg, setPdfMsg] = useState<{ type: 'success' | 'error' | 'info'; text: string } | null>(null);

  useEffect(() => {
    fetchSettings().then((s: any) => {
      if (s.accounting_locale) setAccLocale(s.accounting_locale);
    }).catch(() => {});
  }, []);

  // 商品列表仅供弹窗明细行带出品名/单位/默认成本（桌面版才有 /api/products）
  useEffect(() => {
    if (!desktop) return;
    listProducts().then(setProducts).catch(() => {});
  }, [desktop]);

  const load = useCallback(() => {
    if (!desktop) return;
    setIsLoading(true);
    setError(null);
    listDocuments(filter)
      .then(setDocs)
      .catch((err) => { console.error('Failed to load documents:', err); setError(t('documents.loadFailed')); })
      .finally(() => setIsLoading(false));
  }, [desktop, filter, t]);

  useEffect(() => { load(); }, [load]);

  const openEdit = async (id: string) => {
    setError(null);
    try {
      const full = await getDocument(id);
      setEditing(full);
      setShowModal(true);
    } catch (err) {
      console.error(err);
      setError(t('documents.loadFailed'));
    }
  };

  const changeStatus = async (id: string, status: 'issued' | 'void') => {
    setError(null);
    try {
      await updateDocument(id, { status });
      load();
    } catch (err) {
      console.error(err);
      setError(t('documents.saveFailed'));
    }
  };

  const removeDoc = async (id: string) => {
    setError(null);
    try {
      await deleteDocument(id);
      setDocs((prev) => prev.filter((d) => d.id !== id));
    } catch (err) {
      console.error(err);
      setError(t('documents.saveFailed'));
    }
  };

  // Phase B：导出单据 PDF。标签按该单据冻结的 acc_locale 解析（getTaxLabel + 销售页
  // 同款 CN gate），金额经 formatMoney(冻结制度)；HTML 组装在 documentPdf.ts（数据驱动，
  // 不动 FinancePage）；主进程走 #97 既有通用 IPC app:exportReportPdf。
  const handleExportPdf = async (d: BusinessDocument) => {
    setPdfMsg(null);
    if (!desktop) { setPdfMsg({ type: 'info', text: t('documents.pdfDesktopOnly') }); return; }
    setPdfBusyId(d.id);
    try {
      const full = await getDocument(d.id);
      const s: any = await fetchSettings().catch(() => ({}));
      const company = s?.company_info || null;
      const uiLang = i18n.language;
      const docLocale = full.accLocale || 'CN';
      const taxL = (key: string) => getTaxLabel(docLocale, uiLang, key);
      const html = buildDocumentHtml(full, company, {
        lang: uiLang,
        typeTitle: t(TYPE_LABEL_KEYS[full.docType]),
        voidBadge: full.status === 'void' ? t('documents.statusVoid') : '',
        numberLabel: t('documents.colNumber'),
        dateLabel: t('documents.colDate'),
        validUntilLabel: t('documents.formValidUntil'),
        customerLabel: t('documents.colCustomer'),
        customerTaxIdLabel: t('documents.formCustomerTaxId'),
        customerAddressLabel: t('documents.formCustomerAddress'),
        customerContactLabel: t('documents.formCustomerContact'),
        descriptionLabel: t('documents.itemDescription'),
        qtyLabel: t('documents.itemQty'),
        unitPriceLabel: t('documents.itemUnitPrice'),
        taxRateLabel: taxL('formTaxRate'),
        taxAmountLabel: docLocale !== 'CN' ? taxL('headerTaxAmount') : t('tableHeaders.taxAmount'),
        amountLabel: t('documents.itemAmount'),
        subtotalLabel: t('documents.subtotal'),
        totalLabel: docLocale !== 'CN' ? taxL('headerTotalWithTax') : t('tableHeaders.totalWithTax'),
        notesLabel: t('documents.formNotes'),
        generatedAtLabel: t('documents.pdfGeneratedAt'),
        disclaimer: t('documents.pdfDisclaimer'),
      }, {
        money: (v: number) => formatMoney(v, docLocale),
        unitLabel: (u) => getProductUnitLabel(u, uiLang),
        generatedAt: new Date().toLocaleString(uiLang),
      });
      const safeName = full.docNumber.replace(/[\\/:*?"<>|\s]+/g, '_') || full.id;
      const r = await exportReportPdf(html, `SoloLedger-${safeName}.pdf`);
      if (r.ok && r.path) setPdfMsg({ type: 'success', text: t('documents.pdfExported', { path: r.path }) });
      else if (r.error) setPdfMsg({ type: 'error', text: t('documents.pdfFailed') });
      // ok=false 且无 error = 用户取消保存框 → 静默
    } catch (err) {
      console.error(err);
      setPdfMsg({ type: 'error', text: t('documents.pdfFailed') });
    } finally {
      setPdfBusyId(null);
    }
  };

  return (
    <div className="space-y-6">
      {/* 标题 + 新建 */}
      <div className="flex items-start justify-between gap-4">
        <div>
          <h3 className="text-xl font-bold text-[#191918]">{t('documents.title')}</h3>
          <p className="text-xs text-[#6b6b69] mt-1">{t('documents.subtitle')}</p>
        </div>
        <button
          onClick={() => { setEditing(null); setShowModal(true); }}
          disabled={!desktop}
          className="flex items-center px-4 py-2 bg-[#d97757] hover:bg-[#c56a4a] text-white rounded-lg transition-colors text-sm font-medium disabled:opacity-50 disabled:cursor-not-allowed"
          style={{ boxShadow: '0 4px 16px rgba(217,119,87,0.15)' }}
        >
          <i className="fas fa-plus mr-2"></i>{t('documents.addButton')}
        </button>
      </div>

      {!desktop && (
        <div className="text-sm text-amber-700 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2">
          <i className="fas fa-circle-info mr-2"></i>{t('documents.desktopOnly')}
        </div>
      )}

      {error && (
        <div className="text-sm text-rose-600 bg-rose-50 border border-rose-200 rounded-lg px-3 py-2">
          <i className="fas fa-exclamation-circle mr-2"></i>{error}
        </div>
      )}

      {pdfMsg && (
        <div className={`text-sm rounded-lg px-3 py-2 break-all ${
          pdfMsg.type === 'success' ? 'text-emerald-700 bg-emerald-50 border border-emerald-200'
          : pdfMsg.type === 'error' ? 'text-rose-600 bg-rose-50 border border-rose-200'
          : 'text-amber-700 bg-amber-50 border border-amber-200'}`}>
          <i className={`fas mr-2 ${pdfMsg.type === 'success' ? 'fa-check-circle' : pdfMsg.type === 'error' ? 'fa-exclamation-circle' : 'fa-circle-info'}`}></i>{pdfMsg.text}
        </div>
      )}

      {/* 类型筛选 */}
      <div className="flex flex-wrap gap-1 bg-[#f9f9f8] rounded-lg p-1 border border-[#e0ddd5] w-fit">
        {FILTERS.map((f) => (
          <button
            key={f}
            onClick={() => setFilter(f)}
            className={`px-3 py-1.5 rounded-md text-xs transition-all ${filter === f ? 'bg-[#d97757] text-white shadow-sm' : 'text-[#4a4a48] hover:text-[#191918]'}`}
          >
            {f === 'all' ? t('documents.filterAll') : t(TYPE_LABEL_KEYS[f])}
          </button>
        ))}
      </div>

      {/* 单据列表 */}
      <div className="bg-white/80 border border-[#e0ddd5] rounded-xl overflow-hidden" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.05)' }}>
        <div className="overflow-x-auto">
          <table className="w-full text-left border-collapse">
            <thead>
              <tr className="border-b border-[#e0ddd5] text-[#5c5c5a] text-xs">
                <th className="px-5 py-4 font-medium">{t('documents.colNumber')}</th>
                <th className="px-5 py-4 font-medium">{t('documents.colType')}</th>
                <th className="px-5 py-4 font-medium">{t('documents.colDate')}</th>
                <th className="px-5 py-4 font-medium">{t('documents.colCustomer')}</th>
                <th className="px-5 py-4 font-medium whitespace-nowrap">{t('documents.colTotal')}</th>
                <th className="px-5 py-4 font-medium">{t('documents.colStatus')}</th>
                <th className="px-5 py-4 font-medium">{t('tableHeaders.actions')}</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-[#e0ddd5]/50">
              {docs.map((d) => (
                <tr key={d.id} className="hover:bg-[#f9f9f8]/30 transition-colors">
                  <td className="px-5 py-5 text-sm font-mono text-[#191918] tracking-tight whitespace-nowrap">{d.docNumber}</td>
                  <td className="px-5 py-5 text-sm text-[#4a4a48] whitespace-nowrap">{t(TYPE_LABEL_KEYS[d.docType])}</td>
                  <td className="px-5 py-5 text-sm text-[#4a4a48] whitespace-nowrap">{d.docDate}</td>
                  <td className="px-5 py-5 text-sm text-[#191918] font-medium">{d.customerName}</td>
                  {/* 金额按该单据冻结的制度渲染币种 */}
                  <td className="px-5 py-5 text-sm text-[#191918] font-bold whitespace-nowrap">{formatMoney(d.total, d.accLocale)}</td>
                  <td className="px-5 py-5">
                    <span className={`px-2 py-0.5 rounded-md text-[10px] font-bold ${STATUS_BADGE_CLS[d.status] || STATUS_BADGE_CLS.draft}`}>
                      {t(STATUS_LABEL_KEYS[d.status] || STATUS_LABEL_KEYS.draft)}
                    </span>
                  </td>
                  <td className="px-5 py-5 text-xs font-medium space-x-3 whitespace-nowrap">
                    {d.status === 'draft' && (
                      <button onClick={() => openEdit(d.id)} className="text-[#d97757] hover:text-[#c56a4a] transition-colors">
                        {t('common2.edit')}
                      </button>
                    )}
                    {d.status === 'draft' && (
                      <button onClick={() => changeStatus(d.id, 'issued')} className="text-emerald-600 hover:text-emerald-500 transition-colors">
                        {t('documents.markIssued')}
                      </button>
                    )}
                    {(d.status === 'draft' || d.status === 'issued') && (
                      <button
                        onClick={() => { if (window.confirm(t('documents.voidConfirm'))) changeStatus(d.id, 'void'); }}
                        className="text-amber-600 hover:text-amber-500 transition-colors"
                      >
                        {t('documents.voidAction')}
                      </button>
                    )}
                    {d.status !== 'issued' && (
                      <button
                        onClick={() => { if (window.confirm(t('documents.deleteConfirm'))) removeDoc(d.id); }}
                        className="text-rose-500 hover:text-rose-400 transition-colors"
                      >
                        {t('common2.delete')}
                      </button>
                    )}
                    <button
                      onClick={() => handleExportPdf(d)}
                      disabled={pdfBusyId !== null}
                      className="text-[#5c5c5a] hover:text-[#191918] transition-colors disabled:opacity-50"
                    >
                      {pdfBusyId === d.id ? <i className="fas fa-spinner fa-spin"></i> : t('documents.exportPdf')}
                    </button>
                  </td>
                </tr>
              ))}
              {isLoading && (
                <tr>
                  <td colSpan={7} className="px-6 py-12 text-center text-[#5c5c5a] text-sm">
                    <i className="fas fa-spinner animate-spin mr-2"></i>{t('common.loading')}
                  </td>
                </tr>
              )}
              {!isLoading && docs.length === 0 && (
                <tr>
                  <td colSpan={7} className="px-6 py-12 text-center text-[#5c5c5a] text-sm italic">
                    {t('documents.empty')}
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>

      {showModal && (
        <DocumentModal
          editing={editing}
          accLocale={accLocale}
          products={products}
          onClose={() => { setShowModal(false); setEditing(null); }}
          onSaved={() => { setShowModal(false); setEditing(null); load(); }}
        />
      )}
    </div>
  );
};

export default DocumentsPage;
