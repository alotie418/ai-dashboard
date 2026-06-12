import React, { useState, useRef, useCallback, useEffect } from 'react';
import { useTranslation } from 'react-i18next';
import Papa from 'papaparse';
import { batchCreateSales, batchCreatePurchases, fetchSettings } from '../services/api';
import { getCurrencySymbol } from './accountingHelpers';

interface Props {
  type: 'sales' | 'purchases';
  onClose: () => void;
  onSuccess: () => void;
}

const SALES_FIELDS = [
  { key: 'id', labelKey: 'csvImport.id', required: false },
  { key: 'date', labelKey: 'csvImport.date', required: true },
  { key: 'customer', labelKey: 'csvImport.customer', required: true },
  { key: 'tons', labelKey: 'csvImport.quantity', required: true },
  { key: 'pricePerTon', labelKey: 'csvImport.unitPrice', required: false },
  { key: 'totalAmount', labelKey: 'csvImport.totalAmount', required: true },
  { key: 'taxRate', labelKey: 'csvImport.taxRate', required: false },
  { key: 'shippingCost', labelKey: 'csvImport.shipping', required: false },
  { key: 'invoiceNumber', labelKey: 'csvImport.invoiceNumber', required: false },
  { key: 'invoiceStatus', labelKey: 'csvImport.invoiceStatus', required: false },
  { key: 'due_date', labelKey: 'csvImport.dueDate', required: false },
];

const PURCHASE_FIELDS = [
  { key: 'id', labelKey: 'csvImport.id', required: false },
  { key: 'date', labelKey: 'csvImport.date', required: true },
  { key: 'supplier', labelKey: 'csvImport.supplier', required: true },
  { key: 'tons', labelKey: 'csvImport.quantity', required: true },
  { key: 'pricePerTon', labelKey: 'csvImport.unitPrice', required: false },
  { key: 'totalAmount', labelKey: 'csvImport.totalAmount', required: true },
  { key: 'taxRate', labelKey: 'csvImport.taxRate', required: false },
  { key: 'invoiceNumber', labelKey: 'csvImport.invoiceNumber', required: false },
  { key: 'invoiceStatus', labelKey: 'csvImport.invoiceStatus', required: false },
  { key: 'due_date', labelKey: 'csvImport.dueDate', required: false },
];

// Auto-detect CSV header to app field
function autoMapHeaders(headers: string[], fields: { key: string }[]): Record<string, string> {
  const mapping: Record<string, string> = {};
  const aliases: Record<string, string[]> = {
    date: ['日期', 'date', '时间'],
    customer: ['客户', 'customer', '客户名', '买方'],
    supplier: ['供应商', 'supplier', '卖方', '供货商'],
    tons: ['吨数', 'tons', '数量', '重量', 'quantity', 'weight'],
    pricePerTon: ['单价', 'price_per_ton', '吨价', 'unit_price'],
    totalAmount: ['总金额', 'total', 'amount', '金额', '总额', 'total_amount'],
    taxRate: ['税率', 'tax_rate', 'tax'],
    shippingCost: ['运费', 'shipping', 'freight'],
    invoiceNumber: ['发票号', 'invoice_no', 'invoice', '发票编号'],
    invoiceStatus: ['发票状态', 'invoice_status', '状态'],
    due_date: ['到期日', 'due_date', '应收日期', '应付日期', '账期'],
    id: ['id', 'ID', '编号'],
  };

  for (const header of headers) {
    const lowerHeader = header.toLowerCase().trim();
    for (const field of fields) {
      const fieldAliases = aliases[field.key] || [field.key];
      if (fieldAliases.some(a => lowerHeader === a.toLowerCase() || lowerHeader.includes(a.toLowerCase()))) {
        mapping[header] = field.key;
        break;
      }
    }
  }
  return mapping;
}

const CsvImportModal: React.FC<Props> = ({ type, onClose, onSuccess }) => {
  const { t } = useTranslation();
  const [accLocale, setAccLocale] = useState<string>('CN');
  useEffect(() => {
    fetchSettings().then((s: any) => {
      if (s?.accounting_locale) setAccLocale(s.accounting_locale);
    }).catch(() => {});
  }, []);
  const currSym = getCurrencySymbol(accLocale);
  const [step, setStep] = useState<1 | 2 | 3 | 4>(1);
  const [csvData, setCsvData] = useState<any[]>([]);
  const [headers, setHeaders] = useState<string[]>([]);
  const [mapping, setMapping] = useState<Record<string, string>>({});
  const [fileName, setFileName] = useState('');
  const [importing, setImporting] = useState(false);
  const [result, setResult] = useState<{ success: number; failed: number; errors: { row: number; errors: string[] }[] } | null>(null);
  const [dragActive, setDragActive] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);

  const fields = type === 'sales' ? SALES_FIELDS : PURCHASE_FIELDS;

  const reset = useCallback(() => {
    setStep(1);
    setCsvData([]);
    setHeaders([]);
    setMapping({});
    setFileName('');
    setImporting(false);
    setResult(null);
  }, []);

  const handleClose = () => {
    reset();
    onClose();
  };

  const processFile = (file: File) => {
    setFileName(file.name);
    const isExcel = file.name.endsWith('.xlsx') || file.name.endsWith('.xls');

    if (isExcel) {
      // Dynamic import for xlsx
      import('xlsx').then((XLSX) => {
        const reader = new FileReader();
        reader.onload = (e) => {
          const data = new Uint8Array(e.target?.result as ArrayBuffer);
          const workbook = XLSX.read(data, { type: 'array' });
          const sheet = workbook.Sheets[workbook.SheetNames[0]];
          const json = XLSX.utils.sheet_to_json(sheet, { header: 1 }) as any[][];
          if (json.length < 2) return;
          const hdrs = json[0].map(String);
          setHeaders(hdrs);
          const rows = json.slice(1).map(row => {
            const obj: any = {};
            hdrs.forEach((h, i) => { obj[h] = row[i] ?? ''; });
            return obj;
          });
          setCsvData(rows);
          setMapping(autoMapHeaders(hdrs, fields));
          setStep(2);
        };
        reader.readAsArrayBuffer(file);
      }).catch(() => alert('Excel 解析失败，请尝试 CSV 格式'));
    } else {
      Papa.parse(file, {
        header: true,
        skipEmptyLines: true,
        complete: (results) => {
          if (results.data.length === 0) return;
          const hdrs = results.meta.fields || [];
          setHeaders(hdrs);
          setCsvData(results.data);
          setMapping(autoMapHeaders(hdrs, fields));
          setStep(2);
        },
        error: () => alert('CSV 解析失败，请检查文件格式'),
      });
    }
  };

  const handleDrop = (e: React.DragEvent) => {
    e.preventDefault();
    setDragActive(false);
    const file = e.dataTransfer.files[0];
    if (file) processFile(file);
  };

  const mappedRecords = csvData.map((row, idx) => {
    const record: any = {};
    for (const [csvHeader, appField] of Object.entries(mapping)) {
      if (appField) {
        let val = row[csvHeader];
        if (['tons', 'pricePerTon', 'totalAmount', 'taxRate', 'shippingCost'].includes(appField)) {
          const cleaned = String(val).replace(/[,，]/g, '');
          const numMatch = cleaned.match(/[\d.]+/);
          val = numMatch ? parseFloat(numMatch[0]) : 0;
        }
        record[appField] = val;
      }
    }
    // Generate ID if not mapped
    if (!record.id) record.id = `${type === 'sales' ? 'sale' : 'purchase'}-import-${Date.now()}-${idx}`;
    // Calculate derived fields
    if (!record.pricePerTon && record.totalAmount && record.tons) {
      record.pricePerTon = Math.round((record.totalAmount / record.tons) * 100) / 100;
    }
    const taxRate = record.taxRate || 13;
    record.taxRate = taxRate;
    record.amountWithoutTax = record.totalAmount;
    record.taxAmount = Math.round((record.totalAmount * (taxRate / 100)) * 100) / 100;
    record.totalAmount = Math.round((record.amountWithoutTax + record.taxAmount) * 100) / 100;
    return record;
  });

  const validateRecord = (r: any) => {
    const errors: string[] = [];
    if (!r.date || !/^\d{4}-\d{2}-\d{2}$/.test(r.date)) errors.push('日期格式错误(需要YYYY-MM-DD)');
    if (type === 'sales' && !r.customer) errors.push('缺少客户名');
    if (type === 'purchases' && !r.supplier) errors.push('缺少供应商');
    if (!r.totalAmount || r.totalAmount <= 0) errors.push('总金额须大于0');
    return errors;
  };

  const handleImport = async () => {
    setImporting(true);
    try {
      const batchFn = type === 'sales' ? batchCreateSales : batchCreatePurchases;
      const res = await batchFn(mappedRecords);
      setResult(res);
      setStep(4);
      if (res.success > 0) onSuccess();
    } catch (err: any) {
      setResult({ success: 0, failed: mappedRecords.length, errors: [{ row: 0, errors: [err.message || '导入失败'] }] });
      setStep(4);
    } finally {
      setImporting(false);
    }
  };

  const downloadTemplate = () => {
    const templateFields = fields.map(f => t((f as any).labelKey));
    const exampleRow = type === 'sales'
      ? ['', '2026-03-01', t('csvImport.exampleCustomer'), '10', '3500', '35000', '13', '500', 'FP-001', t('csvImport.exampleIssued'), '2026-04-01']
      : ['', '2026-03-01', t('csvImport.exampleSupplier'), '10', '3000', '30000', '13', '', 'FP-001', t('csvImport.exampleReceived'), '2026-04-01'];
    const csv = [templateFields.join(','), exampleRow.join(',')].join('\n');
    const blob = new Blob(['\uFEFF' + csv], { type: 'text/csv;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `${t(type === 'sales' ? 'csvImport.templateSales' : 'csvImport.templatePurchases')}.csv`;
    a.click();
    URL.revokeObjectURL(url);
  };

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-4">
      <div className="glass-modal rounded-2xl w-full max-w-3xl max-h-[90vh] overflow-hidden">
        {/* Header */}
        <div className="flex items-center justify-between px-6 py-4 border-b border-[#e0ddd5]">
          <h3 className="text-lg font-bold text-[#191918]">
            <i className="fas fa-file-import mr-2 text-primary"></i>
            批量导入{type === 'sales' ? '销售' : '采购'}记录
          </h3>
          <button onClick={handleClose} className="text-[#7a7a78] hover:text-[#191918]">
            <i className="fas fa-times text-lg"></i>
          </button>
        </div>

        {/* Steps indicator */}
        <div className="flex items-center px-6 py-3 bg-[#f9f9f8] border-b border-[#e0ddd5]">
          {['上传文件', '列映射', '预览验证', '导入结果'].map((label, i) => (
            <div key={i} className="flex items-center">
              <div className={`w-7 h-7 rounded-full flex items-center justify-center text-xs font-bold ${
                step > i + 1 ? 'bg-green-500 text-white' : step === i + 1 ? 'bg-primary text-white' : 'bg-[#e0ddd5] text-[#7a7a78]'
              }`}>{step > i + 1 ? '✓' : i + 1}</div>
              <span className={`ml-1.5 text-xs ${step === i + 1 ? 'text-[#191918] font-medium' : 'text-[#7a7a78]'}`}>{label}</span>
              {i < 3 && <div className="w-8 h-px bg-[#e0ddd5] mx-2"></div>}
            </div>
          ))}
        </div>

        {/* Content */}
        <div className="p-6 overflow-y-auto max-h-[60vh]">
          {/* Step 1: Upload */}
          {step === 1 && (
            <div>
              <div
                onDrop={handleDrop}
                onDragOver={(e) => { e.preventDefault(); setDragActive(true); }}
                onDragLeave={() => setDragActive(false)}
                onClick={() => fileInputRef.current?.click()}
                className={`border-2 border-dashed rounded-xl p-12 text-center cursor-pointer transition-all ${
                  dragActive ? 'border-primary bg-primary/5' : 'border-[#e0ddd5] hover:border-primary/50'
                }`}
              >
                <i className="fas fa-cloud-upload-alt text-4xl text-primary mb-3"></i>
                <p className="text-[#191918] font-medium mb-1">拖拽文件到这里，或点击选择</p>
                <p className="text-xs text-[#7a7a78]">支持 CSV、Excel(.xlsx) 文件，最多 500 条</p>
                <input ref={fileInputRef} type="file" accept=".csv,.xlsx,.xls" className="hidden"
                  onChange={(e) => { if (e.target.files?.[0]) processFile(e.target.files[0]); }} />
              </div>
              <button onClick={downloadTemplate} className="mt-4 text-sm text-primary hover:underline">
                <i className="fas fa-download mr-1"></i> 下载导入模板
              </button>
            </div>
          )}

          {/* Step 2: Field Mapping */}
          {step === 2 && (
            <div>
              <p className="text-sm text-[#7a7a78] mb-4">请确认 CSV 列与系统字段的对应关系：</p>
              <div className="space-y-2">
                {headers.map(h => (
                  <div key={h} className="flex items-center gap-3">
                    <span className="w-32 text-sm text-[#191918] truncate font-mono bg-[#f0eeeb] px-2 py-1 rounded">{h}</span>
                    <i className="fas fa-arrow-right text-[#7a7a78] text-xs"></i>
                    <select
                      value={mapping[h] || ''}
                      onChange={(e) => setMapping({ ...mapping, [h]: e.target.value })}
                      className="flex-1 text-sm border border-[#e0ddd5] rounded-lg px-3 py-1.5 bg-white"
                    >
                      <option value="">— 跳过 —</option>
                      {fields.map(f => (
                        <option key={f.key} value={f.key}>{t((f as any).labelKey)}{f.required ? ' *' : ''}</option>
                      ))}
                    </select>
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* Step 3: Preview & Validate */}
          {step === 3 && (
            <div>
              <p className="text-sm text-[#7a7a78] mb-3">预览前 10 条记录（共 {mappedRecords.length} 条）：</p>
              <div className="overflow-x-auto">
                <table className="w-full text-xs border-collapse data-table">
                  <thead>
                    <tr className="bg-[#f0eeeb]">
                      <th className="px-2 py-1.5 text-left">#</th>
                      <th className="px-2 py-1.5 text-left">日期</th>
                      <th className="px-2 py-1.5 text-left">{type === 'sales' ? '客户' : '供应商'}</th>
                      <th className="px-2 py-1.5 text-right">数量</th>
                      <th className="px-2 py-1.5 text-right">总金额</th>
                      <th className="px-2 py-1.5 text-center">状态</th>
                    </tr>
                  </thead>
                  <tbody>
                    {mappedRecords.slice(0, 10).map((r, i) => {
                      const errs = validateRecord(r);
                      return (
                        <tr key={i} className={`border-t border-[#f0eeeb] ${errs.length > 0 ? 'bg-red-50' : ''}`}>
                          <td className="px-2 py-1.5">{i + 1}</td>
                          <td className="px-2 py-1.5">{r.date}</td>
                          <td className="px-2 py-1.5">{type === 'sales' ? r.customer : r.supplier}</td>
                          <td className="px-2 py-1.5 text-right">{r.tons}</td>
                          <td className="px-2 py-1.5 text-right">{currSym}{(r.totalAmount || 0).toLocaleString()}</td>
                          <td className="px-2 py-1.5 text-center">
                            {errs.length === 0
                              ? <span className="text-green-600"><i className="fas fa-check-circle"></i></span>
                              : <span className="text-red-500 cursor-help" title={errs.join('; ')}><i className="fas fa-exclamation-circle"></i></span>
                            }
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
              {mappedRecords.length > 10 && <p className="text-xs text-[#7a7a78] mt-2">...还有 {mappedRecords.length - 10} 条未显示</p>}
            </div>
          )}

          {/* Step 4: Result */}
          {step === 4 && result && (
            <div className="text-center py-6">
              {result.success > 0 ? (
                <div>
                  <i className="fas fa-check-circle text-5xl text-green-500 mb-4"></i>
                  <p className="text-lg font-bold text-[#191918]">导入完成</p>
                  <p className="text-sm text-[#7a7a78] mt-2">
                    成功 <span className="text-green-600 font-bold">{result.success}</span> 条
                    {result.failed > 0 && <>，失败 <span className="text-red-500 font-bold">{result.failed}</span> 条</>}
                  </p>
                </div>
              ) : (
                <div>
                  <i className="fas fa-exclamation-triangle text-5xl text-red-500 mb-4"></i>
                  <p className="text-lg font-bold text-[#191918]">导入失败</p>
                </div>
              )}
              {result.errors.length > 0 && (
                <div className="mt-4 text-left bg-red-50 rounded-lg p-3 max-h-40 overflow-y-auto">
                  {result.errors.slice(0, 10).map((e, i) => (
                    <p key={i} className="text-xs text-red-600">第{e.row}行: {e.errors.join(', ')}</p>
                  ))}
                </div>
              )}
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="flex items-center justify-between px-6 py-4 border-t border-[#e0ddd5] bg-[#f9f9f8]">
          <span className="text-xs text-[#7a7a78]">{fileName && `📄 ${fileName} (${csvData.length} 条)`}</span>
          <div className="flex gap-2">
            {step > 1 && step < 4 && (
              <button onClick={() => setStep((step - 1) as any)} className="px-4 py-2 text-sm text-[#7a7a78] hover:text-[#191918]">上一步</button>
            )}
            {step === 2 && (
              <button onClick={() => setStep(3)} className="px-4 py-2 text-sm bg-primary text-white rounded-lg hover:bg-primary-hover">
                下一步：预览
              </button>
            )}
            {step === 3 && (
              <button onClick={handleImport} disabled={importing} className="px-4 py-2 text-sm bg-primary text-white rounded-lg hover:bg-primary-hover disabled:opacity-50">
                {importing ? <><i className="fas fa-spinner fa-spin mr-1"></i>导入中...</> : `确认导入 ${mappedRecords.length} 条`}
              </button>
            )}
            {step === 4 && (
              <button onClick={handleClose} className="px-4 py-2 text-sm bg-primary text-white rounded-lg hover:bg-primary-hover">完成</button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
};

export default CsvImportModal;
