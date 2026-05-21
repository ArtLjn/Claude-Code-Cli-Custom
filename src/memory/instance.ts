/**
 * MemoryManager 全局单例。
 * 负责初始化和生命周期管理。
 */

import { MemoryManager } from './MemoryManager'
import { HolographicProvider } from './providers/HolographicProvider'
import type { ProviderContext } from './types'

let _instance: MemoryManager | null = null
let _checked = false

/** 检查 memory 系统是否被禁用 */
function isMemoryDisabled(): boolean {
  // 尝试读取设置
  try {
    // 使用懒加载避免循环依赖
    const getSettings = () => {
      try {
        return require('../utils/settings/settings.js') as typeof import('../utils/settings/settings.js')
      } catch {
        return null
      }
    }
    const settingsModule = getSettings()
    if (settingsModule) {
      const settings = settingsModule.getInitialSettings()
      // 默认启用，仅当显式设置为 false 时禁用
      return settings?.holographicMemoryEnabled === false
    }
  } catch {
    // 读取失败时默认启用
  }
  return false
}

/** 获取全局 MemoryManager 实例（懒初始化） */
export function getMemoryManager(ctx?: ProviderContext): MemoryManager | null {
  if (_instance) return _instance

  if (!ctx) return null

  // 仅检查一次，避免重复读取配置
  if (!_checked) {
    _checked = true
    if (isMemoryDisabled()) {
      console.log('[Memory] holographic memory 已通过设置禁用')
      return null
    }
  }

  try {
    _instance = new MemoryManager()

    const holographic = new HolographicProvider()
    if (holographic.isAvailable()) {
      _instance.addProvider(holographic)
    }

    _instance.initializeAll(ctx)
    return _instance
  } catch (err) {
    console.warn('[Memory] 初始化失败:', err)
    _instance = null
    return null
  }
}

/** 关闭全局 MemoryManager */
export function shutdownMemoryManager(): void {
  if (_instance) {
    _instance.shutdownAll()
    _instance = null
  }
}
