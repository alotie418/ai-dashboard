
import { GoogleGenAI } from "@google/genai";
import { getApiKey } from "./apiKey";

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
  const ai = new GoogleGenAI({ apiKey: getApiKey() });

  const prompt = `
    你是一位专业的财务审计员。请从这张发票图片中提取以下信息，并严格以 JSON 格式返回（不要包含 markdown 代码块标记）：
    {
      "date": "开票日期，格式 YYYY-MM-DD",
      "customer": "客户名称/购方名称",
      "quantity": "货物总数量及单位，例如 36.5吨 / 3650袋（如有多行货物请合计总数量）",
      "price": 合计不含税金额数字（即"金额"栏的合计值）,
      "shipping": 运费数字（没有则为0）,
      "invoiceNo": "发票号码",
      "totalWithTax": 价税合计金额数字（即发票上"价税合计"或"（小写）"对应的含税总额）,
      "unitPriceWithoutTax": 不含税单价数字（即"单价"栏的值，如有多行货物取第一行的单价）,
      "taxAmount": 合计税额数字（即"税额"栏的合计值）
    }

    注意：price、shipping、totalWithTax、unitPriceWithoutTax、taxAmount 必须是数字，不要加引号。如果发票上没有对应字段则填 0。
  `;

  try {
    const response = await ai.models.generateContent({
      model: "gemini-2.0-flash",
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
    });

    const text = response.text;
    if (!text) throw new Error("AI response was empty");

    // Strip markdown code fences if present
    const cleaned = text.replace(/^```(?:json)?\s*\n?/i, '').replace(/\n?```\s*$/i, '').trim();

    return JSON.parse(cleaned) as ExtractedInvoice;
  } catch (error) {
    console.error("OCR Analysis Failed:", error);
    throw error;
  }
};
