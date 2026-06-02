// US Tax Tools — Mileage Tracking + Home Office Deduction (F stage)
// Only visible when accounting_locale === 'US'

import React, { useState, useEffect, useCallback } from 'react';
import { useTranslation } from 'react-i18next';
import {
  listMileage, createMileage, deleteMileage, fetchMileageSummary,
  fetchHomeOffice, saveHomeOffice, fetchSettings,
  type MileageLog, type MileageSummary, type HomeOfficeData,
} from '../services/api';

interface Props {
  selectedYear?: string;
}

// IRS standard mileage rate (USD/mile) by tax year. Display-only — drives the
// informational note so it reflects the selected accounting year instead of a
// hardcoded 2024 rate. Add new years here as the IRS publishes them.
const US_MILEAGE_RATES: Record<number, number> = { 2024: 0.67, 2025: 0.70, 2026: 0.725 };
const LATEST_MILEAGE_YEAR = Math.max(...Object.keys(US_MILEAGE_RATES).map(Number));

// Resolve the rate for the selected accounting year; if that year has no published
// rate, fall back to the latest known year — and report that actual year so the
// note never shows a rate/year mismatch.
const resolveMileageRate = (selectedYear?: string): { year: number; rate: string } => {
  const requested = Number(selectedYear) || new Date().getFullYear();
  const year = US_MILEAGE_RATES[requested] != null ? requested : LATEST_MILEAGE_YEAR;
  return { year, rate: US_MILEAGE_RATES[year].toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 3 }) };
};

const USTaxToolsPage: React.FC<Props> = ({ selectedYear }) => {
  const { t } = useTranslation();
  const [activeTab, setActiveTab] = useState<'mileage' | 'homeOffice'>('mileage');
  const { year: mileageYear, rate: mileageRate } = resolveMileageRate(selectedYear);
  const [accLocale, setAccLocale] = useState<string | null>(null);
  useEffect(() => {
    fetchSettings().then((s: any) => setAccLocale(s?.accounting_locale || 'CN')).catch(() => setAccLocale('CN'));
  }, []);

  // Defensive guard: page is gated in nav, but if accessed directly with
  // non-US accountingLocale, show a clear "not applicable" message.
  if (accLocale && accLocale !== 'US') {
    return (
      <div className="max-w-3xl mx-auto py-20 text-center">
        <i className="fas fa-flag-usa text-5xl text-[#d1cdc4] mb-6"></i>
        <h2 className="text-xl font-semibold text-[#191918]">{t('usTax.title')}</h2>
        <p className="text-sm text-[#5c5c5a] mt-3 max-w-md mx-auto">{t('usTax.notApplicable')}</p>
      </div>
    );
  }

  return (
    <div className="max-w-7xl mx-auto space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <h2 className="text-2xl font-bold text-[#191918]">{t('usTax.title', 'US Tax Tools')}</h2>

      <div className="flex border-b border-[#e0ddd5]">
        <button onClick={() => setActiveTab('mileage')} className={`px-6 py-2.5 text-sm font-medium border-b-2 transition-colors ${activeTab === 'mileage' ? 'border-[#d97757] text-[#d97757]' : 'border-transparent text-[#7a7a78]'}`}>
          <i className="fas fa-car mr-2"></i>{t('usTax.mileage', 'Mileage Tracking')}
        </button>
        <button onClick={() => setActiveTab('homeOffice')} className={`px-6 py-2.5 text-sm font-medium border-b-2 transition-colors ${activeTab === 'homeOffice' ? 'border-[#d97757] text-[#d97757]' : 'border-transparent text-[#7a7a78]'}`}>
          <i className="fas fa-home mr-2"></i>{t('usTax.homeOffice', 'Home Office')}
        </button>
      </div>

      {activeTab === 'mileage' && <MileageSection mileageRate={mileageRate} mileageYear={mileageYear} />}
      {activeTab === 'homeOffice' && <HomeOfficeSection />}
    </div>
  );
};

// ─── Mileage Section ───
const MileageSection: React.FC<{ mileageRate: string; mileageYear: number }> = ({ mileageRate, mileageYear }) => {
  const { t } = useTranslation();
  const [logs, setLogs] = useState<MileageLog[]>([]);
  const [summary, setSummary] = useState<MileageSummary | null>(null);
  const [loading, setLoading] = useState(true);
  const [showForm, setShowForm] = useState(false);
  const [form, setForm] = useState({ date: new Date().toISOString().split('T')[0], start_location: '', end_location: '', miles: '', purpose: '', round_trip: false });
  const [saving, setSaving] = useState(false);

  const reload = useCallback(async () => {
    setLoading(true);
    try {
      const [l, s] = await Promise.all([listMileage({}), fetchMileageSummary()]);
      setLogs(l);
      setSummary(s);
    } catch { /* ignore */ }
    setLoading(false);
  }, []);

  useEffect(() => { reload(); }, [reload]);

  const handleAdd = async () => {
    if (!form.date || !form.miles || Number(form.miles) <= 0) return;
    setSaving(true);
    try {
      await createMileage({ date: form.date, start_location: form.start_location, end_location: form.end_location, miles: Number(form.miles), purpose: form.purpose, round_trip: form.round_trip ? 1 : 0 });
      setShowForm(false);
      setForm({ date: new Date().toISOString().split('T')[0], start_location: '', end_location: '', miles: '', purpose: '', round_trip: false });
      await reload();
    } catch { /* ignore */ }
    setSaving(false);
  };

  const handleDelete = async (id: string) => {
    await deleteMileage(id);
    await reload();
  };

  return (
    <div className="space-y-6">
      {/* Summary */}
      {summary && (
        <div className="grid grid-cols-3 gap-4">
          <div className="bg-white/80 border border-[#e0ddd5] p-5 rounded-xl">
            <p className="text-[10px] uppercase tracking-widest text-[#5c5c5a] font-bold">{t('usTax.totalTrips', 'Total Trips')}</p>
            <p className="text-2xl font-bold text-[#191918] mt-1">{summary.trips}</p>
          </div>
          <div className="bg-white/80 border border-[#e0ddd5] p-5 rounded-xl">
            <p className="text-[10px] uppercase tracking-widest text-[#5c5c5a] font-bold">{t('usTax.totalMiles', 'Total Miles')}</p>
            <p className="text-2xl font-bold text-[#191918] mt-1">{summary.totalMiles.toLocaleString()}</p>
          </div>
          <div className="bg-white/80 border border-[#e0ddd5] p-5 rounded-xl">
            <p className="text-[10px] tracking-widest text-[#5c5c5a] font-bold">{t('usTax.deduction', 'Deduction (Sch C Line 9)')}</p>
            <p className="text-2xl font-bold text-emerald-600 mt-1">${summary.totalDeduction.toLocaleString()}</p>
          </div>
        </div>
      )}

      {/* Add button */}
      {!showForm ? (
        <button onClick={() => setShowForm(true)} className="flex items-center px-5 py-2.5 bg-[#d97757] hover:bg-[#c56a4a] text-white rounded-xl text-sm font-medium">
          <i className="fas fa-plus mr-2"></i>{t('usTax.addTrip', 'Log a Trip')}
        </button>
      ) : (
        <div className="border border-[#d97757]/30 bg-[#d97757]/5 rounded-xl p-5 space-y-4">
          <h3 className="text-sm font-semibold text-[#191918]">{t('usTax.newTrip', 'New Mileage Entry')}</h3>
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="block text-xs font-medium text-[#4a4a48] mb-1">{t('tableHeaders.date')}</label>
              <input type="date" value={form.date} onChange={e => setForm(f => ({ ...f, date: e.target.value }))} className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm" />
            </div>
            <div>
              <label className="block text-xs font-medium text-[#4a4a48] mb-1">{t('usTax.miles', 'Miles')}</label>
              <input type="number" step="0.1" value={form.miles} onChange={e => setForm(f => ({ ...f, miles: e.target.value }))} placeholder={t('usTax.milesPlaceholder', 'e.g. 25.3')} className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm" />
            </div>
            <div>
              <label className="block text-xs font-medium text-[#4a4a48] mb-1">{t('usTax.from', 'From')}</label>
              <input type="text" value={form.start_location} onChange={e => setForm(f => ({ ...f, start_location: e.target.value }))} placeholder={t('usTax.fromPlaceholder', 'Office')} className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm" />
            </div>
            <div>
              <label className="block text-xs font-medium text-[#4a4a48] mb-1">{t('usTax.to', 'To')}</label>
              <input type="text" value={form.end_location} onChange={e => setForm(f => ({ ...f, end_location: e.target.value }))} placeholder={t('usTax.toPlaceholder', 'Client site')} className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm" />
            </div>
          </div>
          <div>
            <label className="block text-xs font-medium text-[#4a4a48] mb-1">{t('usTax.purpose', 'Business Purpose')}</label>
            <input type="text" value={form.purpose} onChange={e => setForm(f => ({ ...f, purpose: e.target.value }))} placeholder={t('usTax.purposePlaceholder', 'e.g. Client meeting')} className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm" />
          </div>
          <label className="flex items-center space-x-2 text-sm text-[#4a4a48]">
            <input type="checkbox" checked={form.round_trip} onChange={e => setForm(f => ({ ...f, round_trip: e.target.checked }))} className="rounded" />
            <span>{t('usTax.roundTrip', 'Round trip (doubles miles)')}</span>
          </label>
          <div className="flex space-x-2">
            <button onClick={() => setShowForm(false)} className="px-4 py-2 border border-[#e0ddd5] text-[#4a4a48] rounded-lg text-sm">{t('common.cancel')}</button>
            <button onClick={handleAdd} disabled={saving} className="px-4 py-2 bg-[#d97757] text-white rounded-lg text-sm disabled:opacity-50">{saving ? t('common.saving') : t('common.save')}</button>
          </div>
        </div>
      )}

      {/* Table */}
      {loading ? (
        <div className="text-center py-8 text-sm text-[#7a7a78]"><i className="fas fa-spinner fa-spin mr-2"></i></div>
      ) : (
        <div className="border border-[#e0ddd5] rounded-xl overflow-hidden">
          <table className="w-full text-sm">
            <thead className="bg-[#f9f9f8] text-[10px] uppercase tracking-wider text-[#4a4a48]">
              <tr>
                <th className="text-left px-4 py-2.5">{t('tableHeaders.date')}</th>
                <th className="text-left px-4 py-2.5">{t('usTax.route', 'Route')}</th>
                <th className="text-right px-4 py-2.5">{t('usTax.miles', 'Miles')}</th>
                <th className="text-left px-4 py-2.5">{t('usTax.purpose', 'Purpose')}</th>
                <th className="text-right px-4 py-2.5">{t('usTax.deductionShort', 'Deduction')}</th>
                <th className="text-right px-4 py-2.5 w-16"></th>
              </tr>
            </thead>
            <tbody>
              {logs.length === 0 ? (
                <tr><td colSpan={6} className="text-center py-8 text-[#7a7a78]">{t('usTax.noTrips', 'No trips logged yet.')}</td></tr>
              ) : logs.map(log => (
                <tr key={log.id} className="border-t border-[#e0ddd5]/70 hover:bg-[#f9f9f8]/40">
                  <td className="px-4 py-2.5">{log.date}</td>
                  <td className="px-4 py-2.5 text-[#4a4a48]">{log.start_location || '—'} → {log.end_location || '—'}{log.round_trip ? ' ↩' : ''}</td>
                  <td className="px-4 py-2.5 text-right font-mono">{log.miles}</td>
                  <td className="px-4 py-2.5 text-[#5c5c5a]">{log.purpose || '—'}</td>
                  <td className="px-4 py-2.5 text-right font-mono text-emerald-600">${log.deduction.toFixed(2)}</td>
                  <td className="px-4 py-2.5 text-right">
                    <button onClick={() => handleDelete(log.id)} className="text-xs text-rose-500 hover:text-rose-700">{t('common2.delete')}</button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <div className="text-[10px] text-[#7a7a78] bg-[#f9f9f8] border border-[#e0ddd5] rounded-lg p-3">
        <i className="fas fa-info-circle mr-1.5 text-[#d97757]"></i>
        {t('usTax.mileageNote', { rate: mileageRate, year: mileageYear, defaultValue: 'IRS standard mileage rate: ${{rate}}/mile ({{year}}). Deduction auto-calculated and maps to Schedule C Line 9 (Car & Truck Expenses).' })}
      </div>
    </div>
  );
};

// ─── Home Office Section ───
const HomeOfficeSection: React.FC = () => {
  const { t } = useTranslation();
  const [data, setData] = useState<HomeOfficeData | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    fetchHomeOffice().then(setData).finally(() => setLoading(false));
  }, []);

  const handleSave = async (patch: Partial<HomeOfficeData>) => {
    setSaving(true);
    try {
      const updated = await saveHomeOffice(patch);
      setData(updated);
    } catch { /* ignore */ }
    setSaving(false);
  };

  if (loading || !data) return <div className="text-center py-8 text-sm text-[#7a7a78]"><i className="fas fa-spinner fa-spin mr-2"></i></div>;

  return (
    <div className="space-y-6">
      {/* Deduction Result Card */}
      <div className="bg-emerald-50 border border-emerald-200 rounded-xl p-6 text-center">
        <p className="text-[10px] tracking-widest text-emerald-700 font-bold">{t('usTax.homeOfficeDeduction', 'Home Office Deduction (Form 8829)')}</p>
        <p className="text-3xl font-bold text-emerald-600 mt-2">${data.deduction.toLocaleString()}</p>
        <p className="text-xs text-emerald-600/70 mt-1">{t('usTax.scheduleC30', 'Schedule C Line 30')}</p>
      </div>

      {/* Method Toggle */}
      <div className="flex bg-white/80 p-1.5 rounded-xl border border-[#e0ddd5] w-fit">
        <button onClick={() => handleSave({ method: 'simplified' })} className={`px-5 py-2 rounded-lg text-sm font-medium transition-all ${data.method === 'simplified' ? 'bg-[#d97757] text-white' : 'text-[#4a4a48]'}`}>
          {t('usTax.simplified', 'Simplified Method')}
        </button>
        <button onClick={() => handleSave({ method: 'actual' })} className={`px-5 py-2 rounded-lg text-sm font-medium transition-all ${data.method === 'actual' ? 'bg-[#d97757] text-white' : 'text-[#4a4a48]'}`}>
          {t('usTax.actual', 'Actual Expenses')}
        </button>
      </div>

      {/* Simplified Method */}
      {data.method === 'simplified' && (
        <div className="border border-[#e0ddd5] rounded-xl p-6 space-y-4 bg-white/80">
          <h3 className="text-sm font-semibold text-[#191918]">{t('usTax.simplifiedTitle', 'Simplified Method: $5 × sqft (max 300 sqft)')}</h3>
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-xs font-medium text-[#4a4a48] mb-1">{t('usTax.officeSqft', 'Office Area (sqft)')}</label>
              <input type="number" value={data.sqft} onChange={e => handleSave({ sqft: Number(e.target.value) })} className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm" />
            </div>
            <div>
              <label className="block text-xs font-medium text-[#4a4a48] mb-1">{t('usTax.ratePerSqft', 'Rate per sqft')}</label>
              <input type="number" value={data.rate_per_sqft} disabled className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm bg-[#f9f9f8]" />
            </div>
          </div>
          <p className="text-xs text-[#7a7a78]">{t('usTax.simplifiedCalc', 'Calculation')}: min({t('usTax.officeArea', 'office area')}, {data.max_sqft}) × ${data.rate_per_sqft} = <b>${data.deduction}</b></p>
        </div>
      )}

      {/* Actual Expenses Method */}
      {data.method === 'actual' && (
        <div className="border border-[#e0ddd5] rounded-xl p-6 space-y-4 bg-white/80">
          <h3 className="text-sm font-semibold text-[#191918]">{t('usTax.actualTitle', 'Actual Expenses Method')}</h3>
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-xs font-medium text-[#4a4a48] mb-1">{t('usTax.officeSqft', 'Office Area (sqft)')}</label>
              <input type="number" value={data.sqft} onChange={e => handleSave({ sqft: Number(e.target.value) })} className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm" />
            </div>
            <div>
              <label className="block text-xs font-medium text-[#4a4a48] mb-1">{t('usTax.totalHomeSqft', 'Total Home Area (sqft)')}</label>
              <input type="number" value={data.total_home_sqft} onChange={e => handleSave({ total_home_sqft: Number(e.target.value) })} className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm" />
            </div>
            <div>
              <label className="block text-xs font-medium text-[#4a4a48] mb-1">{t('usTax.annualRent', 'Annual Rent')}</label>
              <input type="number" value={data.annual_rent} onChange={e => handleSave({ annual_rent: Number(e.target.value) })} className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm" />
            </div>
            <div>
              <label className="block text-xs font-medium text-[#4a4a48] mb-1">{t('usTax.annualUtilities', 'Annual Utilities')}</label>
              <input type="number" value={data.annual_utilities} onChange={e => handleSave({ annual_utilities: Number(e.target.value) })} className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm" />
            </div>
            <div>
              <label className="block text-xs font-medium text-[#4a4a48] mb-1">{t('usTax.annualInsurance', 'Annual Insurance')}</label>
              <input type="number" value={data.annual_insurance} onChange={e => handleSave({ annual_insurance: Number(e.target.value) })} className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm" />
            </div>
            <div>
              <label className="block text-xs font-medium text-[#4a4a48] mb-1">{t('usTax.annualDepreciation', 'Annual Depreciation')}</label>
              <input type="number" value={data.annual_depreciation} onChange={e => handleSave({ annual_depreciation: Number(e.target.value) })} className="w-full px-3 py-2 border border-[#e0ddd5] rounded-lg text-sm" />
            </div>
          </div>
          <p className="text-xs text-[#7a7a78]">
            {t('usTax.actualCalc', 'Calculation')}: ({data.sqft} / {data.total_home_sqft || 1}) × (${data.annual_rent} + ${data.annual_utilities} + ${data.annual_insurance} + ${data.annual_depreciation}) = <b>${data.deduction}</b>
          </p>
        </div>
      )}

      <div className="text-[10px] text-[#7a7a78] bg-[#f9f9f8] border border-[#e0ddd5] rounded-lg p-3">
        <i className="fas fa-info-circle mr-1.5 text-[#d97757]"></i>
        {t('usTax.homeOfficeNote', 'Simplified method: max $1,500 (300 sqft × $5). Actual method requires tracking actual expenses and prorating by area. Maps to Schedule C Line 30 / Form 8829.')}
      </div>
    </div>
  );
};

export default USTaxToolsPage;
