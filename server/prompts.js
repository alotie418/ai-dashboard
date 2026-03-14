// Prompt builders for RAG agents — extracted from worker/src/index.js

export function buildPlanPrompt(query) {
  const year = new Date().getFullYear();
  return `你是一名专业的市场研究策略规划师。用户提出了一个市场调研问题，请分析并制定搜索策略。

用户查询: "${query}"

请完成以下任务：
1. **分类问题类型**（只选一个）：
   - factual: 事实查询（如"XX价格是多少"）
   - causal: 因果分析（如"为什么XX涨价"）
   - predictive: 预测类（如"XX价格走势预测"）
   - comparative: 对比类（如"A和B哪个更划算"）
   - evaluative: 评估类（如"XX值不值得买"、"采购建议"）

2. **判断是否需要 multi-hop 推理**：问题是否需要综合多条独立信息才能回答？

3. **生成子查询**（3-5条），每条标注类型：
   - **factual**: 直接获取核心事实数据的查询（如当前价格、规格参数）
   - **context**: 补充背景上下文的查询（如产业链、供需、行业动态）
   - **quantitative**: 获取定量统计数据的查询（如产量、进出口量、历史价格）
   - **counter**: 获取反面/风险视角的查询（如替代品、价格下跌因素）

要求：
- 子查询应该覆盖中文搜索和英文搜索场景
- 每条查询简洁明确，适合搜索引擎
- 包含时效性关键词（如"${year}年"、"最新"、"近期"）
- 返回纯 JSON，不要解释`;
}

export function buildExtractPrompt(query, searchResults) {
  const formatted = searchResults.map((r, i) =>
    `[结果${i + 1}] 来源: ${r.source || 'unknown'}\n标题: ${r.title}\n链接: ${r.url}\n内容: ${(r.content || '').slice(0, 800)}`
  ).join('\n\n');

  return `你是一个证据提取引擎。从以下搜索结果中提取与查询"${query}"相关的结构化证据。

搜索结果：
${formatted}

请提取以下信息：
1. **claims (论断)**: 每条数据点或观点作为一条独立论断
2. **numbers (定量数据)**: 提取所有数值及其单位和上下文（价格、产量、百分比等）
3. **entities (命名实体)**: 产品名、公司名、地名、平台名等
4. **viewpoints (观点)**: 市场参与者的看法或分析师观点
5. **uncertainty (不确定信息)**: 标记不确定、可能过时或存疑的信息
6. **confidence (置信度)**: 0.0-1.0，基于来源权威性和信息一致性

为每条证据分配唯一 claim_id (格式: c1, c2, c3...)。
type 字段取值: price_claim(价格数据) | supply_demand(供需) | trend(趋势) | opinion(观点) | fact(事实)

重要：
- 每条证据必须绑定 source_url（从搜索结果的链接中获取）
- 价格数据必须保留原始单位（元/吨、元/kg、USD/ton等）
- 不要编造数据，只提取搜索结果中实际存在的信息
- 最多返回20条最重要的证据，优先保留价格数据和定量信息

请严格按照以下 JSON 结构输出：
{"evidence": [{"claim_id": "c1", "text": "论断原文摘要", "type": "price_claim", "numbers": [{"value": 280, "unit": "元/吨", "context": "软水盐出厂价"}], "entities": ["中盐"], "source_url": "https://example.com", "confidence": 0.85}]}

viewpoints 和 uncertainty 字段可选，如有则添加为字符串数组。`;
}

export function buildSynthesisPrompt(query, questionType, evidencePool, iteration) {
  // Sanitize evidence text to prevent prompt injection
  const evidenceText = evidencePool.map((e, i) => {
    const safeText = JSON.stringify(e.text || '').slice(1, -1);
    const safeNumbers = (e.numbers || []).map(n => `${n.value}${n.unit}(${n.context})`).join(', ');
    const safeUrl = (e.source_url || '').replace(/[<>"'`]/g, '');
    return `[证据${i + 1}] (${e.type}, 置信度:${e.confidence})\n${safeText}\n数值: ${safeNumbers}\n来源: ${safeUrl}`;
  }).join('\n\n');

  return `你是一名专业的市场分析综合引擎。这是第 ${iteration} 轮分析。

原始查询: "${query}"
问题类型: ${questionType}
证据数量: ${evidencePool.length} 条

结构化证据池：
${evidenceText}

请完成以下任务：
1. **聚类相似论断**: 将相关的证据聚合在一起
2. **识别共识**: 找出多个来源一致支持的结论（填入 consensus 数组）
3. **检测矛盾**: 找出不同来源之间冲突的数据或观点（填入 contradictions 数组）
4. **聚合定量数据**: 计算价格区间、均值、趋势方向
5. **标注引用**: analysis 中的关键数据用"(来源: URL)"标注
6. **估算信心分**: 基于证据覆盖度、一致性和来源质量，给出 0.0-1.0 的 confidence_score

输出要求：
- **analysis**: Markdown 格式的分析报告，包含：
  - ### 📊 价格行情（主流价格区间、市场均价）
  - ### 🛒 电商平台对比（各平台报价差异）
  - ### 💡 销售建议（卖家定价策略、渠道选择）
  - ### 🛍️ 购买建议（买家最佳入手渠道、避坑指南）
  禁止使用三个星号(***), 仅使用两个星号(**)。不要返回 Markdown 代码块标记。

- **summaryTable**: 关键数据汇总，包含最低价、最高价、价格区间、市场均价、推荐对标平台、数据来源数量等。
  label 简短（≤10汉字），value 格式: "数值 单位 (来源)"

- **prices**: 从证据中提取的所有价格条目。
  **价格单位规则**（严格遵守）：
  - **仅以下工业散货品类需要换算为"元/吨"**：软水盐、工业盐、离子交换树脂再生剂、融雪剂、除冰盐、原盐、海盐（工业用途）、以及其他明确按吨交易的大宗工业原料
  - **其他所有产品保留原始价格单位**，如 元/台、元/个、元/箱、元/瓶、元/kg、元/件 等

  工业散货换算规则（仅适用于上述品类）：
  1. 识别包装规格总重量：10kg*2袋 = 20kg；4.5kg = 4.5kg；10kg = 10kg；25kg/袋 = 25kg；50斤 = 25kg
  2. 换算公式：price_per_ton = (该包装总售价 / 总重量kg) × 1000
  3. 如果原始单位已经是"吨"或"元/吨"，直接保留数值
  4. 如果原始单位是"元/kg"，则乘以 1000
  5. 如果是整包价格（如 ¥25/10kg），则 = (25/10) × 1000 = 2500 元/吨

  每条包含：
  - platform: 平台名
  - title: 商品标题
  - price: 数字。工业散货品类填换算后的元/吨单价；其他产品填原始价格数值
  - priceUnit: 工业散货品类填 "元/吨"；其他产品填原始单位（如 "元/台"、"元/个"、"元/kg" 等）
  - original_price_str: 原始价格字符串，如 "¥25/10kg*2袋"、"1000元/吨"、"¥65/袋(10kg)"、"¥299/台"
  - spec: 包装规格描述，如 "20kg (10kg×2袋)"、"10kg/袋"、"散装/吨"、"单台"
  - link: 真实URL，禁止编造。无 URL 则填空字符串 ""
  - platformCategory: B2C|B2B|industry|international

- **consensus**: 多源一致的共识结论列表
- **contradictions**: 不同来源的矛盾发现列表
- **confidence_score**: 综合信心评分

请确保分析专业、数据准确。`;
}

export function buildCritiquePrompt(query, questionType, synthesis, evidencePool, iteration, maxIterations) {
  return `你是一名严格的研究质量评审员。请评估以下市场研究的完整性和质量。

原始查询: "${query}"
问题类型: ${questionType}
当前轮次: ${iteration}/${maxIterations}
证据数量: ${evidencePool.length} 条
当前信心分: ${synthesis.confidence_score || 0}

共识结论: ${JSON.stringify(synthesis.consensus || [])}
矛盾发现: ${JSON.stringify(synthesis.contradictions || [])}
价格条目数: ${(synthesis.prices || []).length}

分析报告摘要（前500字）:
${(synthesis.analysis || '').slice(0, 500)}

请严格评估以下维度：
1. **缺失视角**: 是否有重要的分析角度被遗漏？（如供需面、政策面、国际对比、替代品分析）
2. **定量数据充分性**: 价格数据是否覆盖了主要渠道和规格？数量是否够支撑结论？
3. **矛盾解决**: 发现的矛盾是否已合理解释？
4. **时效性**: 数据是否足够新？是否反映了最近的市场变动？
5. **信心评估**: 综合以上维度，给出 0.0-1.0 的信心分
   - ≥ 0.8: 通过，数据充分，可输出最终结果
   - < 0.8: 不通过，需要补充搜索

${iteration >= maxIterations ? '注意：这是最后一轮，即使信心不足也应设 needs_more_search=false，并在 reasoning 中说明剩余不足。' : ''}

如果 needs_more_search=true，请在 new_queries 中生成 1-3 条精准的补充搜索查询，专门针对缺失的维度。

返回纯 JSON。`;
}
