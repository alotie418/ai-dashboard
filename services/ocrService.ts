
import { GoogleGenAI, Type } from "@google/genai";
import { getApiKey } from "./apiKey";

export interface ExtractedInvoice {
  date: string;
  customer: string;
  quantity: string;
  price: number;
  shipping: number;
  invoiceNo: string;
}

export const analyzeInvoice = async (base64Data: string, mimeType: string): Promise<ExtractedInvoice> => {
  const ai = new GoogleGenAI({ apiKey: getApiKey() });
  
  const prompt = `
    你是一位专业的财务审计员。请从这张发票图片中提取以下信息：
    - date: 开票日期 (格式: YYYY-MM-DD)
    - customer: 客户名称/购方名称
    - quantity: 货物数量及单位 (例如: "36.5吨 / 3650袋")
    - price: 成交价/总计金额 (不含税数字)
    - shipping: 运费/物流费用 (如果没找到则为 0)
    - invoiceNo: 发票号码 (20位数字左右)

    请以 JSON 格式返回结果。
  `;

  try {
    const response = await ai.models.generateContent({
      model: "gemini-3.1-flash-lite-preview",
      contents: [
        {
          parts: [
            { text: prompt },
            {
              inlineData: {
                data: base64Data,
                mimeType: mimeType
              }
            }
          ]
        }
      ],
      config: {
        responseMimeType: "application/json",
        responseSchema: {
          type: Type.OBJECT,
          properties: {
            date: { type: Type.STRING },
            customer: { type: Type.STRING },
            quantity: { type: Type.STRING },
            price: { type: Type.NUMBER },
            shipping: { type: Type.NUMBER },
            invoiceNo: { type: Type.STRING },
          },
          required: ["date", "customer", "quantity", "price", "shipping", "invoiceNo"],
        },
      },
    });

    const text = response.text;
    if (!text) throw new Error("AI response was empty");
    
    return JSON.parse(text) as ExtractedInvoice;
  } catch (error) {
    console.error("OCR Analysis Failed:", error);
    throw error;
  }
};
