
import React, { useState, useRef, useEffect } from 'react';
import { BusinessData } from '../types';
import { analyzeInvoice } from '../services/ocrService';
import { fetchSales, createSale, updateSale, deleteSale, SalesRecord } from '../services/api';
import CsvImportModal from './CsvImportModal';

interface Props {
  data: BusinessData;
  selectedYear: string;
  selectedQuarter: string;
  selectedMonth: string;
}

let salesIdCounter = 0;
const nextSalesId = () => `sale-${++salesIdCounter}-${Date.now()}`;

const SalesAndOutputPage: React.FC<Props> = ({ data, selectedYear, selectedQuarter, selectedMonth }) => {
  const [recognitionMode, setRecognitionMode] = useState<'ai' | 'ocr'>('ai');
  const [isScanning, setIsScanning] = useState(false);
  const [showAddModal, setShowAddModal] = useState(false);
  const [records, setRecords] = useState<SalesRecord[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [showCsvImport, setShowCsvImport] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);

  // Load records from API on mount
  useEffect(() => {
    fetchSales()
      .then(setRecords)
      .catch((err) => console.error('Failed to load sales:', err))
      .finally(() => setIsLoading(false));
  }, []);

  // Form State for manual entry
  const [newSale, setNewSale] = useState<Omit<SalesRecord, 'status' | 'id'>>({
    date: new Date().toISOString().split('T')[0],
    customer: '',
    quantity: '',
    price: 0,
    shipping: 0,
    invoiceNo: '',
    totalWithTax: 0,
    unitPriceWithoutTax: 0,
    taxAmount: 0
  });

  const fileInputRef = useRef<HTMLInputElement>(null);

  // Auto-calculate: when totalWithTax + quantity change, compute price/unitPrice/taxAmount
  useEffect(() => {
    const { totalWithTax, quantity, taxRate } = newSale;
    if (!totalWithTax || totalWithTax <= 0) return;

    const rateNum = parseFloat((taxRate || '13%').replace('%', '')) || 13;
    const amountWithoutTax = Math.round((totalWithTax / (1 + rateNum / 100)) * 100) / 100;
    const taxAmount = Math.round((totalWithTax - amountWithoutTax) * 100) / 100;

    const tonsMatch = quantity.match(/[\d.]+/);
    const tons = tonsMatch ? parseFloat(tonsMatch[0]) : 0;
    const unitPrice = tons > 0 ? Math.round((amountWithoutTax / tons) * 100) / 100 : 0;

    if (
      newSale.price !== amountWithoutTax ||
      newSale.unitPriceWithoutTax !== unitPrice ||
      newSale.taxAmount !== taxAmount
    ) {
      setNewSale(prev => ({
        ...prev,
        price: amountWithoutTax,
        unitPriceWithoutTax: unitPrice,
        taxAmount
      }));
    }
  }, [newSale.totalWithTax, newSale.quantity, newSale.taxRate]);

  const formatCurrency = (val: number) => `¥${val.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

  const handleFileChange = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (file) {
      await processFile(file);
    }
  };

  const processFile = async (file: File) => {
    setIsScanning(true);
    try {
      const reader = new FileReader();
      const base64Promise = new Promise<string>((resolve, reject) => {
        const timeout = setTimeout(() => reject(new Error('文件读取超时')), 30000);
        reader.onload = () => {
          clearTimeout(timeout);
          const result = reader.result as string;
          const parts = result.split(',');
          if (parts.length < 2) {
            reject(new Error('文件格式不支持'));
            return;
          }
          resolve(parts[1]);
        };
        reader.onerror = () => {
          clearTimeout(timeout);
          reject(new Error('文件读取失败'));
        };
      });
      reader.readAsDataURL(file);
      const base64 = await base64Promise;

      const extracted = await analyzeInvoice(base64, file.type);

      const taxRate = extracted.price > 0 && extracted.taxAmount > 0
        ? `${Math.round((extracted.taxAmount / extracted.price) * 100)}%`
        : '13%';

      const newRecord: SalesRecord = {
        id: nextSalesId(),
        date: extracted.date,
        customer: extracted.customer,
        quantity: extracted.quantity,
        price: extracted.price,
        shipping: extracted.shipping,
        invoiceNo: extracted.invoiceNo,
        status: '已开',
        taxRate,
        totalWithTax: extracted.totalWithTax || 0,
        unitPriceWithoutTax: extracted.unitPriceWithoutTax || 0,
        taxAmount: extracted.taxAmount || 0,
        amountWithoutTax: extracted.price
      };

      await createSale(newRecord);
      setRecords(prev => [newRecord, ...prev]);
      alert("识别成功！已添加到列表。");
    } catch (err) {
      console.error(err);
      alert("识别失败，请确保上传的是清晰的发票图片。");
    } finally {
      setIsScanning(false);
      if (fileInputRef.current) fileInputRef.current.value = '';
    }
  };

  const handleAddSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!newSale.customer || !newSale.quantity) {
      alert("请填写必要的客户和数量信息");
      return;
    }
    try {
      if (editingId) {
        // Update existing record
        const recordToUpdate: SalesRecord = { id: editingId, ...newSale, status: '已开' };
        await updateSale(editingId, recordToUpdate);
        setRecords(prev => prev.map(r => r.id === editingId ? recordToUpdate : r));
      } else {
        // Create new record
        const recordToAdd: SalesRecord = { id: nextSalesId(), ...newSale, status: '已开' };
        await createSale(recordToAdd);
        setRecords(prev => [recordToAdd, ...prev]);
      }
      setShowAddModal(false);
      setEditingId(null);
      setNewSale({
        date: new Date().toISOString().split('T')[0],
        customer: '',
        quantity: '',
        price: 0,
        shipping: 0,
        invoiceNo: '',
        totalWithTax: 0,
        unitPriceWithoutTax: 0,
        taxAmount: 0
      });
    } catch (err) {
      console.error(err);
      alert(editingId ? '更新失败，请重试' : '保存失败，请重试');
    }
  };

  const triggerUpload = () => {
    fileInputRef.current?.click();
  };

  return (
    <div className="space-y-6 animate-in fade-in duration-500 max-w-[1600px] mx-auto relative">
      <input
        type="file"
        ref={fileInputRef}
        onChange={handleFileChange}
        className="hidden"
        accept="image/*,application/pdf"
      />

      {/* Header Section */}
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold text-[#191918]">销售与销项</h1>
        <div className="flex space-x-3">
          <button
            onClick={() => setShowCsvImport(true)}
            className="flex items-center px-4 py-2 bg-emerald-600 hover:bg-emerald-500 text-white rounded-lg transition-colors text-sm font-medium" style={{ boxShadow: '0 4px 16px rgba(16,185,129,0.15)' }}
          >
            <i className="fas fa-file-csv mr-2"></i> 批量导入
          </button>
          <button
            onClick={triggerUpload}
            disabled={isScanning}
            className="flex items-center px-4 py-2 bg-purple-600 hover:bg-purple-500 text-white rounded-lg transition-colors text-sm font-medium disabled:opacity-50" style={{ boxShadow: '0 4px 16px rgba(147,51,234,0.15)' }}
          >
            <i className={`fas ${isScanning ? 'fa-spinner animate-spin' : 'fa-camera'} mr-2`}></i>
            {isScanning ? '正在识别...' : '扫描发票'}
          </button>
          <button
            onClick={() => { setEditingId(null); setShowAddModal(true); }}
            className="flex items-center px-4 py-2 bg-[#d97757] hover:bg-[#c56a4a] text-white rounded-lg transition-colors text-sm font-medium" style={{ boxShadow: '0 4px 16px rgba(217,119,87,0.15)' }}
          >
            <i className="fas fa-plus mr-2"></i> 新增销售
          </button>
        </div>
      </div>

      {/* Inventory Banner */}
      {(() => {
        const purchaseTons = data.rawMetrics?.purchaseTotalTons ?? 0;
        const salesTons = data.rawMetrics?.salesTotalTons ?? 0;
        const inventoryTons = purchaseTons - salesTons;
        const inventoryBags = Math.round(inventoryTons * 100); // 1吨=100袋(10kg/袋)
        const isLow = inventoryTons <= 0;
        return (
          <div className={`${isLow ? 'bg-rose-500/10 border-rose-500/20' : 'bg-blue-500/10 border-blue-500/20'} border rounded-xl p-4 flex items-center justify-between`}>
            <div className="flex items-center space-x-3">
              <div className={`${isLow ? 'text-rose-500 bg-rose-500/20' : 'text-blue-500 bg-blue-500/20'} w-8 h-8 rounded-full flex items-center justify-center`}>
                <i className={`fas ${isLow ? 'fa-exclamation-triangle' : 'fa-boxes'}`}></i>
              </div>
              <div>
                <p className={`${isLow ? 'text-rose-500' : 'text-blue-500'} font-bold text-sm`}>
                  当前库存: {inventoryTons.toFixed(2)} 吨 ({inventoryBags} 袋)
                </p>
                <p className={`${isLow ? 'text-rose-400' : 'text-blue-400'} text-xs`}>
                  {isLow ? '库存不足，销售将导致库存为负' : '库存充足'}
                </p>
              </div>
            </div>
            <div className="text-right text-[#5c5c5a] text-xs space-y-0.5">
              <p>总采购: {purchaseTons.toFixed(2)} 吨</p>
              <p>总销售: {salesTons.toFixed(2)} 吨</p>
            </div>
          </div>
        );
      })()}

      {/* Recognition Mode Selector */}
      <div className="flex items-center justify-between py-2">
        <div className="flex items-center space-x-4">
          <span className="text-[#4a4a48] text-sm">识别模式:</span>
          <div className="flex bg-[#f9f9f8] rounded-lg p-1 border border-[#e0ddd5]">
            <button
              onClick={() => setRecognitionMode('ai')}
              className={`flex items-center px-3 py-1.5 rounded-md text-xs transition-all ${recognitionMode === 'ai' ? 'bg-[#d97757] text-white shadow-sm' : 'text-[#4a4a48] hover:text-[#191918]'}`}
            >
              <i className="fas fa-robot mr-2"></i> AI 智能识别 (Gemini)
            </button>
            <button
              onClick={() => setRecognitionMode('ocr')}
              className={`flex items-center px-3 py-1.5 rounded-md text-xs transition-all ${recognitionMode === 'ocr' ? 'bg-[#f0eeeb] text-[#191918]' : 'text-[#4a4a48] hover:text-[#191918]'}`}
            >
              <i className="fas fa-file-invoice mr-2"></i> 本地 OCR 识别
            </button>
          </div>
        </div>
        <div className="flex items-center space-x-2 text-xs text-[#5c5c5a]">
          <span className="w-2 h-2 rounded-full bg-emerald-500 animate-pulse"></span>
          <span>AI 服务: 已在线 ({recognitionMode === 'ai' ? 'Gemini 3 Flash' : 'Local OCR Engine'})</span>
        </div>
      </div>

      {/* Upload Dropzone */}
      <div
        onClick={triggerUpload}
        onDragOver={(e) => e.preventDefault()}
        onDrop={async (e) => {
          e.preventDefault();
          const file = e.dataTransfer.files[0];
          if (file) await processFile(file);
        }}
        className={`border-2 border-dashed rounded-xl py-12 flex flex-col items-center justify-center transition-all cursor-pointer group
          ${isScanning ? 'border-[#d97757]/50 bg-[#d97757]/10' : 'border-[#d97757]/30 bg-[#d97757]/5 hover:bg-[#d97757]/10 hover:border-[#d97757]/50'}
        `}
      >
        <div className="mb-4 transform group-hover:scale-110 transition-transform duration-300">
          {isScanning ? (
            <div className="w-12 h-12 border-4 border-[#d97757]/30 border-t-[#d97757] rounded-full animate-spin"></div>
          ) : (
            <div className="text-4xl">🤖</div>
          )}
        </div>
        <h3 className="text-[#4a4a48] font-medium text-base mb-1">
          {isScanning ? '正在分析发票数据...' : '拖放或点击上传电子发票'}
        </h3>
        <p className="text-[#5c5c5a] text-xs">
          {isScanning ? 'AI 正在提取日期、金额、发票号等关键信息' : '支持图片或 PDF，使用 Gemini 智能识别，识别更准确'}
        </p>
      </div>

      {/* Data Table */}
      <div className="bg-white/80 border border-[#e0ddd5] rounded-xl overflow-hidden" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.05)' }}>
        <div className="overflow-x-auto">
          <table className="w-full text-left border-collapse">
            <thead>
              <tr className="border-b border-[#e0ddd5] text-[#5c5c5a] text-xs">
                <th className="px-5 py-4 font-medium">日期</th>
                <th className="px-5 py-4 font-medium">客户</th>
                <th className="px-5 py-4 font-medium">数量</th>
                <th className="px-5 py-4 font-medium whitespace-nowrap">无税单价</th>
                <th className="px-5 py-4 font-medium whitespace-nowrap">合计无税金额</th>
                <th className="px-5 py-4 font-medium whitespace-nowrap">合计税额</th>
                <th className="px-5 py-4 font-medium whitespace-nowrap">价税合计</th>
                <th className="px-5 py-4 font-medium">运费</th>
                <th className="px-5 py-4 font-medium">发票号码</th>
                <th className="px-5 py-4 font-medium">状态</th>
                <th className="px-5 py-4 font-medium">操作</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-[#e0ddd5]/50">
              {records.map((row) => {
                const unitPrice = row.unitPriceWithoutTax || (row.pricePerTon || 0);
                const amtWithoutTax = row.amountWithoutTax || row.price;
                const taxAmt = row.taxAmount || 0;
                const totalWT = row.totalWithTax || (amtWithoutTax + taxAmt);
                return (
                <tr key={row.id} className="hover:bg-[#f9f9f8]/30 transition-colors">
                  <td className="px-5 py-5 text-sm text-[#4a4a48] whitespace-nowrap">{row.date}</td>
                  <td className="px-5 py-5 text-sm text-[#191918] font-medium">{row.customer}</td>
                  <td className="px-5 py-5 text-sm text-[#4a4a48]">{row.quantity}</td>
                  <td className="px-5 py-5 text-sm text-[#191918] font-medium whitespace-nowrap">{formatCurrency(unitPrice)}</td>
                  <td className="px-5 py-5 text-sm text-[#191918] font-medium whitespace-nowrap">{formatCurrency(amtWithoutTax)}</td>
                  <td className="px-5 py-5 text-sm text-rose-600 font-medium whitespace-nowrap">{formatCurrency(taxAmt)}</td>
                  <td className="px-5 py-5 text-sm text-[#191918] font-bold whitespace-nowrap">{formatCurrency(totalWT)}</td>
                  <td className="px-5 py-5 text-sm text-[#4a4a48]">{formatCurrency(row.shipping)}</td>
                  <td className="px-5 py-5 text-sm font-mono text-[#4a4a48] tracking-tight">{row.invoiceNo}</td>
                  <td className="px-5 py-5">
                    <span className="px-2 py-0.5 bg-emerald-500/10 text-emerald-500 border border-emerald-500/20 rounded-md text-[10px] font-bold">
                      {row.status}
                    </span>
                  </td>
                  <td className="px-5 py-5 text-xs font-medium space-x-3">
                    <button
                      onClick={() => {
                        setEditingId(row.id);
                        setNewSale({ date: row.date, customer: row.customer, quantity: row.quantity, price: row.price, shipping: row.shipping, invoiceNo: row.invoiceNo, totalWithTax: row.totalWithTax || 0, unitPriceWithoutTax: row.unitPriceWithoutTax || 0, taxAmount: row.taxAmount || 0 });
                        setShowAddModal(true);
                      }}
                      className="text-[#d97757] hover:text-[#c56a4a] transition-colors"
                    >编辑</button>
                    <button
                      onClick={async () => {
                        try {
                          await deleteSale(row.id);
                          setRecords(prev => prev.filter(r => r.id !== row.id));
                        } catch (err) {
                          console.error(err);
                          alert('删除失败，请重试');
                        }
                      }}
                      className="text-rose-500 hover:text-rose-400 transition-colors"
                    >
                      删除
                    </button>
                  </td>
                </tr>
                );
              })}
              {isLoading && (
                <tr>
                  <td colSpan={11} className="px-6 py-12 text-center text-[#5c5c5a] text-sm">
                    <i className="fas fa-spinner animate-spin mr-2"></i>正在加载数据...
                  </td>
                </tr>
              )}
              {!isLoading && records.length === 0 && (
                <tr>
                  <td colSpan={11} className="px-6 py-12 text-center text-[#5c5c5a] text-sm italic">
                    暂无销售记录，请上传发票或手动新增。
                  </td>
                </tr>
              )}
              {/* Summary row */}
              {!isLoading && records.length > 0 && (
                <tr className="bg-[#f9f9f8] border-t-2 border-[#e0ddd5] font-semibold">
                  <td className="px-5 py-4 text-sm text-[#191918]" colSpan={2}>合计</td>
                  <td className="px-5 py-4 text-sm text-[#191918]">
                    {(() => {
                      const total = records.reduce((sum, r) => {
                        const match = r.quantity.match(/[\d.]+/);
                        return sum + (match ? parseFloat(match[0]) : 0);
                      }, 0);
                      const unit = records[0]?.quantity.replace(/[\d.\s]+/g, '') || '';
                      return `${total}${unit}`;
                    })()}
                  </td>
                  <td className="px-5 py-4 text-sm text-[#4a4a48]">—</td>
                  <td className="px-5 py-4 text-sm text-[#191918] whitespace-nowrap">
                    {formatCurrency(records.reduce((s, r) => s + (r.amountWithoutTax || r.price), 0))}
                  </td>
                  <td className="px-5 py-4 text-sm text-rose-600 whitespace-nowrap">
                    {formatCurrency(records.reduce((s, r) => s + (r.taxAmount || 0), 0))}
                  </td>
                  <td className="px-5 py-4 text-sm text-[#191918] font-bold whitespace-nowrap">
                    {formatCurrency(records.reduce((s, r) => {
                      const amt = r.amountWithoutTax || r.price;
                      const tax = r.taxAmount || 0;
                      return s + (r.totalWithTax || (amt + tax));
                    }, 0))}
                  </td>
                  <td className="px-5 py-4 text-sm text-[#4a4a48] whitespace-nowrap">
                    {formatCurrency(records.reduce((s, r) => s + (r.shipping || 0), 0))}
                  </td>
                  <td colSpan={3}></td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* CSV Import Modal */}
      {showCsvImport && (
        <CsvImportModal
          type="sales"
          onClose={() => setShowCsvImport(false)}
          onSuccess={() => {
            setShowCsvImport(false);
            fetchSales().then(setRecords).catch(console.error);
          }}
        />
      )}

      {/* Add Sales Modal */}
      {showAddModal && (
        <div className="fixed inset-0 z-[10001] flex items-center justify-center px-4">
          <div className="absolute inset-0 bg-black/40 backdrop-blur-sm" onClick={() => { setShowAddModal(false); setEditingId(null); }}></div>
          <div className="relative w-full max-w-lg bg-white border border-[#e0ddd5] rounded-xl overflow-hidden animate-in zoom-in-95 duration-200" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.05)' }}>
            <div className="p-8 border-b border-[#e0ddd5] flex justify-between items-center">
              <div>
                <h2 className="text-xl font-bold text-[#191918]">{editingId ? '编辑销售记录' : '新增销售记录'}</h2>
                <p className="text-xs text-[#5c5c5a] mt-1">{editingId ? '修改已有的销售交易明细' : '手动录入销售交易明细'}</p>
              </div>
              <button onClick={() => setShowAddModal(false)} className="text-[#5c5c5a] hover:text-[#191918] transition-colors">
                <i className="fas fa-times text-xl"></i>
              </button>
            </div>

            <form onSubmit={handleAddSubmit} className="p-8 space-y-5">
              <div className="grid grid-cols-2 gap-4">
                <div className="space-y-2">
                  <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">业务日期</label>
                  <input
                    type="date"
                    required
                    value={newSale.date}
                    onChange={(e) => setNewSale({ ...newSale, date: e.target.value })}
                    className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-[#d97757] text-[#191918] transition-all"
                  />
                </div>
                <div className="space-y-2">
                  <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">发票号码</label>
                  <input
                    type="text"
                    placeholder="可选"
                    value={newSale.invoiceNo}
                    onChange={(e) => setNewSale({ ...newSale, invoiceNo: e.target.value })}
                    className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-[#d97757] text-[#191918] transition-all"
                  />
                </div>
              </div>

              <div className="space-y-2">
                <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">客户名称</label>
                <input
                  type="text"
                  required
                  placeholder="请输入购方全称"
                  value={newSale.customer}
                  onChange={(e) => setNewSale({ ...newSale, customer: e.target.value })}
                  className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-[#d97757] text-[#191918] transition-all"
                />
              </div>

              <div className="space-y-2">
                <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">销售数量</label>
                <input
                  type="text"
                  required
                  placeholder="例如: 36.5吨 / 3650袋"
                  value={newSale.quantity}
                  onChange={(e) => setNewSale({ ...newSale, quantity: e.target.value })}
                  className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-[#d97757] text-[#191918] transition-all"
                />
              </div>

              <div className="grid grid-cols-2 gap-4">
                <div className="space-y-2">
                  <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">成交总价 (不含税)</label>
                  <div className="relative">
                    <span className="absolute left-4 top-1/2 -translate-y-1/2 text-[#5c5c5a] text-sm">¥</span>
                    <input
                      type="number"
                      required
                      step="0.01"
                      value={newSale.price || ''}
                      onChange={(e) => setNewSale({ ...newSale, price: parseFloat(e.target.value) || 0 })}
                      className="w-full bg-white border border-[#e0ddd5] rounded-xl pl-8 pr-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-[#d97757] text-[#191918] transition-all"
                    />
                  </div>
                </div>
                <div className="space-y-2">
                  <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">运费支出</label>
                  <div className="relative">
                    <span className="absolute left-4 top-1/2 -translate-y-1/2 text-[#5c5c5a] text-sm">¥</span>
                    <input
                      type="number"
                      step="0.01"
                      value={newSale.shipping || ''}
                      onChange={(e) => setNewSale({ ...newSale, shipping: parseFloat(e.target.value) || 0 })}
                      className="w-full bg-white border border-[#e0ddd5] rounded-xl pl-8 pr-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-[#d97757] text-[#191918] transition-all"
                    />
                  </div>
                </div>
              </div>

              <div className="grid grid-cols-3 gap-4">
                <div className="space-y-2">
                  <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">无税单价</label>
                  <div className="relative">
                    <span className="absolute left-4 top-1/2 -translate-y-1/2 text-[#5c5c5a] text-sm">¥</span>
                    <input
                      type="number"
                      step="0.01"
                      value={newSale.unitPriceWithoutTax || ''}
                      onChange={(e) => setNewSale({ ...newSale, unitPriceWithoutTax: parseFloat(e.target.value) || 0 })}
                      className="w-full bg-white border border-[#e0ddd5] rounded-xl pl-8 pr-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-[#d97757] text-[#191918] transition-all"
                      placeholder="可选"
                    />
                  </div>
                </div>
                <div className="space-y-2">
                  <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">合计税额</label>
                  <div className="relative">
                    <span className="absolute left-4 top-1/2 -translate-y-1/2 text-[#5c5c5a] text-sm">¥</span>
                    <input
                      type="number"
                      step="0.01"
                      value={newSale.taxAmount || ''}
                      onChange={(e) => setNewSale({ ...newSale, taxAmount: parseFloat(e.target.value) || 0 })}
                      className="w-full bg-white border border-[#e0ddd5] rounded-xl pl-8 pr-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-[#d97757] text-[#191918] transition-all"
                      placeholder="可选"
                    />
                  </div>
                </div>
                <div className="space-y-2">
                  <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">价税合计</label>
                  <div className="relative">
                    <span className="absolute left-4 top-1/2 -translate-y-1/2 text-[#5c5c5a] text-sm">¥</span>
                    <input
                      type="number"
                      step="0.01"
                      value={newSale.totalWithTax || ''}
                      onChange={(e) => setNewSale({ ...newSale, totalWithTax: parseFloat(e.target.value) || 0 })}
                      className="w-full bg-white border border-[#e0ddd5] rounded-xl pl-8 pr-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-[#d97757] text-[#191918] transition-all"
                      placeholder="可选"
                    />
                  </div>
                </div>
              </div>


              <div className="pt-4 flex space-x-3">
                <button
                  type="button"
                  onClick={() => setShowAddModal(false)}
                  className="flex-1 py-4 bg-[#f0eeeb] hover:bg-[#e0ddd5] text-[#4a4a48] font-bold rounded-xl transition-all"
                >
                  取消
                </button>
                <button
                  type="submit"
                  className="flex-2 px-10 py-4 bg-[#d97757] hover:bg-[#c56a4a] text-white font-bold rounded-xl transition-all active:scale-95" style={{ boxShadow: '0 4px 16px rgba(217,119,87,0.15)' }}
                >
                  {editingId ? '确认修改' : '确认新增'}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}
    </div>
  );
};

export default SalesAndOutputPage;
