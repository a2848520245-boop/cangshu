export interface Resource {
  id: string; name: string; sizeBytes: number; mimeType: string
  hash: { algorithm: string; digest: string }; tags: string[]; status: string
  createdAt: string; contentId?: string; deletedAt?: string; expireAt?: string
}
export interface Page { items: Resource[]; total: number; page: number; size: number }
export interface Upload extends Resource { deduplicated: boolean; contentId: string }
export interface ApiError extends Error { code?: string }

export async function api<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(path, init)
  if (!response.ok) {
    let body: { code?: string; message?: string } = {}
    try { body = await response.json() } catch { /* non-JSON HTTP failure */ }
    const error = new Error(body.message || `请求失败（HTTP ${response.status}）`) as ApiError
    error.code = body.code
    throw error
  }
  if (response.status === 204) return undefined as T
  return response.json() as Promise<T>
}

export const contentUrl = (id: string, inline = false) =>
  `/api/resources/${encodeURIComponent(id)}/content${inline ? '?inline=1' : ''}`

// No HTML or SVG may be opened as active same-origin content.
export const canPreview = (mime: string) => /^(image\/(png|jpeg|gif|webp)|application\/pdf|text\/plain)(;|$)/i.test(mime)

export const errorText = (error: unknown) => error instanceof Error ? error.message : '操作失败，请重试'
