const SUMMARY_THRESHOLD = 100
const MAX_SUMMARY_RATIO = 0.5
const MAX_SUMMARY_LENGTH = 120

export function generateSummary(content: string): string | null {
  const trimmed = content.trim()
  if (trimmed.length <= SUMMARY_THRESHOLD) return null

  let summary = extractKeySentences(trimmed)
  const maxLen = Math.min(Math.floor(trimmed.length * MAX_SUMMARY_RATIO), MAX_SUMMARY_LENGTH)

  if (summary.length > maxLen) {
    summary = summary.slice(0, maxLen)
    const lastPeriod = Math.max(summary.lastIndexOf('。'), summary.lastIndexOf('. '))
    if (lastPeriod > maxLen * 0.6) {
      summary = summary.slice(0, lastPeriod + 1)
    }
  }

  return summary.trim()
}

function extractKeySentences(text: string): string {
  const sentences = text.split(/(?<=[。！？])\s*|\.\s+/).filter(s => s.trim().length > 5)
  if (sentences.length >= 2) {
    return sentences.slice(0, 2).join('。') + '。'
  }
  return text.slice(0, Math.floor(text.length * 0.6))
}
