// Response schemas and validation for RAG agents — extracted from worker/src/index.js

export const PLAN_RESPONSE_SCHEMA = {
  type: 'OBJECT',
  properties: {
    question_type: { type: 'STRING', description: 'factual|causal|predictive|comparative|evaluative' },
    multi_hop_required: { type: 'BOOLEAN' },
    sub_queries: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: {
          type: { type: 'STRING', description: 'factual|context|quantitative|counter' },
          query: { type: 'STRING' },
        },
        required: ['type', 'query'],
      },
    },
  },
  required: ['question_type', 'multi_hop_required', 'sub_queries'],
};

export const EXTRACT_RESPONSE_SCHEMA = {
  type: 'OBJECT',
  properties: {
    evidence: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: {
          claim_id: { type: 'STRING' },
          text: { type: 'STRING', description: '论断原文' },
          type: { type: 'STRING', description: 'price_claim|supply_demand|trend|opinion|fact' },
          numbers: {
            type: 'ARRAY',
            items: {
              type: 'OBJECT',
              properties: {
                value: { type: 'NUMBER' },
                unit: { type: 'STRING' },
                context: { type: 'STRING' },
              },
              required: ['value', 'unit', 'context'],
            },
          },
          entities: { type: 'ARRAY', items: { type: 'STRING' } },
          viewpoints: { type: 'ARRAY', items: { type: 'STRING' } },
          uncertainty: { type: 'ARRAY', items: { type: 'STRING' } },
          source_url: { type: 'STRING' },
          confidence: { type: 'NUMBER', description: '0.0-1.0' },
        },
        required: ['claim_id', 'text', 'type', 'numbers', 'entities', 'source_url', 'confidence'],
      },
    },
  },
  required: ['evidence'],
};

export const SYNTHESIS_RESPONSE_SCHEMA = {
  type: 'OBJECT',
  properties: {
    analysis: { type: 'STRING', description: '结构化Markdown分析报告' },
    summaryTable: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: {
          label: { type: 'STRING' },
          value: { type: 'STRING' },
        },
        required: ['label', 'value'],
      },
    },
    prices: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: {
          platform: { type: 'STRING' },
          title: { type: 'STRING' },
          price: { type: 'NUMBER', description: '标准化后的元/吨单价' },
          priceUnit: { type: 'STRING', description: '固定为 元/吨' },
          original_price_str: { type: 'STRING', description: '原始价格字符串, 如 ¥25/10kg' },
          spec: { type: 'STRING', description: '包装规格, 如 20kg (10kg×2袋)' },
          link: { type: 'STRING' },
          platformCategory: { type: 'STRING' },
        },
        required: ['platform', 'title', 'price', 'priceUnit', 'link', 'platformCategory'],
      },
    },
    consensus: { type: 'ARRAY', items: { type: 'STRING' }, description: '多源一致的共识结论' },
    contradictions: { type: 'ARRAY', items: { type: 'STRING' }, description: '不同来源的矛盾发现' },
    confidence_score: { type: 'NUMBER', description: '综合信心评分 0.0-1.0' },
  },
  required: ['analysis', 'prices', 'summaryTable', 'consensus', 'contradictions', 'confidence_score'],
};

export const CRITIQUE_RESPONSE_SCHEMA = {
  type: 'OBJECT',
  properties: {
    needs_more_search: { type: 'BOOLEAN' },
    missing_aspects: { type: 'ARRAY', items: { type: 'STRING' } },
    new_queries: { type: 'ARRAY', items: { type: 'STRING' } },
    confidence_score: { type: 'NUMBER', description: '0.0-1.0' },
    reasoning: { type: 'STRING' },
  },
  required: ['needs_more_search', 'missing_aspects', 'new_queries', 'confidence_score', 'reasoning'],
};

// ==================== Validation ====================

const VALID_EVIDENCE_TYPES = new Set(['price_claim', 'supply_demand', 'trend', 'opinion', 'fact']);

/** Validate & sanitize extract response when responseSchema is not enforced */
export function validateExtractResponse(raw) {
  if (!raw || typeof raw !== 'object') return { evidence: [] };
  const evidence = Array.isArray(raw.evidence) ? raw.evidence : [];
  const validated = evidence
    .filter(e => e && typeof e === 'object' && e.claim_id && e.text && e.source_url)
    .map(e => ({
      claim_id: String(e.claim_id),
      text: String(e.text).slice(0, 500),
      type: VALID_EVIDENCE_TYPES.has(e.type) ? e.type : 'fact',
      numbers: Array.isArray(e.numbers) ? e.numbers.filter(n => n && typeof n.value === 'number').map(n => ({
        value: n.value,
        unit: String(n.unit || ''),
        context: String(n.context || ''),
      })) : [],
      entities: Array.isArray(e.entities) ? e.entities.filter(x => typeof x === 'string') : [],
      viewpoints: Array.isArray(e.viewpoints) ? e.viewpoints.filter(x => typeof x === 'string') : [],
      uncertainty: Array.isArray(e.uncertainty) ? e.uncertainty.filter(x => typeof x === 'string') : [],
      source_url: String(e.source_url),
      confidence: typeof e.confidence === 'number' ? Math.min(1, Math.max(0, e.confidence)) : 0.5,
    }))
    .slice(0, 30); // hard cap
  return { evidence: validated };
}

/**
 * Parse JSON from Gemini text output — handles markdown code blocks, partial JSON, etc.
 */
export function parseGeminiJSON(text) {
  if (!text) return null;

  // Try direct parse first
  try {
    return JSON.parse(text);
  } catch {}

  // Try extracting from markdown code block
  const codeBlockMatch = text.match(/```(?:json)?\s*([\s\S]*?)```/);
  if (codeBlockMatch) {
    try {
      return JSON.parse(codeBlockMatch[1].trim());
    } catch {}
  }

  // Try finding JSON object in text
  const jsonMatch = text.match(/\{[\s\S]*\}/);
  if (jsonMatch) {
    try {
      return JSON.parse(jsonMatch[0]);
    } catch {}
  }

  return null;
}
