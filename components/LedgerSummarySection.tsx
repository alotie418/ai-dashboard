// 设置页 → 台账汇总快照（PR-7B-1，只读管理口径快照）
// 各台账（账户/负债/固定资产/权益）余额各自 SUM、按币种分组（仅启用行）+ 已缴税款独立备查。
// POLICY-NEUTRAL：这不是资产负债表——不分类(资产/负债/权益)、不做合计、不做平衡、不折算、
// 不折旧、不结转、不对冲，不碰 P&L/cashflow/reports。纯 UI 语言驱动（i18n），不读 accountingLocale。
import React, { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { fetchLedgerSummary, type LedgerSummary, type LedgerGroup } from '../services/api';
import { getSystemErrorText } from '../services/systemErrors';

const LedgerSummarySection: React.FC = () => {
  const { t } = useTranslation();
  const [data, setData] = useState<LedgerSummary | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => { reload(); }, []);

  const reload = async () => {
    setLoading(true);
    setError(null);
    try {
      setData(await fetchLedgerSummary());
    } catch (e: any) {
      console.error(e);
      setError(getSystemErrorText(e, t) || t('common.operationFailed'));
    } finally {
      setLoading(false);
    }
  };

  const ccyLabel = (c: string | null) => c || t('ledgerSummary.currencyUnspecified');

  // 单台账小块：标题 + 笔数 + 按币种分组的各行（不跨币种合计、不与其它台账合计）
  const LedgerCard: React.FC<{ labelKey: string; group?: LedgerGroup; memo?: boolean }> = ({ labelKey, group, memo }) => (
    <div className={`border border-[#e0ddd5] rounded-xl overflow-hidden ${memo ? 'bg-[#f9f9f8]/40' : ''}`}>
      <div className="flex items-center justify-between px-4 py-2.5 bg-[#f9f9f8]/60">
        <span className="text-sm font-bold text-[#191918]">{t(labelKey)}</span>
        <span className="text-[11px] text-[#5c5c5a]">{group?.count || 0} {t('ledgerSummary.count')}</span>
      </div>
      <div className="divide-y divide-[#e0ddd5]/70">
        {(!group || group.byCurrency.length === 0) ? (
          <div className="px-4 py-2.5 text-[11px] text-[#8a8a88]">{t('ledgerSummary.noData')}</div>
        ) : group.byCurrency.map((r, i) => (
          <div key={i} className="flex items-center justify-between px-4 py-2.5 text-sm">
            <span className="text-[11px] text-[#5c5c5a]">{ccyLabel(r.currency)} · {r.count} {t('ledgerSummary.count')}</span>
            <span className="font-mono text-[#191918]">{r.total}</span>
          </div>
        ))}
      </div>
    </div>
  );

  return (
    <section className="space-y-6">
      <div>
        <h3 className="text-xl font-bold text-[#191918]">{t('ledgerSummary.title')}</h3>
        <p className="text-xs text-[#6b6b69] mt-1">{t('ledgerSummary.subtitle')}</p>
      </div>

      {/* Strong boundary: management snapshot, NOT a balance sheet; no totals/balance; no FX conversion. */}
      <div className="text-xs text-amber-700 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2 space-y-1">
        <p><i className="fas fa-info-circle mr-1.5"></i>{t('ledgerSummary.snapshotNote')}</p>
        <p><i className="fas fa-circle-exclamation mr-1.5"></i>{t('ledgerSummary.mixedCurrencyNote')}</p>
      </div>
      <div className="text-[11px] text-[#5c5c5a] bg-[#f9f9f8]/60 border border-[#e0ddd5] rounded-lg px-3 py-2">
        {t('disclaimer.report')}
      </div>

      {error && (
        <div className="text-sm text-rose-600 bg-rose-50 border border-rose-200 rounded-lg px-3 py-2">
          <i className="fas fa-exclamation-circle mr-2"></i>{error}
        </div>
      )}

      {loading ? (
        <div className="text-sm text-[#5c5c5a] py-6 text-center">
          <i className="fas fa-spinner fa-spin mr-2"></i>{t('common.loading')}
        </div>
      ) : (
        <div className="space-y-4">
          {/* 四张台账各自罗列——不归类为资产/负债/权益、不做跨台账合计、不做平衡 */}
          <LedgerCard labelKey="ledgerSummary.accountsTotal" group={data?.accounts} />
          <LedgerCard labelKey="ledgerSummary.liabilitiesTotal" group={data?.liabilities} />
          <LedgerCard labelKey="ledgerSummary.fixedAssetsTotal" group={data?.fixedAssets} />
          <LedgerCard labelKey="ledgerSummary.equityTotal" group={data?.equity} />

          {/* 已缴税款：独立备查，不参与任何合计 */}
          <div className="pt-2">
            <p className="text-[11px] text-[#8a8a88] mb-2"><i className="fas fa-receipt mr-1.5"></i>{t('ledgerSummary.taxMemoHeading')}</p>
            <LedgerCard labelKey="ledgerSummary.taxPaidMemo" group={data?.taxPaidMemo} memo />
          </div>
        </div>
      )}
    </section>
  );
};

export default LedgerSummarySection;
