/**
 * 结构化记忆系统类型定义。
 * 从 Hermes Holographic Memory 移植，适配 TypeScript/Bun 运行时。
 */

/** 事实分类 */
export type FactCategory = 'identity' | 'coding_style' | 'tool_pref' | 'workflow' | 'project' | 'general'

/** 已废弃的旧分类值（兼容映射用） */
export const LEGACY_CATEGORIES: Record<string, FactCategory> = {
  user_pref: 'identity',
  tool: 'tool_pref',
}

/** 全局库 category 集合（非 project 的都存全局库） */
export const GLOBAL_CATEGORIES = new Set<FactCategory>(['identity', 'coding_style', 'tool_pref', 'workflow', 'general'])

/** 需要始终注入 system prompt 的 category */
export const ALWAYS_INJECT_CATEGORIES = new Set<FactCategory>(['identity', 'workflow'])

/** 需要按项目技术栈匹配注入的 category */
export const TECH_MATCH_CATEGORIES = new Set<FactCategory>(['coding_style'])

/** 存储的事实记录 */
export interface Fact {
  factId: number
  content: string
  category: FactCategory
  tags: string
  keywords: string
  trustScore: number
  retrievalCount: number
  helpfulCount: number
  createdAt: string
  updatedAt: string
}

/** 带评分的检索结果 */
export interface ScoredFact extends Fact {
  score: number
}

/** 矛盾检测结果 */
export interface Contradiction {
  factA: Omit<Fact, never>
  factB: Omit<Fact, never>
  entityOverlap: number
  contentSimilarity: number
  contradictionScore: number
  sharedEntities: string[]
}

/** 检索选项 */
export interface SearchOptions {
  category?: FactCategory
  minTrust?: number
  limit?: number
}

/** 矛盾检测选项 */
export interface ContradictOptions {
  category?: FactCategory
  threshold?: number
  limit?: number
}

/** 检索器配置 */
export interface RetrieverOptions {
  ftsWeight?: number
  jaccardWeight?: number
  temporalDecayHalfLife?: number
}

/** fact_store 工具调用参数 */
export interface FactStoreArgs {
  action: 'add' | 'search' | 'probe' | 'related' | 'reason' | 'contradict' | 'update' | 'remove' | 'list'
  content?: string
  query?: string
  entity?: string
  entities?: string[]
  fact_id?: number
  category?: FactCategory
  tags?: string
  trust_delta?: number
  min_trust?: number
  limit?: number
}

/** fact_feedback 工具调用参数 */
export interface FactFeedbackArgs {
  action: 'helpful' | 'unhelpful'
  fact_id: number
}

/** Provider 生命周期上下文 */
export interface ProviderContext {
  sessionId: string
  projectRoot: string
  configHome: string
}

/** 工具 Schema（兼容 Anthropic tool_use 格式） */
export interface ToolSchema {
  name: string
  description: string
  input_schema: {
    type: 'object'
    properties: Record<string, unknown>
    required: string[]
  }
}

/** 安全扫描结果 */
export interface SecurityScanResult {
  safe: boolean
  warnings: string[]
  hasPii: boolean
  injectionAttempts: string[]
}
