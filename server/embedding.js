// Gemini Embedding 2 — semantic similarity for RAG ranking & dedup
// Model: gemini-embedding-2-preview (released 2026-03-10)
// Supports 8192 tokens, 3072 dimensions, MRL-based dimension reduction

const EMBEDDING_MODEL = 'gemini-embedding-2-preview';
const EMBEDDING_API_BASE = 'https://generativelanguage.googleapis.com/v1beta/models';
const DEFAULT_DIMENSIONS = 256; // MRL: use 256 for fast cosine sim (sufficient for ranking/dedup)

/**
 * Embed a batch of texts using Gemini Embedding 2.
 * @param {string} apiKey
 * @param {string[]} texts - Array of text strings to embed
 * @param {'RETRIEVAL_QUERY'|'RETRIEVAL_DOCUMENT'|'SEMANTIC_SIMILARITY'} taskType
 * @param {number} [dimensions=256] - Output dimensions (MRL)
 * @returns {Promise<number[][]>} Array of embedding vectors
 */
export async function embedTexts(apiKey, texts, taskType = 'SEMANTIC_SIMILARITY', dimensions = DEFAULT_DIMENSIONS) {
  if (!texts.length) return [];

  // Batch into chunks of 100 (API limit)
  const BATCH_SIZE = 100;
  const allEmbeddings = [];

  for (let i = 0; i < texts.length; i += BATCH_SIZE) {
    const batch = texts.slice(i, i + BATCH_SIZE);
    const url = `${EMBEDDING_API_BASE}/${EMBEDDING_MODEL}:batchEmbedContents?key=${apiKey}`;

    const requests = batch.map(text => ({
      model: `models/${EMBEDDING_MODEL}`,
      content: { parts: [{ text: text.slice(0, 8000) }] }, // safety truncate
      taskType,
      outputDimensionality: dimensions,
    }));

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 30000); // 30s timeout

    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ requests }),
        signal: controller.signal,
      });
      clearTimeout(timer);

      if (!res.ok) {
        const errText = await res.text();
        throw new Error(`Embedding API HTTP ${res.status}: ${errText.slice(0, 300)}`);
      }

      const result = await res.json();
      const embeddings = (result.embeddings || []).map(e => e.values || []);
      allEmbeddings.push(...embeddings);
    } catch (err) {
      clearTimeout(timer);
      if (err.name === 'AbortError') {
        throw new Error(`Embedding API timeout after 30s`);
      }
      throw err;
    }
  }

  return allEmbeddings;
}

/**
 * Cosine similarity between two vectors.
 * @param {number[]} a
 * @param {number[]} b
 * @returns {number} similarity in [-1, 1]
 */
export function cosineSimilarity(a, b) {
  if (a.length !== b.length || a.length === 0) return 0;
  let dot = 0, normA = 0, normB = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  const denom = Math.sqrt(normA) * Math.sqrt(normB);
  return denom === 0 ? 0 : dot / denom;
}

/**
 * MMR (Maximal Marginal Relevance) selection.
 * Balances relevance to query with diversity among selected items.
 * @param {number[]} queryEmbedding
 * @param {number[][]} docEmbeddings
 * @param {number} k - Number of items to select
 * @param {number} lambda - Balance factor (1.0 = pure relevance, 0.0 = pure diversity)
 * @returns {number[]} Indices of selected items in MMR order
 */
export function mmrSelect(queryEmbedding, docEmbeddings, k, lambda = 0.7) {
  const n = docEmbeddings.length;
  if (n === 0) return [];
  k = Math.min(k, n);

  // Pre-compute query similarities
  const querySims = docEmbeddings.map(d => cosineSimilarity(queryEmbedding, d));

  const selected = [];
  const remaining = new Set(Array.from({ length: n }, (_, i) => i));

  for (let step = 0; step < k; step++) {
    let bestIdx = -1;
    let bestScore = -Infinity;

    for (const idx of remaining) {
      const relevance = querySims[idx];

      // Max similarity to any already-selected doc
      let maxSimToSelected = 0;
      for (const selIdx of selected) {
        const sim = cosineSimilarity(docEmbeddings[idx], docEmbeddings[selIdx]);
        if (sim > maxSimToSelected) maxSimToSelected = sim;
      }

      const mmrScore = lambda * relevance - (1 - lambda) * maxSimToSelected;
      if (mmrScore > bestScore) {
        bestScore = mmrScore;
        bestIdx = idx;
      }
    }

    if (bestIdx >= 0) {
      selected.push(bestIdx);
      remaining.delete(bestIdx);
    }
  }

  return selected;
}

export { EMBEDDING_MODEL, DEFAULT_DIMENSIONS };
