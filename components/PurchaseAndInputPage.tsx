
import React, { useState, useRef, useEffect } from 'react';
import { BusinessData } from '../types';
import { analyzeInvoice } from '../services/ocrService';
import { fetchPurchases, createPurchase, deletePurchase, PurchaseRecord } from '../services/api';
import CsvImportModal from './CsvImportModal';

interface Props {
  data: BusinessData;
  selectedYear: string;
  selectedQuarter: string;
  selectedMonth: string;
}

let purchaseIdCounter = 0;
const nextPurchaseId = () => `purchase-${++purchaseIdCounter}-${Date.now()}`;

const PurchaseAndInputPage: React.FC<Props> = ({ data, selectedYear, selectedQuarter, selectedMonth }) => {
  const [recognitionMode, setRecognitionMode] = useState<'ai' | 'ocr'>('ai');
  const [isScanning, setIsScanning] = useState(false);
  const [showAddModal, setShowAddModal] = useState(false);
  const [records, setRecords] = useState<PurchaseRecord[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [showCsvImport, setShowCsvImport] = useState(false);

  // Load records from API on mount
  useEffect(() => {
    fetchPurchases()
      .then(setRecords)
      .catch((err) => console.error('Failed to load purchases:', err))
      .finally(() => setIsLoading(false));
  }, []);

  // Form State
  const [newPurchase, setNewPurchase] = useState<Omit<PurchaseRecord, 'status' | 'id'>>({
    date: new Date().toISOString().split('T')[0],
    supplier: '',
    quantity: '',
    price: 0,
    taxRate: '13%',
    invoiceNo: ''
  });

  const fileInputRef = useRef<HTMLInputElement>(null);

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

      const newRecord: PurchaseRecord = {
        id: nextPurchaseId(),
        date: extracted.date,
        supplier: extracted.customer,
        quantity: extracted.quantity,
        price: extracted.price,
        taxRate: '13%',
        invoiceNo: extracted.invoiceNo,
        status: '已收'
      };

      await createPurchase(newRecord);
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
    if (!newPurchase.supplier || !newPurchase.quantity) {
      alert("请填写必要的供应商和数量信息");
      return;
    }
    const recordToAdd: PurchaseRecord = { id: nextPurchaseId(), ...newPurchase, status: '已收' };
    try {
      await createPurchase(recordToAdd);
      setRecords(prev => [recordToAdd, ...prev]);
      setShowAddModal(false);
      setNewPurchase({
        date: new Date().toISOString().split('T')[0],
        supplier: '',
        quantity: '',
        price: 0,
        taxRate: '13%',
        invoiceNo: ''
      });
    } catch (err) {
      console.error(err);
      alert('保存失败，请重试');
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
        <h1 className="text-2xl font-bold text-[#191918]">采购与进项</h1>
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
            onClick={() => setShowAddModal(true)}
            className="flex items-center px-4 py-2 bg-[#d97757] hover:bg-[#c56a4a] text-white rounded-lg transition-colors text-sm font-medium" style={{ boxShadow: '0 4px 16px rgba(217,119,87,0.15)' }}
          >
            <i className="fas fa-plus mr-2"></i> 新增采购
          </button>
        </div>
      </div>

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
          <span className="w-2 h-2 rounded-full bg-amber-500 animate-pulse"></span>
          <span>AI 服务: 已在线 (Gemini 3 Flash)</span>
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
          {isScanning ? '正在分析进项发票...' : '拖放或点击上传电子发票'}
        </h3>
        <p className="text-[#5c5c5a] text-xs">
          {isScanning ? 'AI 正在核对供应商、进价及进项税率' : '自动提取日期、金额、供应商及发票号码'}
        </p>
      </div>

      {/* Data Table */}
      <div className="bg-white/80 border border-[#e0ddd5] rounded-xl overflow-hidden" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.05)' }}>
        <div className="overflow-x-auto">
          <table className="w-full text-left border-collapse">
            <thead>
              <tr className="border-b border-[#e0ddd5] text-[#5c5c5a] text-xs">
                <th className="px-6 py-4 font-medium">日期</th>
                <th className="px-6 py-4 font-medium">供应商</th>
                <th className="px-6 py-4 font-medium">数量</th>
                <th className="px-6 py-4 font-medium">进价</th>
                <th className="px-6 py-4 font-medium">税率</th>
                <th className="px-6 py-4 font-medium">发票号码</th>
                <th className="px-6 py-4 font-medium">发票状态</th>
                <th className="px-6 py-4 font-medium">操作</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-[#e0ddd5]/50">
              {records.map((row) => (
                <tr key={row.id} className="hover:bg-[#f9f9f8]/30 transition-colors">
                  <td className="px-6 py-5 text-sm text-[#4a4a48]">{row.date}</td>
                  <td className="px-6 py-5 text-sm text-[#191918] font-medium">{row.supplier}</td>
                  <td className="px-6 py-5 text-sm text-[#4a4a48]">{row.quantity}</td>
                  <td className="px-6 py-5 text-sm text-[#191918] font-medium">{formatCurrency(row.price)}</td>
                  <td className="px-6 py-5 text-sm text-[#4a4a48]">{row.taxRate}</td>
                  <td className="px-6 py-5 text-sm font-mono text-[#4a4a48] tracking-tight">{row.invoiceNo}</td>
                  <td className="px-6 py-5">
                    <span className="px-2 py-0.5 bg-emerald-500/10 text-emerald-500 border border-emerald-500/20 rounded-md text-[10px] font-bold">
                      {row.status}
                    </span>
                  </td>
                  <td className="px-6 py-5 text-xs font-medium space-x-3">
                    <button
                      onClick={() => {
                        setNewPurchase({ date: row.date, supplier: row.supplier, quantity: row.quantity, price: row.price, taxRate: row.taxRate, invoiceNo: row.invoiceNo });
                        setShowAddModal(true);
                      }}
                      className="text-[#d97757] hover:text-[#c56a4a] transition-colors"
                    >编辑</button>
                    <button
                      onClick={async () => {
                        try {
                          await deletePurchase(row.id);
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
              ))}
              {isLoading && (
                <tr>
                  <td colSpan={8} className="px-6 py-12 text-center text-[#5c5c5a] text-sm">
                    <i className="fas fa-spinner animate-spin mr-2"></i>正在加载数据...
                  </td>
                </tr>
              )}
              {!isLoading && records.length === 0 && (
                <tr>
                  <td colSpan={8} className="px-6 py-12 text-center text-[#5c5c5a] text-sm italic">
                    暂无采购记录。
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* CSV Import Modal */}
      {showCsvImport && (
        <CsvImportModal
          type="purchases"
          onClose={() => setShowCsvImport(false)}
          onSuccess={() => {
            setShowCsvImport(false);
            fetchPurchases().then(setRecords).catch(console.error);
          }}
        />
      )}

      {/* Add Purchase Modal */}
      {showAddModal && (
        <div className="fixed inset-0 z-[10001] flex items-center justify-center px-4">
          <div className="absolute inset-0 bg-black/40 backdrop-blur-sm" onClick={() => setShowAddModal(false)}></div>
          <div className="relative w-full max-w-lg bg-white border border-[#e0ddd5] rounded-xl overflow-hidden animate-in zoom-in-95 duration-200" style={{ boxShadow: '0 4px 24px rgba(0,0,0,0.05)' }}>
            <div className="p-8 border-b border-[#e0ddd5] flex justify-between items-center">
              <div>
                <h2 className="text-xl font-bold text-[#191918]">新增采购记录</h2>
                <p className="text-xs text-[#5c5c5a] mt-1">请手动输入采购交易详情</p>
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
                    value={newPurchase.date}
                    onChange={(e) => setNewPurchase({ ...newPurchase, date: e.target.value })}
                    className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-[#d97757] text-[#191918] transition-all"
                  />
                </div>
                <div className="space-y-2">
                  <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">发票号码</label>
                  <input
                    type="text"
                    placeholder="可选"
                    value={newPurchase.invoiceNo}
                    onChange={(e) => setNewPurchase({ ...newPurchase, invoiceNo: e.target.value })}
                    className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-[#d97757] text-[#191918] transition-all"
                  />
                </div>
              </div>

              <div className="space-y-2">
                <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">供应商名称</label>
                <input
                  type="text"
                  required
                  placeholder="请输入供应商全称"
                  value={newPurchase.supplier}
                  onChange={(e) => setNewPurchase({ ...newPurchase, supplier: e.target.value })}
                  className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-[#d97757] text-[#191918] transition-all"
                />
              </div>

              <div className="space-y-2">
                <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">采购数量</label>
                <input
                  type="text"
                  required
                  placeholder="例如: 100吨 / 1000袋"
                  value={newPurchase.quantity}
                  onChange={(e) => setNewPurchase({ ...newPurchase, quantity: e.target.value })}
                  className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-[#d97757] text-[#191918] transition-all"
                />
              </div>

              <div className="grid grid-cols-2 gap-4">
                <div className="space-y-2">
                  <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">进价 (不含税)</label>
                  <div className="relative">
                    <span className="absolute left-4 top-1/2 -translate-y-1/2 text-[#5c5c5a] text-sm">¥</span>
                    <input
                      type="number"
                      required
                      step="0.01"
                      value={newPurchase.price || ''}
                      onChange={(e) => setNewPurchase({ ...newPurchase, price: parseFloat(e.target.value) || 0 })}
                      className="w-full bg-white border border-[#e0ddd5] rounded-xl pl-8 pr-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-[#d97757] text-[#191918] transition-all"
                    />
                  </div>
                </div>
                <div className="space-y-2">
                  <label className="text-[10px] font-bold text-[#5c5c5a] uppercase tracking-widest">增值税率</label>
                  <select
                    value={newPurchase.taxRate}
                    onChange={(e) => setNewPurchase({ ...newPurchase, taxRate: e.target.value })}
                    className="w-full bg-white border border-[#e0ddd5] rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-[#d97757] text-[#191918] transition-all appearance-none"
                  >
                    <option value="13%">13% (标准货物)</option>
                    <option value="9%">9% (交通运输/低税)</option>
                    <option value="6%">6% (现代服务)</option>
                    <option value="3%">3% (小规模/简易)</option>
                  </select>
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
                  确认新增
                </button>
              </div>
            </form>
          </div>
        </div>
      )}
    </div>
  );
};

export default PurchaseAndInputPage;
