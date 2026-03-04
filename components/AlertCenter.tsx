import React, { useState, useEffect, useRef, useCallback } from 'react';
import { fetchAlerts, fetchAlertCount, markAlertRead, markAllAlertsRead, dismissAlert } from '../services/api';
import { Alert } from '../types';

const SEVERITY_STYLES: Record<string, { bg: string; text: string; icon: string; border: string }> = {
  critical: { bg: 'bg-red-50', text: 'text-red-600', icon: 'fa-exclamation-circle', border: 'border-red-200' },
  warning: { bg: 'bg-orange-50', text: 'text-orange-600', icon: 'fa-exclamation-triangle', border: 'border-orange-200' },
  info: { bg: 'bg-blue-50', text: 'text-blue-600', icon: 'fa-info-circle', border: 'border-blue-200' },
};

const TYPE_LABELS: Record<string, string> = {
  inventory_zero: '库存预警',
  receivable_overdue: '应收逾期',
  payable_upcoming: '应付到期',
  price_volatility: '价格波动',
};

const AlertCenter: React.FC = () => {
  const [isOpen, setIsOpen] = useState(false);
  const [alerts, setAlerts] = useState<Alert[]>([]);
  const [unreadCount, setUnreadCount] = useState(0);
  const [loading, setLoading] = useState(false);
  const panelRef = useRef<HTMLDivElement>(null);

  const loadCount = useCallback(async () => {
    try {
      const { count } = await fetchAlertCount();
      setUnreadCount(count);
    } catch (err) {
      // silently fail
    }
  }, []);

  const loadAlerts = useCallback(async () => {
    setLoading(true);
    try {
      const data = await fetchAlerts(false, 30);
      setAlerts(data);
    } catch (err) {
      console.error('Failed to load alerts:', err);
    } finally {
      setLoading(false);
    }
  }, []);

  // Poll unread count every 60s
  useEffect(() => {
    loadCount();
    const interval = setInterval(loadCount, 60000);
    return () => clearInterval(interval);
  }, [loadCount]);

  // Load alerts when panel opens
  useEffect(() => {
    if (isOpen) loadAlerts();
  }, [isOpen, loadAlerts]);

  // Close on outside click
  useEffect(() => {
    const handleClick = (e: MouseEvent) => {
      if (panelRef.current && !panelRef.current.contains(e.target as Node)) {
        setIsOpen(false);
      }
    };
    if (isOpen) document.addEventListener('mousedown', handleClick);
    return () => document.removeEventListener('mousedown', handleClick);
  }, [isOpen]);

  const handleMarkRead = async (id: number) => {
    try {
      await markAlertRead(id);
      setAlerts(prev => prev.map(a => a.id === id ? { ...a, is_read: 1 } : a));
      setUnreadCount(prev => Math.max(0, prev - 1));
    } catch (err) {
      console.error('Mark read failed:', err);
    }
  };

  const handleDismiss = async (id: number) => {
    const dismissed = alerts.find(a => a.id === id);
    try {
      await dismissAlert(id);
      setAlerts(prev => prev.filter(a => a.id !== id));
      if (dismissed && !dismissed.is_read) setUnreadCount(prev => Math.max(0, prev - 1));
    } catch (err) {
      console.error('Dismiss failed:', err);
    }
  };

  const handleMarkAllRead = async () => {
    try {
      await markAllAlertsRead();
      setAlerts(prev => prev.map(a => ({ ...a, is_read: 1 })));
      setUnreadCount(0);
    } catch (err) {
      console.error('Mark all read failed:', err);
    }
  };

  const formatTime = (dateStr: string) => {
    const d = new Date(dateStr + 'Z');
    const now = new Date();
    const diff = now.getTime() - d.getTime();
    const mins = Math.floor(diff / 60000);
    if (mins < 60) return `${mins}分钟前`;
    const hours = Math.floor(mins / 60);
    if (hours < 24) return `${hours}小时前`;
    const days = Math.floor(hours / 24);
    if (days < 7) return `${days}天前`;
    return d.toLocaleDateString('zh-CN');
  };

  return (
    <div className="relative" ref={panelRef}>
      {/* Bell Icon */}
      <button
        onClick={() => setIsOpen(!isOpen)}
        className="relative p-2 rounded-lg hover:bg-[#f0eeeb] transition-colors text-[#7a7a78] hover:text-[#191918]"
        title="预警通知"
      >
        <i className="fas fa-bell text-lg"></i>
        {unreadCount > 0 && (
          <span className="absolute -top-0.5 -right-0.5 min-w-[18px] h-[18px] bg-red-500 text-white text-[10px] font-bold rounded-full flex items-center justify-center px-1 animate-pulse">
            {unreadCount > 99 ? '99+' : unreadCount}
          </span>
        )}
      </button>

      {/* Dropdown Panel */}
      {isOpen && (
        <div className="absolute right-0 top-full mt-2 w-96 max-h-[480px] bg-white rounded-xl shadow-xl border border-[#e0ddd5] overflow-hidden z-50">
          {/* Header */}
          <div className="flex items-center justify-between px-4 py-3 border-b border-[#e0ddd5] bg-[#f9f9f8]">
            <h4 className="text-sm font-bold text-[#191918]">
              <i className="fas fa-bell mr-1.5 text-[#d97757]"></i>
              预警中心
              {unreadCount > 0 && <span className="ml-2 text-xs text-[#7a7a78]">({unreadCount} 未读)</span>}
            </h4>
            {unreadCount > 0 && (
              <button onClick={handleMarkAllRead} className="text-xs text-[#d97757] hover:text-[#c56646]">
                全部已读
              </button>
            )}
          </div>

          {/* Alerts List */}
          <div className="overflow-y-auto max-h-[400px]">
            {loading ? (
              <div className="flex items-center justify-center py-12">
                <i className="fas fa-spinner fa-spin text-[#d97757]"></i>
              </div>
            ) : alerts.length === 0 ? (
              <div className="flex flex-col items-center justify-center py-12 text-[#7a7a78]">
                <i className="fas fa-check-circle text-3xl text-green-400 mb-2"></i>
                <p className="text-sm">暂无预警</p>
              </div>
            ) : (
              alerts.map(alert => {
                const style = SEVERITY_STYLES[alert.severity] || SEVERITY_STYLES.info;
                return (
                  <div
                    key={alert.id}
                    className={`px-4 py-3 border-b border-[#f0eeeb] hover:bg-[#f9f9f8] transition-colors cursor-pointer ${!alert.is_read ? 'bg-[#fdf8f5]' : ''}`}
                    onClick={() => !alert.is_read && handleMarkRead(alert.id)}
                  >
                    <div className="flex items-start gap-3">
                      <div className={`w-8 h-8 rounded-lg ${style.bg} flex items-center justify-center flex-shrink-0 mt-0.5`}>
                        <i className={`fas ${style.icon} ${style.text} text-sm`}></i>
                      </div>
                      <div className="flex-1 min-w-0">
                        <div className="flex items-center gap-2 mb-0.5">
                          <span className={`inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium ${style.bg} ${style.text}`}>
                            {TYPE_LABELS[alert.type] || alert.type}
                          </span>
                          {!alert.is_read && <span className="w-1.5 h-1.5 rounded-full bg-[#d97757]"></span>}
                        </div>
                        <p className="text-sm font-medium text-[#191918] truncate">{alert.title}</p>
                        <p className="text-xs text-[#7a7a78] mt-0.5 line-clamp-2">{alert.message}</p>
                        <p className="text-[10px] text-[#b0b0ae] mt-1">{formatTime(alert.created_at)}</p>
                      </div>
                      <button
                        onClick={(e) => { e.stopPropagation(); handleDismiss(alert.id); }}
                        className="text-[#b0b0ae] hover:text-red-400 p-1 flex-shrink-0"
                        title="忽略"
                      >
                        <i className="fas fa-times text-xs"></i>
                      </button>
                    </div>
                  </div>
                );
              })
            )}
          </div>
        </div>
      )}
    </div>
  );
};

export default AlertCenter;
