/**
 * SQLite 结构化事实存储 Provider（双层架构）。
 *
 * 全局库: ~/.claude/memory/facts.db — identity / coding_style / tool_pref / workflow / general
 * 项目库: {project}/.claude/memory/facts.db — project
 *
 * 注入策略：
 * - identity / workflow → 始终注入 system prompt
 * - coding_style → 按项目技术栈匹配注入
 * - tool_pref / general / project → prefetch 检索注入
 * - 项目概览（一条 project 事实，tags 含 "project_overview"）→ 始终注入
 */

import { join, relative } from 'node:path'
import { homedir } from 'node:os'
import { existsSync, statSync, readdirSync, readFileSync } from 'node:fs'
import { MemoryProvider } from '../MemoryProvider'
import { MemoryStore } from '../store/MemoryStore'
import { FactRetriever } from '../store/FactRetriever'
import { scanForInjection } from '../security'
import { LEGACY_CATEGORIES, GLOBAL_CATEGORIES } from '../types'
import type { ToolSchema, ProviderContext, FactStoreArgs, FactFeedbackArgs, FactCategory, ScoredFact } from '../types'

// -- 工具 Schema 定义 --

const FACT_STORE_SCHEMA: ToolSchema = {
  name: 'fact_store',
  description: `结构化事实记忆系统（SQLite+FTS5 索引）。支持读写。

双层存储：
- 全局库（identity/coding_style/tool_pref/workflow/general）：跨项目共享
- 项目库（project）：跟随项目

操作：
- search — 关键词查找
- probe — 实体探测：关于某人/某事的所有事实
- related — 实体关联
- reason — 组合推理：同时关联多个实体的事实
- contradict — 矛盾检测
- list — 浏览事实
- add — 添加新事实（自动去重，相似则更新）
- update — 更新已有事实
- remove — 删除事实

写入说明：
- 添加前先 search 检查是否已存在相似事实
- identity/coding_style/tool_pref/workflow/general → 全局库
- project → 项目库`,
  input_schema: {
    type: 'object',
    properties: {
      action: {
        type: 'string',
        enum: ['add', 'search', 'probe', 'related', 'reason', 'contradict', 'update', 'remove', 'list'],
      },
      content: { type: 'string', description: "事实内容（'add' 必需）" },
      query: { type: 'string', description: "搜索查询（'search' 必需）" },
      entity: { type: 'string', description: "实体名（'probe'/'related' 使用）" },
      entities: { type: 'array', items: { type: 'string' }, description: "实体列表（'reason' 使用）" },
      fact_id: { type: 'number', description: "事实 ID（'update'/'remove' 使用）" },
      category: { type: 'string', enum: ['identity', 'coding_style', 'tool_pref', 'workflow', 'project', 'general'] },
      tags: { type: 'string', description: '逗号分隔标签' },
      trust_delta: { type: 'number', description: "'update' 的信任调整值" },
      min_trust: { type: 'number', description: '最低信任过滤（默认 0.3）' },
      limit: { type: 'number', description: '最大结果数（默认 10）' },
    },
    required: ['action'],
  },
}

const FACT_FEEDBACK_SCHEMA: ToolSchema = {
  name: 'fact_feedback',
  description: '使用事实后评分。标记 helpful 如果准确，unhelpful 如果过时。训练记忆系统 — 好事实上升，坏事实下降。',
  input_schema: {
    type: 'object',
    properties: {
      action: { type: 'string', enum: ['helpful', 'unhelpful'] },
      fact_id: { type: 'number', description: '要评分的事实 ID' },
    },
    required: ['action', 'fact_id'],
  },
}

/** 旧 category 到新 category 的关键词映射（用于数据迁移，顺序敏感：更具体的规则先执行） */
const MIGRATION_RULES: Array<{ from: string; to: FactCategory; keywords: string[] }> = [
  // coding_style 先执行（更具体，避免被 identity 关键词误匹配）
  {
    from: 'user_pref',
    to: 'coding_style',
    keywords: ['编码', '命名', '文件', '规范', 'Python', 'Go', 'TypeScript', '设计模式', '测试', 'IDE', '检查', '限制', 'ruff', 'lint'],
  },
  // identity 后执行（兜底：剩余的 user_pref 都归入 identity）
  {
    from: 'user_pref',
    to: 'identity',
    keywords: ['姓名', '名字', '称呼', '角色', '身份', '沟通', '互动', '风格', 'profile', '角色是', '身份是', '被称呼', 'AI角色'],
  },
]

/** 项目概览标签，用于标记和检索概览事实 */
const OVERVIEW_TAG = 'project_overview'

export class HolographicProvider extends MemoryProvider {
  private globalStore: MemoryStore | null = null
  private projectStore: MemoryStore | null = null
  private globalRetriever: FactRetriever | null = null
  private projectRetriever: FactRetriever | null = null
  private minTrust = 0.3
  private projectRoot = ''
  private overviewNeedsUpdate = false
  /** 从项目根目录提取的项目标识，用于内容级路由判断 */
  private projectIdSignals: string[] = []

  // Tiered injection state
  private cachedBlock: string | null = null
  private lastBuildTime: string = ''
  private lastFactCount: number = -1
  private warmSummary: string = ''
  private warmRoundCounter: number = 0
  private readonly WARM_TTL = 5
  private readonly HOT_TIER_LIMIT = 5
  private readonly HOT_TIER_MIN_TRUST = 0.5

  get name(): string {
    return 'holographic'
  }

  isAvailable(): boolean {
    return true // SQLite 始终可用
  }

  initialize(ctx: ProviderContext): void {
    // 全局数据库
    const globalHome = process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), '.claude')
    const globalDbPath = join(globalHome, 'memory', 'facts.db')
    this.globalStore = new MemoryStore(globalDbPath)
    this.globalRetriever = new FactRetriever(this.globalStore, { temporalDecayHalfLife: 30 })

    // 项目数据库
    this.projectRoot = ctx.projectRoot
    const projectDbPath = join(ctx.projectRoot, '.claude', 'memory', 'facts.db')
    this.projectStore = new MemoryStore(projectDbPath)
    this.projectRetriever = new FactRetriever(this.projectStore, { temporalDecayHalfLife: 30 })

    // 提取项目标识信号（目录名、package name 等），用于内容级路由
    this.projectIdSignals = this.extractProjectIdSignals(ctx.projectRoot)

    // 信任衰减：session 启动时清理过期事实
    this.globalStore.decayTrustScores()
    this.projectStore.decayTrustScores()

    // 启动时矛盾审计：不依赖写入触发，每次启动必然扫描
    this.globalStore.auditContradictions()
    this.projectStore.auditContradictions()

    // 项目活跃续命：用户在本项目启动 = 项目正在开发
    this.projectStore.refreshProjectFacts()

    // 检测文档变更，标记概览是否需要更新
    this.overviewNeedsUpdate = this.checkDocsChanged()

    // 一次性迁移旧 category 数据
    this.migrateLegacyCategories()
  }

  /** 旧 category 数据迁移（幂等，可安全重复执行） */
  private migrateLegacyCategories(): void {
    if (!this.globalStore) return

    for (const rule of MIGRATION_RULES) {
      for (const keyword of rule.keywords) {
        this.globalStore.connection.prepare(
          `UPDATE facts SET category = ? WHERE category = ? AND content LIKE ?`
        ).run(rule.to, rule.from, `%${keyword}%`)
      }
    }

    // tool → tool_pref（无关键词条件，全量迁移）
    this.globalStore.connection.prepare(
      `UPDATE facts SET category = 'tool_pref' WHERE category = 'tool'`
    ).run()

    // 剩余未迁移的 user_pref → 归入 identity（兜底）
    this.globalStore.connection.prepare(
      `UPDATE facts SET category = 'identity' WHERE category = 'user_pref'`
    ).run()
  }

  /** 兼容旧 category 值，自动映射到新 category */
  private resolveCategory(category?: string): FactCategory {
    if (!category) return 'general'
    if (category in LEGACY_CATEGORIES) return LEGACY_CATEGORIES[category]
    return category as FactCategory
  }

  /** 判断 category 是否路由到项目库 */
  private isProjectCategory(category?: FactCategory): boolean {
    return category === 'project'
  }

  /**
   * 从项目根目录提取标识信号，用于内容级路由判断。
   * 提取：目录名、package.json/pyproject.toml 的 name 字段。
   */
  private extractProjectIdSignals(projectRoot: string): string[] {
    const signals: string[] = []
    // 目录名（如 "ocean-cc-cli"、"skill_engine"）
    const dirName = basename(projectRoot)
    if (dirName && dirName !== '.claude') signals.push(dirName.toLowerCase())

    // package.json 的 name
    try {
      const pkg = JSON.parse(
        readFileSync(join(projectRoot, 'package.json'), 'utf-8'),
      )
      if (pkg.name) {
        // 去掉 scope：@anthropic/claude-code → claude-code
        const name = pkg.name.replace(/^@[^/]+\//, '').toLowerCase()
        if (name) signals.push(name)
      }
    } catch { /* no package.json */ }

    // pyproject.toml 的 name
    try {
      const content = readFileSync(join(projectRoot, 'pyproject.toml'), 'utf-8')
      const match = content.match(/^name\s*=\s*"([^"]+)"/m)
      if (match?.[1]) signals.push(match[1].toLowerCase())
    } catch { /* no pyproject.toml */ }

    return [...new Set(signals)]
  }

  /**
   * 内容级项目检测：判断事实内容是否包含项目标识。
   * 用于防止项目知识被错误写入全局库。
   */
  private isProjectContent(content: string): boolean {
    if (this.projectIdSignals.length === 0) return false
    const lower = content.toLowerCase()
    for (const signal of this.projectIdSignals) {
      // 至少匹配一个完整信号词
      if (lower.includes(signal)) return true
    }
    // 内容包含项目特有模式
    if (/项目(?:概览|架构|结构|实现|设计|代码|模块|源码)/.test(content)) return true
    // 技术调试/测试经验：提到具体组件 + 问题模式（通常是项目级知识）
    if (/(?:截图|调试|测试|修复|经验).{0,30}(?:路由|dispatch|搜索|agent|skill|模块|组件)/i.test(content)) return true
    return false
  }

  /**
   * 路由决策（写入时调用）。
   *
   * 确定性规则，不依赖 AI 分类准确性：
   * - identity/coding_style/tool_pref/workflow → 全局库（这些语义明确，永远是用户级的）
   * - project → 项目库
   * - general → 内容包含项目标识则路由到项目库，否则全局库
   *
   * 内容检测路由到项目库时，category 强制覆盖为 project（保持存储与分类一致）。
   */
  private validateAndRoute(
    category: FactCategory,
    content: string,
  ): { store: MemoryStore; resolvedCategory: FactCategory } {
    // project → 项目库
    if (this.isProjectCategory(category) && this.projectStore) {
      return { store: this.projectStore, resolvedCategory: category }
    }
    // general/workflow/coding_style + 内容包含项目标识 → 项目库，category 纠正为 project
    if (['general', 'workflow', 'coding_style'].includes(category) && this.projectStore && this.isProjectContent(content)) {
      return { store: this.projectStore, resolvedCategory: 'project' }
    }
    // 其余全部 → 全局库
    return { store: this.globalStore!, resolvedCategory: category }
  }

  /** 按 category 路由到对应 store（不验证内容，用于 update/remove 等已知 fact_id 的操作） */
  private routeStore(category?: FactCategory): MemoryStore {
    if (this.isProjectCategory(category) && this.projectStore) return this.projectStore
    return this.globalStore!
  }

  /** 根据 fact_id 判断属于哪个库（先查全局再查项目） */
  private storeForFactId(factId: number): MemoryStore | null {
    if (this.globalStore) {
      const row = this.globalStore.connection.prepare('SELECT fact_id FROM facts WHERE fact_id = ?').get(factId)
      if (row) return this.globalStore
    }
    if (this.projectStore) {
      const row = this.projectStore.connection.prepare('SELECT fact_id FROM facts WHERE fact_id = ?').get(factId)
      if (row) return this.projectStore
    }
    return null
  }

  // ------------------------------------------------------------------
  // 项目概览：一条 project 事实，tags 含 project_overview
  // ------------------------------------------------------------------

  /** 获取项目概览事实 */
  private getProjectOverview(): string | null {
    const facts = this.projectStore?.listFacts('project', 0.0, 50) ?? []
    const overview = facts.find(f => f.tags.includes(OVERVIEW_TAG))
    return overview?.content ?? null
  }

  /** 检测项目文档是否变更（mtime 比对） */
  private checkDocsChanged(): boolean {
    const overview = this.projectStore?.listFacts('project', 0.0, 50)
      ?.find(f => f.tags.includes(OVERVIEW_TAG))
    if (!overview) {
      // 没有概览，检查项目是否有文档
      return this.scanProjectDocs().length > 0
    }

    // 有概览，检查文档 mtime 是否比概览更新
    const overviewTime = new Date(overview.updatedAt + 'Z').getTime()
    const docs = this.scanProjectDocs()
    for (const doc of docs) {
      if (doc.mtimeMs > overviewTime) return true
    }
    return false
  }

  /** 扫描项目文档目录 */
  private static readonly DOC_DIRS = ['docs', 'doc', 'documentation', 'design', 'arch']

  private scanProjectDocs(): Array<{ filePath: string; mtimeMs: number }> {
    const root = this.projectRoot
    const results: Array<{ filePath: string; mtimeMs: number }> = []

    for (const dir of HolographicProvider.DOC_DIRS) {
      const fullDir = join(root, dir)
      if (existsSync(fullDir)) {
        this.collectMdFiles(fullDir, root, results)
      }
    }

    return results
  }

  private collectMdFiles(
    dir: string,
    root: string,
    results: Array<{ filePath: string; mtimeMs: number }>,
    depth = 0,
  ): void {
    if (depth > 5) return
    const EXCLUDE = new Set(['node_modules', '.git', '.claude', 'dist', 'build', '__pycache__', 'venv'])

    let entries
    try {
      entries = readdirSync(dir, { withFileTypes: true })
    } catch { return }

    for (const entry of entries) {
      if (EXCLUDE.has(entry.name)) continue
      const fullPath = join(dir, entry.name)
      if (entry.isDirectory()) {
        this.collectMdFiles(fullPath, root, results, depth + 1)
      } else if (entry.name.endsWith('.md')) {
        try {
          const stat = statSync(fullPath)
          results.push({
            filePath: relative(root, fullPath),
            mtimeMs: stat.mtimeMs,
          })
        } catch { /* ignore */ }
      }
    }
  }

  // ------------------------------------------------------------------
  // Tiered injection helpers
  // ------------------------------------------------------------------

  private getFactDisplayText(fact: { summary: string | null; content: string }): string {
    return fact.summary ?? fact.content
  }

  private hasFactDatabaseChanged(): boolean {
    if (!this.globalStore) return true
    const maxUpdated = this.globalStore.connection.prepare(
      "SELECT MAX(updated_at) as max_time, COUNT(*) as count FROM facts"
    ).get() as { max_time: string; count: number }
    return maxUpdated.max_time !== this.lastBuildTime || maxUpdated.count !== this.lastFactCount
  }

  private generateWarmSummary(): string {
    const parts: string[] = []

    const workflowFacts = this.globalStore?.listFacts('workflow', 0.0, 10) ?? []
    if (workflowFacts.length > 0) {
      const workflowTexts = workflowFacts.map(f => this.getFactDisplayText(f))
      parts.push('工作流偏好：' + workflowTexts.join('；') + '。')
    }

    const codingFacts = this.globalStore?.listFacts('coding_style', 0.0, 20) ?? []
    if (codingFacts.length > 0) {
      const techTag = this.detectProjectTech()
      const matched = techTag
        ? codingFacts.filter(f => f.content.toLowerCase().includes(techTag) || f.tags.toLowerCase().includes(techTag))
        : codingFacts.slice(0, 3)

      if (matched.length > 0) {
        const codingTexts = matched.slice(0, 3).map(f => this.getFactDisplayText(f))
        parts.push(`编码习惯${techTag ? '（' + techTag + '）' : ''}：` + codingTexts.join('；') + '。')
      }
    }

    return parts.join('\n')
  }

  // ------------------------------------------------------------------
  // System prompt 注入
  // ------------------------------------------------------------------

  systemPromptBlock(): string {
    // 1. 缓存命中检查：数据库未变更时直接返回缓存
    if (this.cachedBlock && !this.hasFactDatabaseChanged()) {
      return this.cachedBlock
    }

    const globalCount = this.globalStore?.getTotalCount() ?? 0
    const projectCount = this.projectStore?.getTotalCount() ?? 0

    if (globalCount === 0 && projectCount === 0) {
      return '# 结构化记忆\n事实库为空。使用 fact_store 存储和检索结构化事实。'
    }

    let block = '# 结构化记忆\n'
    if (globalCount > 0) block += `全局事实库 ${globalCount} 条。`
    if (projectCount > 0) block += `项目事实库 ${projectCount} 条。`
    block += '\n\n**读取优先级**：'
    block += '\n- 用户身份/偏好/习惯 → 查 fact_store（文件里没有）'
    block += '\n- 决策背景/团队约定/隐性知识 → 查 fact_store（文件里没有）'
    block += '\n**写入**：当用户说"记住"、"记下来"、"以后记住"时，必须立即用 fact_store 保存。'
    block += '\n- 先 search 检查是否已有相似事实，有则 update，无则 add。'
    block += '\n- update 时必须保留旧事实中的所有有效信息，只修改变化的部分。'
    block += '\n  例如：用户说"改用 pnpm"，旧事实是"用 npm 管理依赖，偏好 monorepo 结构"'
    block += '\n  → update 为"用 pnpm 管理依赖，偏好 monorepo 结构"，只改包管理器，不丢其他信息。'
    block += '\n**反馈**：成功使用 fact_store 返回的事实时，调用 fact_feedback(action="helpful", fact_id=...) 正向强化该事实的信任评分。'

    // Hot tier：高信任 identity 事实（仅 top N）
    const identityFacts = this.globalStore?.listFacts('identity', this.HOT_TIER_MIN_TRUST, this.HOT_TIER_LIMIT) ?? []
    if (identityFacts.length > 0) {
      block += '\n\n## 角色与身份设定（必须遵守）\n'
      block += identityFacts.map(f => `- ${this.getFactDisplayText(f)}`).join('\n')
      block += '\n\n当用户问"你是谁"时，必须按照以上设定回答，不要自称"Ocean CLI"或其他默认身份。'
    }

    // Warm tier：工作流 + 编码习惯摘要，缓存 5 轮
    if (this.warmRoundCounter >= this.WARM_TTL || !this.warmSummary) {
      this.warmSummary = this.generateWarmSummary()
      this.warmRoundCounter = 0
    } else {
      this.warmRoundCounter++
    }
    if (this.warmSummary) {
      block += '\n\n## 工作流与编码习惯\n'
      block += this.warmSummary
    }

    // Cold tier：general / tool_pref / project（除概览外）不再自动注入
    // 这些类别通过 prefetch 按需检索

    // 项目概览（一条事实，始终注入）
    const overview = this.getProjectOverview()
    if (overview) {
      block += '\n\n## 项目概览\n'
      block += overview
    }

    // 概览需要更新或首次生成：提示 AI 扫描文档
    if (this.overviewNeedsUpdate && !overview) {
      block += '\n\n## ⚠️ 项目文档未索引'
      block += '\n检测到项目有文档目录但尚未生成项目概览。请在合适时机扫描项目文档（docs/、design/、arch/ 等），'
      block += '提取出项目整体架构、方向、职责边界，存为一条 project 事实：'
      block += '\nfact_store(action="add", content="项目概览内容", category="project", tags="project_overview")'
      block += '\n概览应包含：项目定位、整体架构、职责边界、当前阶段。不需要逐文档详细摘要，只需要全局视角。'
    } else if (this.overviewNeedsUpdate) {
      block += '\n\n> 注意：项目文档有变更，概览可能需要更新。请根据需要更新概览内容。'
    }

    // 更新缓存
    const maxUpdated = this.globalStore?.connection.prepare(
      "SELECT MAX(updated_at) as max_time, COUNT(*) as count FROM facts"
    ).get() as { max_time: string; count: number } | undefined
    if (maxUpdated) {
      this.lastBuildTime = maxUpdated.max_time
      this.lastFactCount = maxUpdated.count
    }
    this.cachedBlock = block

    return block
  }

  prefetch(query: string): string {
    if (!query) return ''
    try {
      // 跨库搜索
      const globalResults = this.globalRetriever?.search(query, { minTrust: this.minTrust, limit: 3 }) ?? []
      const projectResults = this.projectRetriever?.search(query, { minTrust: this.minTrust, limit: 3 }) ?? []
      const all = [...globalResults, ...projectResults]
      if (all.length === 0) return ''

      // 安全过滤
      const safeResults = all.filter(r => {
        const scan = scanForInjection(r.content)
        return scan.safe
      })
      if (safeResults.length === 0) return ''

      const lines = safeResults.map(r =>
        `- [${r.trustScore.toFixed(1)}] ${r.content}`
      )
      return '## 结构化记忆\n' + lines.join('\n')
    } catch {
      return ''
    }
  }

  /**
   * 检测当前项目的技术栈，返回匹配的关键词用于编码习惯过滤。
   */
  private detectProjectTech(): string | null {
    const root = this.projectRoot
    const techSignals: Array<{ file: string; tag: string }> = [
      { file: 'pyproject.toml', tag: 'python' },
      { file: 'setup.py', tag: 'python' },
      { file: 'setup.cfg', tag: 'python' },
      { file: 'requirements.txt', tag: 'python' },
      { file: 'Pipfile', tag: 'python' },
      { file: 'go.mod', tag: 'go' },
      { file: 'Cargo.toml', tag: 'rust' },
      { file: 'package.json', tag: 'typescript' },
      { file: 'pom.xml', tag: 'java' },
      { file: 'build.gradle', tag: 'java' },
    ]
    for (const { file, tag } of techSignals) {
      try {
        if (existsSync(join(root, file))) return tag
      } catch { /* ignore */ }
    }
    return null
  }

  getToolSchemas(): ToolSchema[] {
    return [FACT_STORE_SCHEMA, FACT_FEEDBACK_SCHEMA]
  }

  handleToolCall(toolName: string, args: Record<string, unknown>): string {
    if (toolName === 'fact_store') return this.handleFactStore(args as unknown as FactStoreArgs)
    if (toolName === 'fact_feedback') return this.handleFactFeedback(args as unknown as FactFeedbackArgs)
    throw new Error(`Unknown tool: ${toolName}`)
  }

  shutdown(): void {
    this.globalStore?.close()
    this.projectStore?.close()
    this.globalStore = this.projectStore = null
    this.globalRetriever = this.projectRetriever = null
  }

  // -- 工具处理 ---

  private handleFactStore(args: FactStoreArgs): string {
    try {
      const action = args.action
      // 兼容旧 category 值
      const resolvedCategory = this.resolveCategory(args.category)

      switch (action) {
        case 'add': {
          if (!args.content) return JSON.stringify({ error: "Missing required argument: content" })
          // 路由决策：category 标签不变，但 store 可能被内容检测纠正
          const { store } = this.validateAndRoute(resolvedCategory, args.content)

          // 去重：实体优先 + 编辑距离（跨 category 搜索，合并时保留旧 category）
          const similar = store.findSimilarFact(args.content, resolvedCategory)
            ?? store.findSimilarFact(args.content) // 回退：不限 category
          if (similar) {
            store.updateFact(similar.factId, {
              content: args.content,
              tags: args.tags,
              trustDelta: 0.05,
              // 合并时不覆盖 category，保留旧事实的分类
            })
            const demoted = store.demoteContradictingFacts(similar.factId, args.content, resolvedCategory)
            return JSON.stringify({
              fact_id: similar.factId,
              status: 'updated',
              reason: 'similar_fact_merged',
              ...(demoted > 0 ? { contradicted_demoted: demoted } : {}),
            })
          }

          const factId = store.addFact(args.content, resolvedCategory, args.tags ?? '')
          const demoted = store.demoteContradictingFacts(factId, args.content, resolvedCategory)
          return JSON.stringify({
            fact_id: factId,
            status: 'added',
            category: resolvedCategory,
            ...(demoted > 0 ? { contradicted_demoted: demoted } : {}),
          })
        }

        case 'search': {
          if (!args.query) return JSON.stringify({ error: "Missing required argument: query" })
          const results: ScoredFact[] = []
          // 搜索全局库
          const globalCategory = this.isProjectCategory(resolvedCategory) ? undefined : resolvedCategory
          const globalResults = this.globalRetriever?.search(args.query, {
            category: globalCategory,
            minTrust: args.min_trust ?? this.minTrust,
            limit: args.limit ?? 10,
          }) ?? []
          results.push(...globalResults)
          // 项目库：未指定 category 或指定了 project
          if (!args.category || this.isProjectCategory(resolvedCategory)) {
            const projectResults = this.projectRetriever?.search(args.query, {
              category: undefined,
              minTrust: args.min_trust ?? this.minTrust,
              limit: args.limit ?? 10,
            }) ?? []
            results.push(...projectResults)
          }
          // 去重并截断
          const seen = new Set<string>()
          const deduped = results.filter(r => {
            if (seen.has(r.content)) return false
            seen.add(r.content)
            return true
          })
          return JSON.stringify({ results: deduped.slice(0, args.limit ?? 10), count: deduped.length })
        }

        case 'probe': {
          if (!args.entity) return JSON.stringify({ error: "Missing required argument: entity" })
          const retriever = this.isProjectCategory(resolvedCategory) ? this.projectRetriever! : this.globalRetriever!
          const results = retriever.probe(args.entity, {
            category: undefined,
            minTrust: args.min_trust ?? this.minTrust,
            limit: args.limit ?? 10,
          })
          return JSON.stringify({ results, count: results.length })
        }

        case 'related': {
          if (!args.entity) return JSON.stringify({ error: "Missing required argument: entity" })
          const retriever = this.isProjectCategory(resolvedCategory) ? this.projectRetriever! : this.globalRetriever!
          const results = retriever.related(args.entity, {
            category: undefined,
            minTrust: args.min_trust ?? this.minTrust,
            limit: args.limit ?? 10,
          })
          return JSON.stringify({ results, count: results.length })
        }

        case 'reason': {
          const entities = args.entities ?? []
          if (entities.length === 0) return JSON.stringify({ error: "reason requires 'entities' list" })
          const retriever = this.isProjectCategory(resolvedCategory) ? this.projectRetriever! : this.globalRetriever!
          const results = retriever.reason(entities, {
            category: undefined,
            minTrust: args.min_trust ?? this.minTrust,
            limit: args.limit ?? 10,
          })
          return JSON.stringify({ results, count: results.length })
        }

        case 'contradict': {
          const retriever = this.isProjectCategory(resolvedCategory) ? this.projectRetriever! : this.globalRetriever!
          const results = retriever.contradict({
            category: undefined,
            threshold: 0.3,
            limit: args.limit ?? 10,
          })
          return JSON.stringify({ results, count: results.length })
        }

        case 'update': {
          if (!args.fact_id) return JSON.stringify({ error: "Missing required argument: fact_id" })
          const store = this.storeForFactId(args.fact_id)
          if (!store) return JSON.stringify({ error: `fact_id ${args.fact_id} not found` })
          const updated = store.updateFact(args.fact_id, {
            content: args.content,
            tags: args.tags,
            category: resolvedCategory,
            trustDelta: args.trust_delta,
          })
          return JSON.stringify({ updated })
        }

        case 'remove': {
          if (!args.fact_id) return JSON.stringify({ error: "Missing required argument: fact_id" })
          const store = this.storeForFactId(args.fact_id)
          if (!store) return JSON.stringify({ error: `fact_id ${args.fact_id} not found` })
          const removed = store.removeFact(args.fact_id)
          return JSON.stringify({ removed })
        }

        case 'list': {
          const store = this.routeStore(resolvedCategory)
          const facts = store.listFacts(resolvedCategory, args.min_trust ?? 0.0, args.limit ?? 10)
          return JSON.stringify({ facts, count: facts.length })
        }

        default:
          return JSON.stringify({ error: `Unknown action: ${action}` })
      }
    } catch (err) {
      return JSON.stringify({ error: String(err) })
    }
  }

  private handleFactFeedback(args: FactFeedbackArgs): string {
    try {
      if (!args.fact_id) return JSON.stringify({ error: "Missing required argument: fact_id" })
      const store = this.storeForFactId(args.fact_id)
      if (!store) return JSON.stringify({ error: `fact_id ${args.fact_id} not found` })
      const result = store.recordFeedback(args.fact_id, args.action === 'helpful')
      return JSON.stringify(result)
    } catch (err) {
      return JSON.stringify({ error: String(err) })
    }
  }
}
