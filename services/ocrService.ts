
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

export const analyzeInvoice = async (base64Data: string, mimeType: string): Promise<ExtractedInvoice> => {
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
