import React, { useState } from 'react';

interface LoginPageProps {
  onLogin: (username: string) => void;
}

const LoginPage: React.FC<LoginPageProps> = ({ onLogin }) => {
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    setLoading(true);
    try {
      const res = await fetch('/auth/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        credentials: 'same-origin',
        body: JSON.stringify({ username, password }),
      });
      const data = await res.json();
      if (!res.ok) {
        setError(data.error || '登录失败');
        return;
      }
      onLogin(data.username);
    } catch {
      setError('网络连接失败，请稍后重试');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="min-h-screen flex items-center justify-center bg-[#f9f9f8]">
      <div className="w-full max-w-sm">
        <div className="bg-white rounded-2xl border border-[#e0ddd5] p-8" style={{ boxShadow: '0 8px 32px rgba(0,0,0,0.08)' }}>
          <div className="flex items-center justify-center mb-8">
            <div className="w-12 h-12 bg-[#d97757] rounded-xl flex items-center justify-center shadow-lg" style={{ boxShadow: '0 4px 24px rgba(217,119,87,0.25)' }}>
              <i className="fas fa-layer-group text-white text-xl"></i>
            </div>
          </div>
          <h1 className="text-xl font-bold text-center text-[#191918] mb-1">AI Dashboard</h1>
          <p className="text-sm text-center text-[#6b6b69] mb-8">请登录以继续</p>

          <form onSubmit={handleSubmit} className="space-y-5">
            <div>
              <label className="block text-xs font-medium text-[#4a4a48] mb-1.5">用户名</label>
              <input
                type="text"
                value={username}
                onChange={(e) => setUsername(e.target.value)}
                className="w-full px-4 py-3 bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl text-sm text-[#191918] outline-none focus:border-[#d97757] transition-colors placeholder:text-[#a0a09c]"
                placeholder="请输入用户名"
                autoFocus
                autoComplete="username"
              />
            </div>
            <div>
              <label className="block text-xs font-medium text-[#4a4a48] mb-1.5">密码</label>
              <input
                type="password"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                className="w-full px-4 py-3 bg-[#f9f9f8] border border-[#e0ddd5] rounded-xl text-sm text-[#191918] outline-none focus:border-[#d97757] transition-colors placeholder:text-[#a0a09c]"
                placeholder="请输入密码"
                autoComplete="current-password"
              />
            </div>

            {error && (
              <div className="text-sm text-red-600 bg-red-50 border border-red-200 rounded-lg px-4 py-2.5">
                {error}
              </div>
            )}

            <button
              type="submit"
              disabled={loading || !username || !password}
              className="w-full py-3 bg-[#d97757] text-white font-medium rounded-xl hover:bg-[#c4694d] disabled:opacity-40 transition-all text-sm"
              style={{ boxShadow: '0 4px 24px rgba(217,119,87,0.2)' }}
            >
              {loading ? (
                <span className="flex items-center justify-center space-x-2">
                  <i className="fas fa-spinner fa-spin"></i>
                  <span>登录中...</span>
                </span>
              ) : '登录'}
            </button>
          </form>
        </div>
        <p className="text-center text-xs text-[#a0a09c] mt-6">AI Dashboard 智能经营看板</p>
      </div>
    </div>
  );
};

export default LoginPage;
