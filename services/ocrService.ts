
export interface ExtractedInvoice {
  date: string;
  customer: string;
  quantity: string;
  price: number;
  shipping: number;
  invoiceNo: string;
  totalWithTax: number;
  unitPriceWithoutTax: number;
  taxAmount: number;
}

function isElectron(): boolean {
  return typeof window !== 'undefined' && !!(window as any).electronAPI?.isElectron;
}

export const analyzeInvoice = async (base64Data: string, mimeType: string): Promise<ExtractedInvoice> => {
  if (isElectron()) {
    return (window as any).electronAPI.invoke('api:request', {
      method: 'POST',
      path: '/api/ai/ocr',
      body: { base64Data, mimeType },
    });
  }

  const response = await fetch('/api/ai/ocr', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    credentials: 'same-origin',
    body: JSON.stringify({ base64Data, mimeType }),
  });

  if (!response.ok) {
    const err = await response.json().catch(() => ({ error: 'Unknown error' }));
    throw new Error(err.error || `OCR failed (${response.status})`);
  }

  return response.json() as Promise<ExtractedInvoice>;
};
