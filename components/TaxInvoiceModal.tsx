// 正式税务发票关联 弹窗（Phase D）
// ⚠️ 合规边界：仅记录外部（税局认可的开票平台）开具的正式发票——手动标记已开、
// 号码纯手填（永不自动生成）、开票日期、一份附件副本。不提供任何开票功能。
// 附件：选择时复制进 userData/attachments/docs/（原文件不动），路径由「保存」经
// PUT /api/documents/:id/tax-invoice 统一持久化；选了未保存就取消/重选 → discard 清理。
// 作废单据：只读（终态），打开附件仍可用。附件不入 #96 数据库备份（弹窗内明示）。

import React, { useState } from 'react';
import { useTranslation } from 'react-i18next';
import {
  updateDocTaxInvoice, pickDocAttachment, openDocAttachment, discardDocAttachment,
  type BusinessDocument,
} from '../services/api';
import { getSystemErrorText } from '../services/systemErrors';

interface Props {
  doc: BusinessDocument;
  onClose: () => void;
  onSaved: () => void;
}

const TaxInvoiceModal: React.FC<Props> = ({ doc, onClose, onSaved }) => {
  const { t } = useTranslation();
  const readOnly = doc.status === 'void';

  const [issued, setIssued] = useState(!!doc.taxInvoiceIssued);
  const [number, setNumber] = useState(doc.taxInvoiceNumber || '');
  const [date, setDate] = useState(doc.taxInvoiceDate || '');
  // 已保存的附件路径（来自单据）与本次新选的未保存副本分开管理
  const [savedPath, setSavedPath] = useState(doc.taxInvoiceAttachmentPath || '');
  const [pickedUnsaved, setPickedUnsaved] = useState<{ relPath: string; fileName: string } | null>(null);
  const [cleared, setCleared] = useState(false);
  const [saving, setSaving] = useState(false);
  const [msg, setMsg] = useState<{ type: 'error' | 'info'; text: string } | null>(null);

  // 当前生效的附件（优先新选的未保存副本）
  const effectivePath = pickedUnsaved ? pickedUnsaved.relPath : (cleared ? '' : savedPath);
  const effectiveName = pickedUnsaved
    ? pickedUnsaved.fileName
    : (effectivePath ? effectivePath.split('/').pop() || effectivePath : '');

  const errText = (code?: string): string => {
    switch (code) {
      case 'FILE_TOO_LARGE': return t('documents.attachmentTooLarge');
      case 'INVALID_FILE_TYPE': return t('documents.attachmentInvalidType');
      case 'ATTACHMENT_NOT_FOUND': return t('documents.attachmentMissing');
      case 'DISK_FULL': return t('systemError.diskFull');
      case 'DISK_IO': return t('systemError.diskIo');
      case 'READONLY': return t('systemError.readonly');
      default: return t('documents.attachmentFailed');
    }
  };

  const handlePick = async () => {
    setMsg(null);
    try {
      const r = await pickDocAttachment(doc.id);
      if (r.ok && r.relPath) {
        // 重选：先清理上一次未保存的副本
        if (pickedUnsaved) discardDocAttachment(pickedUnsaved.relPath).catch(() => {});
        setPickedUnsaved({ relPath: r.relPath, fileName: r.fileName || r.relPath });
        setCleared(false);
      } else if (r.error) {
        setMsg({ type: 'error', text: errText(r.error) });
      }
      // 取消静默
    } catch {
      setMsg({ type: 'error', text: t('documents.attachmentFailed') });
    }
  };

  const handleOpen = async () => {
    setMsg(null);
    try {
      const r = await openDocAttachment(effectivePath);
      if (!r.ok) setMsg({ type: 'info', text: errText(r.error) });
    } catch {
      setMsg({ type: 'error', text: t('documents.attachmentFailed') });
    }
  };

  const handleRemove = () => {
    setMsg(null);
    if (pickedUnsaved) {
      // 未保存的副本：立即清理
      discardDocAttachment(pickedUnsaved.relPath).catch(() => {});
      setPickedUnsaved(null);
    } else if (savedPath) {
      // 已保存的附件：标记清除，保存时由 handler 删除旧副本
      setCleared(true);
    }
  };

  const handleCancel = () => {
    // 取消时清理本次新选但未保存的副本
    if (pickedUnsaved) discardDocAttachment(pickedUnsaved.relPath).catch(() => {});
    onClose();
  };

  const handleSave = async () => {
    setMsg(null);
    setSaving(true);
    try {
      await updateDocTaxInvoice(doc.id, {
        issued,
        number: number.trim() || null,
        date: date || null,
        attachmentPath: pickedUnsaved ? pickedUnsaved.relPath : (cleared ? null : savedPath || null),
      });
      if (pickedUnsaved) setSavedPath(pickedUnsaved.relPath);
      onSaved();
    } catch (e) {
      setMsg({ type: 'error', text: getSystemErrorText(e, t) || t('documents.saveFailed') });
    } finally {
      setSaving(false);
    }
  };

  const inputCls = 'w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary text-[#191918] transition-all disabled:opacity-50 disabled:cursor-not-allowed';
  const labelCls = 'text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest';

  return (
    <div className="fixed inset-0 z-[10001] flex items-center justify-center px-4">
      <div className="absolute inset-0 bg-black/40 backdrop-blur-sm" onClick={handleCancel}></div>
      <div className="relative w-full max-w-xl max-h-[90vh] overflow-y-auto glass-modal rounded-xl animate-in zoom-in-95 duration-200" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.05)' }}>
        <div className="p-8 border-b border-[#e0ddd5] flex justify-between items-center gap-4">
          <div>
            <h2 className="text-xl font-bold text-[#191918]">{t('documents.taxInvoiceTitle')}</h2>
            <p className="text-xs text-[#5c5c5a] mt-1 font-mono tracking-tight">{doc.docNumber}</p>
          </div>
          <button type="button" onClick={handleCancel} className="flex-shrink-0 text-[#5c5c5a] hover:text-[#191918] transition-colors">
            <i className="fas fa-times text-xl"></i>
          </button>
        </div>

        <div className="p-8 space-y-5">
          {/* 合规提示：仅记录、永不开票 */}
          <div className="text-xs text-amber-700 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2">
            <i className="fas fa-circle-info mr-2"></i>{t('documents.taxInvoiceCompliance')}
          </div>

          {readOnly && (
            <div className="text-xs text-[#5c5c5a] bg-[#f9f9f8] border border-[#e0ddd5] rounded-lg px-3 py-2">
              <i className="fas fa-lock mr-2"></i>{t('documents.taxInvoiceVoidReadOnly')}
            </div>
          )}

          {msg && (
            <div className={`text-sm rounded-lg px-3 py-2 ${msg.type === 'error' ? 'text-rose-600 bg-rose-50 border border-rose-200' : 'text-amber-700 bg-amber-50 border border-amber-200'}`}>
              <i className={`fas mr-2 ${msg.type === 'error' ? 'fa-exclamation-circle' : 'fa-circle-info'}`}></i>{msg.text}
            </div>
          )}

          <label className="flex items-center gap-3 cursor-pointer">
            <input
              type="checkbox"
              name="taxInvoiceIssued"
              checked={issued}
              disabled={readOnly}
              onChange={(e) => setIssued(e.target.checked)}
              className="w-4 h-4 accent-primary"
            />
            <span className="text-sm text-[#191918]">{t('documents.taxInvoiceIssuedLabel')}</span>
          </label>

          <div className="space-y-2">
            <label className={labelCls}>{t('documents.taxInvoiceNumberLabel')}</label>
            <input
              type="text"
              name="taxInvoiceNumber"
              value={number}
              disabled={readOnly}
              onChange={(e) => setNumber(e.target.value)}
              className={inputCls}
            />
            <p className="text-[10px] text-[#5c5c5a]">{t('documents.taxInvoiceNumberHint')}</p>
          </div>

          <div className="space-y-2">
            <label className={labelCls}>{t('documents.taxInvoiceDateLabel')}</label>
            <input
              type="date"
              name="taxInvoiceDate"
              value={date}
              disabled={readOnly}
              onChange={(e) => setDate(e.target.value)}
              className={inputCls}
            />
          </div>

          {/* 附件块 */}
          <div className="space-y-2">
            <label className={labelCls}>{t('documents.taxInvoiceAttachmentLabel')}</label>
            {effectivePath ? (
              <div className="border border-[#e0ddd5] rounded-xl p-3 flex items-center gap-3 bg-[#f9f9f8]/50">
                <i className="fas fa-paperclip text-[#5c5c5a]"></i>
                <span className="text-sm text-[#191918] flex-1 break-all">{effectiveName}</span>
                <button type="button" onClick={handleOpen} className="text-xs font-medium text-primary hover:text-primary-hover transition-colors whitespace-nowrap">
                  {t('documents.attachmentOpen')}
                </button>
                {!readOnly && (
                  <button type="button" onClick={handleRemove} className="text-xs font-medium text-rose-500 hover:text-rose-400 transition-colors whitespace-nowrap">
                    {t('documents.attachmentRemove')}
                  </button>
                )}
              </div>
            ) : (
              !readOnly && (
                <button
                  type="button"
                  onClick={handlePick}
                  className="w-full border-2 border-dashed border-[#e0ddd5] hover:border-primary/50 hover:bg-primary/5 rounded-xl py-3 text-xs text-[#5c5c5a] hover:text-primary transition-all"
                >
                  <i className="fas fa-paperclip mr-2"></i>{t('documents.attachmentPick')}
                </button>
              )
            )}
            <p className="text-[10px] text-[#5c5c5a]">
              <i className="fas fa-triangle-exclamation mr-1.5 text-amber-500"></i>{t('documents.attachmentNotBackedUp')}
            </p>
          </div>

          <div className="flex justify-end gap-3 pt-2">
            <button
              type="button"
              onClick={handleCancel}
              disabled={saving}
              className="px-5 py-2.5 border border-[#e0ddd5] text-[#4a4a48] rounded-lg text-sm font-medium hover:bg-[#f9f9f8] disabled:opacity-50"
            >
              {t('common.cancel')}
            </button>
            {!readOnly && (
              <button
                type="button"
                onClick={handleSave}
                disabled={saving}
                className="bg-primary text-white px-5 py-2.5 rounded-lg text-sm font-medium hover:bg-primary-hover disabled:opacity-50"
              >
                {saving
                  ? <><i className="fas fa-spinner fa-spin mr-2"></i>{t('common.loading')}</>
                  : t('documents.saveButton')}
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
};

export default TaxInvoiceModal;
