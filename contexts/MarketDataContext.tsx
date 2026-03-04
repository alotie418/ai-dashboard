import React, { createContext, useContext, useState, useCallback } from 'react';
import { MarketSearchResponse } from '../types';

export interface MarketDataContextType {
  latestQuery: string | null;
  latestResults: MarketSearchResponse | null;
  searchTimestamp: number | null;
  setMarketData: (query: string, results: MarketSearchResponse) => void;
  clearMarketData: () => void;
}

const MarketDataContext = createContext<MarketDataContextType>({
  latestQuery: null,
  latestResults: null,
  searchTimestamp: null,
  setMarketData: () => {},
  clearMarketData: () => {},
});

export const useMarketData = () => useContext(MarketDataContext);

export const MarketDataProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const [latestQuery, setLatestQuery] = useState<string | null>(null);
  const [latestResults, setLatestResults] = useState<MarketSearchResponse | null>(null);
  const [searchTimestamp, setSearchTimestamp] = useState<number | null>(null);

  const setMarketData = useCallback((query: string, results: MarketSearchResponse) => {
    setLatestQuery(query);
    setLatestResults(results);
    setSearchTimestamp(Date.now());
  }, []);

  const clearMarketData = useCallback(() => {
    setLatestQuery(null);
    setLatestResults(null);
    setSearchTimestamp(null);
  }, []);

  return (
    <MarketDataContext.Provider value={{
      latestQuery, latestResults, searchTimestamp, setMarketData, clearMarketData
    }}>
      {children}
    </MarketDataContext.Provider>
  );
};
