export const getApiKey = (): string => {
  const key = import.meta.env.VITE_API_KEY as string | undefined;
  if (!key) {
    throw new Error('API Key 未配置。请在 .env 文件中设置 VITE_API_KEY。');
  }
  return key;
};


export const getGoogleSearchCx = (): string => {
  const cx = import.meta.env.VITE_GOOGLE_SEARCH_CX as string | undefined;
  if (!cx) {
    throw new Error('Google Search CX 未配置。请在 .env 文件中设置 VITE_GOOGLE_SEARCH_CX。');
  }
  return cx;
};

export const getGoogleSearchApiKey = (): string => {
  const key = import.meta.env.VITE_GOOGLE_SEARCH_API_KEY as string | undefined;
  if (!key) {
    throw new Error('Google Search API Key 未配置。请在 .env 文件中设置 VITE_GOOGLE_SEARCH_API_KEY。');
  }
  return key;
};

