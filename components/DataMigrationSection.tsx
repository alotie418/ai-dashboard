// 设置页 → 数据迁移（C 阶段）
// 把旧 sales/purchases 数据一键转入新的 transactions 表
// 提供回滚（删除已迁移 transactions，旧表保持不变）

import React, { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import {
  detectLegacyData, runLegacyMigration, rollbackLegacyMigration, fetchSettings,
  type LegacyDetectResult, type MigrationRunResult,
} from '../services/api';
import { getTaxLabel } from './accountingHelpers';

const DataMigrationSection: React.FC = () => {
  const { t, i18n } = useTranslation();
  const [accLocale, setAccLocale] = useState('CN');
  useEffect(() => { fetchSettings().then((s: any) => { if (s?.accounting_locale) setAccLocale(s.accounting_locale); }).catch(() => {}); }, []);
  // US accountingLocale shows user-facing wording (no internal table/field names);
  // other locales keep their existing text. Three helpers: usLabel for i18n-keyed
  // strings, usText for hardcoded fallbacks, usCount for {count}-interpolated.
  const usLabel = (taxKey: string, i18nKey: string, fallback: string) => accLocale === 'US' ? getTaxLabel(accLocale, i18n.language, taxKey) : t(i18nKey, fallback);
  const usText = (taxKey: string, fallback: string) => accLocale === 'US' ? getTaxLabel(accLocale, i18n.language, taxKey) : fallback;
  const usCount = (taxKey: string, i18nKey: string, fallback: string, count: number) => accLocale === 'US' ? getTaxLabel(accLocale, i18n.language, taxKey).replace(/\{count\}/g, String(count)) : t(i18nKey, fallback, { count });
  const [detect, setDetect] = useState<LegacyDetectResult | null>(null);
  const [loading, setLoading] = useState(true);
  const [running, setRunning] = useState(false);
  const [rolling, setRolling] = useState(false);
  const [result, setResult] = useState<MigrationRunResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [confirmRollback, setConfirmRollback] = useState(false);

  const reload = async () => {
    setLoading(true);
    setError(null);
    try {
      const d = await detectLegacyData();
      setDetect(d);
    } catch (e: any) {
      setError(e?.message || 'Detection failed');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => { reload(); }, []);

  const handleRun = async () => {
    setRunning(true);
    setError(null);
    setResult(null);
    try {
      const r = await runLegacyMigration({});
      setResult(r);
      await reload();
    } catch (e: any) {
      setError(e?.message || 'Migration failed');
    } finally {
      setRunning(false);
    }
  };

  const handleRollback = async () => {
    setRolling(true);
    setError(null);
    try {
      await rollbackLegacyMigration();
      setResult(null);
      setConfirmRollback(false);
      await reload();
    } catch (e: any) {
      setError(e?.message || 'Rollback failed');
    } finally {
      setRolling(false);
    }
  };

  const totalPending = detect ? (detect.sales.pending + detect.purchases.pending) : 0;
  const totalMigrated = detect ? (detect.sales.migrated + detect.purchases.migrated) : 0;
  const hasAnyMigrated = totalMigrated > 0;

  return (
    <section className="space-y-6">
      <div>
        <h3 className="text-xl font-bold text-[#191918]">
          {t('settings.dataMigration.title', '数据迁移')}
        </h3>
        <p className="text-xs text-[#6b6b69] mt-1">
          {usLabel('dmSubtitle', 'settings.dataMigration.subtitle', '把旧版本的 sales/purchases 数据一键迁移到新的 transactions 表（国际化数据模型）。旧表保留不删除，30 天内可回滚。')}
        </p>
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
      ) : detect && (!detect.sales.exists && !detect.purchases.exists) ? (
        <div className="text-sm text-emerald-700 bg-emerald-50 border border-emerald-200 rounded-lg px-4 py-3">
          <i className="fas fa-check-circle mr-2"></i>
          {usLabel('dmNoLegacy', 'settings.dataMigration.noLegacy', '本数据库不存在旧版 sales/purchases 表，无需迁移。')}
        </div>
      ) : detect && (
        <>
          {/* 状态卡 */}
          <div className="grid grid-cols-2 gap-3">
            <div className="border border-[#e0ddd5] rounded-xl p-4 bg-white">
              <div className="text-[10px] uppercase tracking-wider text-[#7a7a78] mb-1">{usText('dmCardSales', 'sales（旧表 → income）')}</div>
              <div className="text-2xl font-bold text-[#191918]">{detect.sales.total}</div>
              <div className="text-[11px] text-[#5c5c5a] mt-1">
                <span className="text-emerald-600">{t('settings.dataMigration.migrated', '已迁移')}: {detect.sales.migrated}</span>
                {' · '}
                <span className="text-amber-600">{t('settings.dataMigration.pending', '待迁移')}: {detect.sales.pending}</span>
              </div>
            </div>
            <div className="border border-[#e0ddd5] rounded-xl p-4 bg-white">
              <div className="text-[10px] uppercase tracking-wider text-[#7a7a78] mb-1">{usText('dmCardPurchases', 'purchases（旧表 → expense）')}</div>
              <div className="text-2xl font-bold text-[#191918]">{detect.purchases.total}</div>
              <div className="text-[11px] text-[#5c5c5a] mt-1">
                <span className="text-emerald-600">{t('settings.dataMigration.migrated', '已迁移')}: {detect.purchases.migrated}</span>
                {' · '}
                <span className="text-amber-600">{t('settings.dataMigration.pending', '待迁移')}: {detect.purchases.pending}</span>
              </div>
            </div>
          </div>

          {/* 迁移结果 */}
          {result && (
            <div className="border border-emerald-200 bg-emerald-50/40 rounded-xl p-4">
              <div className="text-sm font-semibold text-emerald-700 mb-2">
                <i className="fas fa-check-circle mr-2"></i>
                {t('settings.dataMigration.runSuccess', '迁移完成')}
              </div>
              <div className="text-xs text-[#4a4a48] space-y-1">
                {accLocale === 'US' ? (
                  <>
                    <div>{usText('dmResultIncome', '收入记录已迁移')}: <b>{result.salesMigrated}</b></div>
                    <div>{usText('dmResultExpense', '费用记录已迁移')}: <b>{result.purchasesMigrated}</b></div>
                  </>
                ) : (
                  <>
                    <div>sales: <b>{result.salesMigrated}</b> migrated, {result.salesSkipped} skipped</div>
                    <div>purchases: <b>{result.purchasesMigrated}</b> migrated, {result.purchasesSkipped} skipped</div>
                  </>
                )}
                {result.errors.length > 0 && (
                  <details className="mt-2">
                    <summary className="cursor-pointer text-rose-600">{result.errors.length} {t('settings.dataMigration.errors', '个错误')}</summary>
                    <div className="mt-1 max-h-32 overflow-y-auto text-[10px] font-mono bg-white border border-[#e0ddd5] rounded p-2">
                      {result.errors.map((e, i) => (
                        <div key={i}>{accLocale === 'US' ? e.error : `${e.legacy_table}/${e.legacy_id}: ${e.error}`}</div>
                      ))}
                    </div>
                  </details>
                )}
              </div>
            </div>
          )}

          {/* 操作 */}
          <div className="space-y-2">
            <button
              onClick={handleRun}
              disabled={running || totalPending === 0}
              className="w-full bg-[#d97757] text-white py-2.5 rounded-lg text-sm font-medium hover:bg-[#c4694d] disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {running ? (
                <><i className="fas fa-spinner fa-spin mr-2"></i>{t('settings.dataMigration.running', '迁移中...')}</>
              ) : totalPending === 0 ? (
                t('settings.dataMigration.allDone', '所有数据已迁移')
              ) : (
                <><i className="fas fa-arrow-right mr-2"></i>{t('settings.dataMigration.runButton', '迁移 {{count}} 条待处理数据', { count: totalPending })}</>
              )}
            </button>

            {hasAnyMigrated && (
              confirmRollback ? (
                <div className="border border-rose-200 bg-rose-50 rounded-lg p-3 space-y-2">
                  <div className="text-xs text-rose-700 font-medium">
                    <i className="fas fa-exclamation-triangle mr-1.5"></i>
                    {usCount('dmRollbackConfirm', 'settings.dataMigration.rollbackConfirm', '确认回滚？这将删除 {{count}} 条已迁移的 transactions，旧 sales/purchases 数据保持不变。', totalMigrated)}
                  </div>
                  <div className="flex space-x-2">
                    <button onClick={() => setConfirmRollback(false)} className="text-xs px-3 py-1 border border-[#e0ddd5] text-[#4a4a48] rounded">{t('common.cancel')}</button>
                    <button onClick={handleRollback} disabled={rolling} className="text-xs px-3 py-1 bg-rose-600 text-white rounded disabled:opacity-50">
                      {rolling ? <><i className="fas fa-spinner fa-spin mr-1"></i>{t('common.loading')}</> : t('settings.dataMigration.rollbackButton', '确认回滚')}
                    </button>
                  </div>
                </div>
              ) : (
                <button
                  onClick={() => setConfirmRollback(true)}
                  className="w-full text-xs text-rose-600 hover:text-rose-700 py-1"
                >
                  <i className="fas fa-undo mr-1"></i>
                  {usCount('dmRollback', 'settings.dataMigration.rollback', '回滚迁移（删除已迁移的 {{count}} 条 transactions）', totalMigrated)}
                </button>
              )
            )}
          </div>

          <div className="text-[10px] text-[#7a7a78] bg-[#f9f9f8] border border-[#e0ddd5] rounded-lg p-3 space-y-1">
            <div><i className="fas fa-info-circle mr-1.5 text-[#d97757]"></i>{usLabel('dmNote1', 'settings.dataMigration.note1', 'sales → income / purchases → expense; defaults to the current accounting locale’s first income / COGS category')}</div>
            <div className="ml-4">{usLabel('dmNote2', 'settings.dataMigration.note2', 'Legacy tables are kept and can be rolled back at any time')}</div>
            <div className="ml-4">{usLabel('dmNote3', 'settings.dataMigration.note3', 'Migration records are written to legacy_migrations to prevent duplicates')}</div>
            <div className="ml-4">{usLabel('dmNote4', 'settings.dataMigration.note4', 'Legacy fields (quantity / unit price / shipping) are preserved in source_meta JSON')}</div>
          </div>
        </>
      )}
    </section>
  );
};

export default DataMigrationSection;
