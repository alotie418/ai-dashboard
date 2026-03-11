// Ranking and deduplication logic — extracted from worker/src/index.js
import { embedTexts, cosineSimilarity } from './embedding.js';

/** Domain authority scores for ranking */
const DOMAIN_AUTHORITY = {
  '100ppi.com': 0.95,      // 生意社
  'sci99.com': 0.93,       // 卓创资讯
  'mysteel.com': 0.92,     // 我的钢铁网
  'baiinfo.com': 0.90,     // 百川盈孚
  'chem99.com': 0.88,      // 中化信息
  'alibaba.com': 0.80,     // 阿里国际
  '1688.com': 0.78,        // 1688
  'jd.com': 0.75,          // 京东
  'taobao.com': 0.70,      // 淘宝
  'tmall.com': 0.72,       // 天猫
  'pinduoduo.com': 0.68,   // 拼多多
  'amazon.com': 0.76,      // Amazon
  'zhihu.com': 0.50,       // 知乎
  'baidu.com': 0.45,       // 百度
};

/** Extract tokens (CJK bigrams + ASCII words) for text matching */
function extractTokens(str) {
  if (!str) return [];
  const tokens = [];
  const asciiWords = str.match(/[a-zA-Z0-9]{2,}/g);
  if (asciiWords) {
    for (const w of asciiWords) tokens.push(w.toLowerCase());
  }
  const cjkChars = str.match(/[\u4e00-\u9fff\u3400-\u4dbf]/g);
  if (cjkChars && cjkChars.length >= 2) {
    for (let i = 0; i < cjkChars.length - 1; i++) {
      tokens.push(cjkChars[i] + cjkChars[i + 1]);
    }
  }
  return tokens;
}

export function getDomainAuthority(url) {
  if (!url) return 0.3;
  try {
    const hostname = new URL(url).hostname.replace(/^www\./, '');
    for (const [domain, score] of Object.entries(DOMAIN_AUTHORITY)) {
      if (hostname === domain || hostname.endsWith('.' + domain)) return score;
    }
  } catch {}
  return 0.4; // default for unknown domains
}

export function computeRelevance(query, title, content) {
  const qTokens = extractTokens(query);
  if (qTokens.length === 0) return 0.5;
  const combined = (title || '') + ' ' + (content || '').slice(0, 500);
  const cTokens = new Set(extractTokens(combined));
  let hits = 0;
  for (const t of qTokens) { if (cTokens.has(t)) hits++; }
  return Math.min(1.0, hits / qTokens.length);
}

export function computeRecency(publishedDate) {
  if (!publishedDate) return 0.3;
  try {
    const d = new Date(publishedDate);
    const now = new Date();
    const daysDiff = (now - d) / (1000 * 60 * 60 * 24);
    if (daysDiff <= 1) return 1.0;
    if (daysDiff <= 7) return 0.9;
    if (daysDiff <= 30) return 0.7;
    if (daysDiff <= 90) return 0.5;
    if (daysDiff <= 365) return 0.3;
    return 0.1;
  } catch { return 0.3; }
}

export function bigramSimilarity(a, b) {
  const tokA = extractTokens(a);
  const tokB = extractTokens(b);
  if (tokA.length === 0 || tokB.length === 0) return 0;
  const setA = new Set(tokA);
  let common = 0;
  for (const t of tokB) { if (setA.has(t)) common++; }
  return common / Math.max(tokA.length, tokB.length);
}

export function rankAndDedup(query, results) {
  // Step 1: URL dedup
  const urlSeen = new Set();
  let removedUrls = 0;
  const urlDeduped = results.filter(r => {
    if (!r.url) return true;
    const norm = r.url.replace(/[?#].*$/, '').replace(/\/$/, '').toLowerCase();
    if (urlSeen.has(norm)) { removedUrls++; return false; }
    urlSeen.add(norm);
    return true;
  });

  // Step 2: Title similarity dedup (>0.85)
  let removedSimilar = 0;
  const titleDeduped = [];
  for (const r of urlDeduped) {
    let isDup = false;
    for (const kept of titleDeduped) {
      if (bigramSimilarity(r.title || '', kept.title || '') > 0.85) {
        isDup = true;
        removedSimilar++;
        break;
      }
    }
    if (!isDup) titleDeduped.push(r);
  }

  // Step 3: Score and rank
  const sourceSeen = new Set();
  const scored = titleDeduped.map(r => {
    const relevance = computeRelevance(query, r.title, r.content);
    const authority = getDomainAuthority(r.url);
    const recency = computeRecency(r.published_date);
    const isNewSource = !sourceSeen.has(r.source);
    if (r.source) sourceSeen.add(r.source);
    const diversity = isNewSource ? 1.0 : 0.3;
    const score = 0.35 * relevance + 0.25 * authority + 0.2 * recency + 0.2 * diversity;
    return { ...r, score: Math.round(score * 1000) / 1000, relevance, authority, recency, diversity };
  });

  scored.sort((a, b) => b.score - a.score);

  return {
    ranked: scored,
    dedup_stats: {
      before: results.length,
      after: scored.length,
      removed_urls: removedUrls,
      removed_similar: removedSimilar,
    },
  };
}

/**
 * Semantic version of rankAndDedup using Gemini Embedding 2.
 * Uses cosine similarity for dedup and relevance scoring.
 * Falls back to keyword-based rankAndDedup on embedding API failure.
 */
export async function rankAndDedupSemantic(apiKey, query, results) {
  try {
    // Step 1: URL dedup (same as original — cheap, no API needed)
    const urlSeen = new Set();
    let removedUrls = 0;
    const urlDeduped = results.filter(r => {
      if (!r.url) return true;
      const norm = r.url.replace(/[?#].*$/, '').replace(/\/$/, '').toLowerCase();
      if (urlSeen.has(norm)) { removedUrls++; return false; }
      urlSeen.add(norm);
      return true;
    });

    // Step 2: Embed query + all document texts in one batch
    const docTexts = urlDeduped.map(r => ((r.title || '') + ' ' + (r.content || '').slice(0, 500)).trim());
    const allTexts = [query, ...docTexts];
    const embeddings = await embedTexts(apiKey, allTexts, 'RETRIEVAL_DOCUMENT');

    if (embeddings.length !== allTexts.length) {
      console.warn('[Rank] Embedding count mismatch, falling back to keyword ranking');
      return rankAndDedup(query, results);
    }

    const queryEmb = embeddings[0];
    const docEmbs = embeddings.slice(1);

    // Step 3: Semantic title dedup (cosine > 0.85)
    let removedSimilar = 0;
    const titleDeduped = [];
    const titleDedupedEmbs = [];
    for (let i = 0; i < urlDeduped.length; i++) {
      let isDup = false;
      for (let j = 0; j < titleDedupedEmbs.length; j++) {
        if (cosineSimilarity(docEmbs[i], titleDedupedEmbs[j]) > 0.85) {
          isDup = true;
          removedSimilar++;
          break;
        }
      }
      if (!isDup) {
        titleDeduped.push(urlDeduped[i]);
        titleDedupedEmbs.push(docEmbs[i]);
      }
    }

    // Step 4: Score with semantic relevance + domain authority + recency + diversity
    const sourceSeen = new Set();
    const scored = titleDeduped.map((r, i) => {
      const relevance = Math.max(0, cosineSimilarity(queryEmb, titleDedupedEmbs[i]));
      const authority = getDomainAuthority(r.url);
      const recency = computeRecency(r.published_date);
      const isNewSource = !sourceSeen.has(r.source);
      if (r.source) sourceSeen.add(r.source);
      const diversity = isNewSource ? 1.0 : 0.3;
      const score = 0.35 * relevance + 0.25 * authority + 0.2 * recency + 0.2 * diversity;
      return { ...r, score: Math.round(score * 1000) / 1000, relevance: Math.round(relevance * 1000) / 1000, authority, recency, diversity };
    });

    scored.sort((a, b) => b.score - a.score);

    return {
      ranked: scored,
      dedup_stats: {
        before: results.length,
        after: scored.length,
        removed_urls: removedUrls,
        removed_similar: removedSimilar,
        method: 'semantic',
      },
    };
  } catch (err) {
    console.warn(`[Rank] Semantic ranking failed (${err.message}), falling back to keyword ranking`);
    return rankAndDedup(query, results);
  }
}
