// i18n 初始化 — 进 React 树之前必须 import 一次
// 语言持久化用 localStorage 'sololedger-lang'，桌面版/Web 版都通用

import i18n from 'i18next';
import { initReactI18next } from 'react-i18next';

import zhCN from './locales/zh-CN.json';
import zhTW from './locales/zh-TW.json';
import en from './locales/en.json';
import ja from './locales/ja.json';
import ko from './locales/ko.json';
import fr from './locales/fr.json';

export const SUPPORTED_LANGUAGES = [
  { code: 'zh-CN', label: '简体中文', flag: '🇨🇳' },
  { code: 'zh-TW', label: '繁體中文', flag: '🇹🇼' },
  { code: 'en', label: 'English', flag: '🇺🇸' },
  { code: 'ja', label: '日本語', flag: '🇯🇵' },
  { code: 'ko', label: '한국어', flag: '🇰🇷' },
  { code: 'fr', label: 'Français', flag: '🇫🇷' },
] as const;

export type LangCode = typeof SUPPORTED_LANGUAGES[number]['code'];

const STORAGE_KEY = 'sololedger-lang';

function detectInitialLang(): LangCode {
  try {
    const saved = typeof localStorage !== 'undefined' ? localStorage.getItem(STORAGE_KEY) : null;
    if (saved && SUPPORTED_LANGUAGES.some(l => l.code === saved)) return saved as LangCode;
  } catch { /* ignore */ }
  // 浏览器/系统语言侦测
  const sysLang = typeof navigator !== 'undefined' ? navigator.language : '';
  if (sysLang.startsWith('zh-TW') || sysLang.startsWith('zh-HK')) return 'zh-TW';
  if (sysLang.startsWith('zh')) return 'zh-CN';
  if (sysLang.startsWith('ja')) return 'ja';
  if (sysLang.startsWith('ko')) return 'ko';
  if (sysLang.startsWith('fr')) return 'fr';
  if (sysLang.startsWith('en')) return 'en';
  return 'zh-CN';
}

i18n
  .use(initReactI18next)
  .init({
    resources: {
      'zh-CN': { translation: zhCN },
      'zh-TW': { translation: zhTW },
      en: { translation: en },
      ja: { translation: ja },
      ko: { translation: ko },
      fr: { translation: fr },
    },
    lng: detectInitialLang(),
    fallbackLng: 'zh-CN',
    interpolation: { escapeValue: false }, // React 已经处理 XSS
    returnEmptyString: false,
  });

// 切换语言并持久化
export function setLanguage(code: LangCode) {
  i18n.changeLanguage(code);
  try { localStorage.setItem(STORAGE_KEY, code); } catch { /* ignore */ }
}

export function getCurrentLanguage(): LangCode {
  return (i18n.language as LangCode) || 'zh-CN';
}

export default i18n;
