// 设置页 → 数据备份 / 恢复（仅桌面版 · 本地 SQLite）
// 备份：调用已加固的 app:exportDb（备份前 wal_checkpoint(TRUNCATE) 再拷主 .db）
// 恢复：app:importDb（校验 → 自动备份当前库 → 关连接 → 原子替换 → 清 wal/shm）→ 必须重启
// 纯 UI-language 文案，零会计/税务含义（与 accountingLocale 解耦），不触碰任何业务计算。
// 非 Electron（web/部署）环境：按钮置灰，显示「仅桌面版可用」，绝不调用 IPC。

import React, { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { backupDatabase, restoreDatabase, relaunchApp, isDesktop, exportTableCsv, type CsvExportTable } from '../services/api';

const CSV_TABLES: { key: CsvExportTable; labelKey: string }[] = [
  { key: 'transactions', labelKey: 'settings.dataBackup.csvTransactions' },
  { key: 'purchases', labelKey: 'settings.dataBackup.csvPurchases' },
  { key: 'sales', labelKey: 'settings.dataBackup.csvSales' },
  { key: 'documents', labelKey: 'settings.dataBackup.csvDocuments' },
];

const DataBackupSection: React.FC = () => {
  const { t } = useTranslation();
  const desktop = isDesktop();
  const [busy, setBusy] = useState<null | 'backup' | 'restore'>(null);
  const [confirmRestore, setConfirmRestore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [backupPath, setBackupPath] = useState<string | null>(null);
  const [restored, setRestored] = useState<{ autoBackupPath?: string } | null>(null);
  const [devRestart, setDevRestart] = useState(false);
  const [csvBusy, setCsvBusy] = useState<CsvExportTable | null>(null);
  const [csvResult, setCsvResult] = useState<{ rows: number; path: string } | null>(null);

  // 把后端错误码翻成本地化文案
  const errText = (code?: string): string => {
    switch (code) {
      case 'INVALID_FILE':
      case 'INTEGRITY_FAILED':
        return t('settings.dataBackup.invalidFile');
      case 'NEWER_VERSION':
        return t('settings.dataBackup.newerVersion');
      case 'AUTOBACKUP_FAILED':
        return t('settings.dataBackup.autoBackupFailed');
      case 'DISK_FULL':
        return t('systemError.diskFull');
      case 'DISK_IO':
        return t('systemError.diskIo');
      case 'READONLY':
        return t('systemError.readonly');
      default:
        return t('settings.dataBackup.error');
    }
  };

  const handleBackup = async () => {
    setError(null); setBackupPath(null); setRestored(null); setBusy('backup');
    try {
      const r = await backupDatabase();
      if (r.ok && r.path) setBackupPath(r.path);
      else if (r.error) setError(errText(r.error));
      // r.ok === false 且无 error = 用户在保存框点了取消 → 静默
    } catch (e: any) {
      setError(e?.message || t('settings.dataBackup.error'));
    } finally {
      setBusy(null);
    }
  };

  const handleRestart = async () => {
    try {
      const r = await relaunchApp();
      // 开发模式不真正重启 → 提示手动重跑；生产模式进程会退出并重启，无需在此渲染
      if (r && r.devMode) setDevRestart(true);
    } catch { /* ignore */ }
  };

  const handleRestore = async () => {
    setError(null); setBackupPath(null); setBusy('restore');
    try {
      const r = await restoreDatabase();
      if (r.ok) { setConfirmRestore(false); setRestored({ autoBackupPath: r.autoBackupPath }); }
      else if (r.error) setError(errText(r.error));
      // 取消静默
    } catch (e: any) {
      setError(e?.message || t('settings.dataBackup.error'));
    } finally {
      setBusy(null);
    }
  };

  const handleCsv = async (table: CsvExportTable) => {
    setError(null); setCsvResult(null); setCsvBusy(table);
    try {
      const r = await exportTableCsv(table);
      if (r.ok && r.path != null) setCsvResult({ rows: r.rows ?? 0, path: r.path });
      else if (r.error) setError(errText(r.error)); // §2A：DISK_* → systemError.*；其余仍回退通用导出失败
      // r.ok === false 且无 error = 用户取消保存框 → 静默
    } catch (e: any) {
      setError(e?.message || t('settings.dataBackup.error'));
    } finally {
      setCsvBusy(null);
    }
  };

  return (
    <section className="space-y-6">
      <div>
        <h3 className="text-xl font-bold text-[#191918]">{t('settings.dataBackup.title')}</h3>
        <p className="text-xs text-[#6b6b69] mt-1">{t('settings.dataBackup.subtitle')}</p>
      </div>

      {!desktop && (
        <div className="text-sm text-amber-700 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2">
          <i className="fas fa-circle-info mr-2"></i>{t('settings.dataBackup.desktopOnly')}
        </div>
      )}

      {error && (
        <div className="text-sm text-rose-600 bg-rose-50 border border-rose-200 rounded-lg px-3 py-2">
          <i className="fas fa-exclamation-circle mr-2"></i>{error}
        </div>
      )}

      {/* 备份 */}
      <div className="border border-[#e0ddd5] rounded-xl p-5 bg-white space-y-3">
        <div>
          <p className="text-sm font-bold text-[#191918]">{t('settings.dataBackup.backupTitle')}</p>
          <p className="text-xs text-[#6b6b69] mt-1">{t('settings.dataBackup.backupHint')}</p>
        </div>
        <button
          onClick={handleBackup}
          disabled={!desktop || busy !== null}
          className="bg-primary text-white px-5 py-2.5 rounded-lg text-sm font-medium hover:bg-primary-hover disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {busy === 'backup'
            ? <><i className="fas fa-spinner fa-spin mr-2"></i>{t('common.loading')}</>
            : <><i className="fas fa-download mr-2"></i>{t('settings.dataBackup.backupButton')}</>}
        </button>
        {backupPath && (
          <div className="text-xs text-emerald-700 bg-emerald-50 border border-emerald-200 rounded-lg px-3 py-2 break-all">
            <i className="fas fa-check-circle mr-2"></i>{t('settings.dataBackup.backupSuccess', { path: backupPath })}
          </div>
        )}
      </div>

      {/* 恢复 */}
      <div className="border border-[#e0ddd5] rounded-xl p-5 bg-white space-y-3">
        <div>
          <p className="text-sm font-bold text-[#191918]">{t('settings.dataBackup.restoreTitle')}</p>
          <p className="text-xs text-[#6b6b69] mt-1">{t('settings.dataBackup.restoreHint')}</p>
        </div>

        {restored ? (
          <div className="border border-emerald-200 bg-emerald-50/50 rounded-lg p-4 space-y-3">
            <div className="text-sm text-emerald-700 font-medium">
              <i className="fas fa-check-circle mr-2"></i>{t('settings.dataBackup.restoreSuccess', { path: restored.autoBackupPath || '' })}
            </div>
            <div className="text-xs text-[#4a4a48]">
              <i className="fas fa-triangle-exclamation mr-1.5 text-amber-500"></i>{t('settings.dataBackup.restartRequired')}
            </div>
            <button
              onClick={handleRestart}
              className="bg-[#191918] text-white px-5 py-2.5 rounded-lg text-sm font-medium hover:bg-black"
            >
              <i className="fas fa-rotate-right mr-2"></i>{t('settings.dataBackup.restartNow')}
            </button>
            {devRestart && (
              <div className="text-xs text-amber-700 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2">
                <i className="fas fa-circle-info mr-2"></i>{t('settings.dataBackup.devModeRestart')}
              </div>
            )}
          </div>
        ) : confirmRestore ? (
          <div className="border border-rose-200 bg-rose-50 rounded-lg p-4 space-y-3">
            <div className="text-xs text-rose-700 font-medium">
              <i className="fas fa-triangle-exclamation mr-1.5"></i>{t('settings.dataBackup.restoreWarning')}
            </div>
            <div className="flex space-x-2">
              <button
                onClick={() => setConfirmRestore(false)}
                disabled={busy !== null}
                className="text-xs px-3 py-1.5 border border-[#e0ddd5] text-[#4a4a48] rounded disabled:opacity-50"
              >
                {t('common.cancel')}
              </button>
              <button
                onClick={handleRestore}
                disabled={busy !== null}
                className="text-xs px-3 py-1.5 bg-rose-600 text-white rounded disabled:opacity-50"
              >
                {busy === 'restore'
                  ? <><i className="fas fa-spinner fa-spin mr-1.5"></i>{t('common.loading')}</>
                  : t('settings.dataBackup.restoreConfirm')}
              </button>
            </div>
          </div>
        ) : (
          <button
            onClick={() => { setError(null); setBackupPath(null); setConfirmRestore(true); }}
            disabled={!desktop || busy !== null}
            className="border border-rose-300 text-rose-600 px-5 py-2.5 rounded-lg text-sm font-medium hover:bg-rose-50 disabled:opacity-50 disabled:cursor-not-allowed"
          >
            <i className="fas fa-rotate-left mr-2"></i>{t('settings.dataBackup.restoreButton')}
          </button>
        )}
      </div>

      {/* 结构化 CSV 导出（供会计师对接 / 迁出） */}
      <div className="border border-[#e0ddd5] rounded-xl p-5 bg-white space-y-3">
        <div>
          <p className="text-sm font-bold text-[#191918]">{t('settings.dataBackup.csvTitle')}</p>
          <p className="text-xs text-[#6b6b69] mt-1">{t('settings.dataBackup.csvHint')}</p>
        </div>
        <div className="flex flex-wrap gap-2">
          {CSV_TABLES.map(({ key, labelKey }) => (
            <button
              key={key}
              onClick={() => handleCsv(key)}
              disabled={!desktop || csvBusy !== null}
              className="border border-[#e0ddd5] text-[#4a4a48] px-4 py-2 rounded-lg text-sm font-medium hover:bg-[#f7f6f2] disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {csvBusy === key
                ? <><i className="fas fa-spinner fa-spin mr-2"></i>{t('common.loading')}</>
                : <><i className="fas fa-file-csv mr-2"></i>{t(labelKey)}</>}
            </button>
          ))}
        </div>
        {csvResult && (
          <div className="text-xs text-emerald-700 bg-emerald-50 border border-emerald-200 rounded-lg px-3 py-2 break-all">
            <i className="fas fa-check-circle mr-2"></i>{t('settings.dataBackup.csvSuccess', { rows: csvResult.rows, path: csvResult.path })}
          </div>
        )}
      </div>
    </section>
  );
};

export default DataBackupSection;
