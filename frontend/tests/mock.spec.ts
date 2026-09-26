import { expect, test, type Page, type Route } from '@playwright/test'

const id1 = '018f92aa-0000-7000-8000-000000000001'
const id2 = '018f92aa-0000-7000-8000-000000000002'
function resource(id: string, name = '测试.txt') {
  return { id, name, sizeBytes: 5, mimeType: 'text/plain', hash: { algorithm: 'sha256', digest: 'a'.repeat(64) }, tags: ['重要'], status: 'READY', createdAt: '2026-09-25T00:00:00Z', contentId: id }
}
function json(route: Route, value: unknown, status = 200) { return route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(value) }) }
async function mock(page: Page) {
  const live = [resource(id1)]
  const trash: ReturnType<typeof resource>[] = []
  const calls: string[] = []
  await page.context().route('**/api/resources**', async route => {
    const request = route.request(); const url = new URL(request.url()); const path = url.pathname; const method = request.method()
    calls.push(`${method} ${path}${url.search}`)
    if (path === '/api/resources' && method === 'GET') {
      const name = url.searchParams.get('name') || ''; const tag = url.searchParams.get('tag') || ''
      const filtered = live.filter(item => item.name.includes(name) && item.tags.includes(tag || '重要'))
      const pageNumber = Number(url.searchParams.get('page') || 1)
      return json(route, { items: filtered.slice((pageNumber - 1) * 20, pageNumber * 20), total: filtered.length, page: pageNumber, size: 20 })
    }
    if (path === '/api/resources' && method === 'POST') {
      const added = resource(id2, '再传.txt'); live.unshift(added)
      return json(route, { ...added, deduplicated: true }, 201)
    }
    if (path === '/api/resources/trash' && method === 'GET') return json(route, { items: trash, total: trash.length, page: 1, size: 20 })
    if (path === '/api/resources/trash' && method === 'DELETE') {
      if (url.searchParams.get('confirm') !== 'true') return json(route, { code: 'INVALID_ARGUMENT', message: '缺少确认' }, 400)
      const deletedCount = trash.length; trash.length = 0; return json(route, { deletedCount })
    }
    const match = path.match(/^\/api\/resources\/([^/]+)(?:\/(restore|content))?$/)
    if (!match) return json(route, { code: 'RESOURCE_NOT_FOUND', message: '不存在' }, 404)
    const [, id, action] = match
    if (action === 'content' && method === 'HEAD') return route.fulfill({ status: 200, headers: { 'content-length': '5' } })
    if (action === 'content') return route.fulfill({ status: 200, body: 'hello', headers: { 'content-disposition': 'attachment; filename="test.txt"' } })
    if (action === 'restore' && method === 'POST') { const index = trash.findIndex(item => item.id === id); const item = trash.splice(index, 1)[0]; if (!item) return json(route, {}, 404); live.unshift(item); return json(route, item) }
    if (method === 'DELETE') { const index = live.findIndex(item => item.id === id); const item = live.splice(index, 1)[0]; if (!item) return json(route, {}, 404); trash.unshift({ ...item, deletedAt: '2026-09-25T00:00:00Z', expireAt: '2026-10-02T00:00:00Z' }); return route.fulfill({ status: 204 }) }
    if (method === 'GET') return json(route, live.find(item => item.id === id) || {}, 200)
    return json(route, {}, 404)
  })
  return { calls }
}

test('mock: upload, deduplication, search, details, download and trash lifecycle', async ({ page }) => {
  const { calls } = await mock(page)
  await page.goto('/')
  await expect(page.getByText('测试.txt')).toBeVisible()
  await page.getByLabel('选择文件').setInputFiles({ name: '再传.txt', mimeType: 'text/plain', buffer: Buffer.from('hello') })
  await page.getByRole('button', { name: '上传', exact: true }).dblclick()
  await expect(page.getByText('上传成功，已复用存储。')).toBeVisible()
  expect(calls.filter(call => call === 'POST /api/resources')).toHaveLength(1)
  await page.getByLabel('名称').fill('再传')
  await page.getByRole('button', { name: '搜索' }).click()
  await expect(page.getByText('再传.txt')).toBeVisible()
  await expect(page.getByText('测试.txt')).toHaveCount(0)
  await page.getByRole('button', { name: '详情' }).click()
  await expect(page.getByText('内容关联')).toBeVisible()
  await page.getByRole('button', { name: '基础预览' }).click()
  await expect(page.getByTitle('文件预览')).toBeVisible()
  await page.getByRole('button', { name: '搜索' }).click()
  await expect(page.getByTitle('文件预览')).toHaveCount(0)
  await page.getByRole('button', { name: '详情' }).click()
  await page.getByRole('button', { name: '基础预览' }).click()
  await expect(page.getByTitle('文件预览')).toBeVisible()
  const download = page.waitForEvent('download')
  await page.getByRole('button', { name: '下载' }).first().click()
  const downloaded = await download
  expect(await downloaded.failure()).toBeNull()
  expect(calls.some(call => call === `HEAD /api/resources/${id2}/content`)).toBeTruthy()
  await page.getByRole('button', { name: '移入回收站' }).click()
  await expect(page.getByTitle('文件预览')).toHaveCount(0)
  await page.getByRole('button', { name: '回收站', exact: true }).click()
  await expect(page.getByText('再传.txt')).toBeVisible()
  await page.getByRole('button', { name: '还原' }).click()
  await expect(page.getByText('已还原，可在资源列表查看。')).toBeVisible()
  await expect(page.getByRole('button', { name: '资源列表' })).toHaveAttribute('aria-current', 'page')
  await expect(page.getByText('再传.txt')).toBeVisible()
  await page.getByRole('button', { name: '移入回收站' }).first().click()
  await page.getByRole('button', { name: '回收站', exact: true }).click()
  await page.getByRole('button', { name: '清空回收站' }).click()
  await page.getByRole('button', { name: '取消' }).click()
  expect(calls.filter(call => call.startsWith('DELETE /api/resources/trash'))).toHaveLength(0)
  await page.getByRole('button', { name: '清空回收站' }).click()
  await page.getByRole('button', { name: '确认清空' }).dblclick()
  await expect(page.getByText('回收站是空的。')).toBeVisible()
  expect(calls.filter(call => call === 'DELETE /api/resources/trash?confirm=true')).toHaveLength(1)
  await page.screenshot({ path: process.env.PW_SCREENSHOT || '../target/ui-mock-screen.png', fullPage: true })
})

test('mock: initial list failure has retry without an empty-state claim', async ({ page }) => {
  let listCalls = 0
  await page.route('**/api/resources**', route => {
    listCalls += 1
    if (listCalls === 1) return json(route, { code: 'SERVICE_BUSY', message: '稍后重试' }, 503)
    return json(route, { items: [], total: 0, page: 1, size: 20 })
  })
  await page.goto('/')
  await expect(page.getByRole('alert')).toContainText('列表加载失败：稍后重试')
  await expect(page.getByRole('button', { name: '重试加载' })).toBeVisible()
  await expect(page.getByText('暂无资源。可上传文件或更换搜索条件。')).toHaveCount(0)
  await page.getByRole('button', { name: '重试加载' }).click()
  await expect(page.getByText('暂无资源。可上传文件或更换搜索条件。')).toBeVisible()
  expect(listCalls).toBe(2)
})

test('mock: detail failure is visible and failed restore stays in trash', async ({ page }) => {
  const item = resource(id1)
  await page.route('**/api/resources**', route => {
    const url = new URL(route.request().url())
    const method = route.request().method()
    if (url.pathname === '/api/resources') return json(route, { items: [item], total: 1, page: 1, size: 20 })
    if (url.pathname === '/api/resources/trash') return json(route, { items: [item], total: 1, page: 1, size: 20 })
    if (url.pathname.endsWith('/restore') && method === 'POST') return json(route, { code: 'SERVICE_BUSY', message: '还原稍后重试' }, 503)
    return json(route, { code: 'RESOURCE_NOT_FOUND', message: '详情不存在' }, 404)
  })
  await page.goto('/')
  await page.getByRole('button', { name: '详情' }).click()
  await expect(page.getByRole('alert')).toContainText('详情加载失败：详情不存在')
  await page.getByRole('button', { name: '回收站', exact: true }).click()
  await page.getByRole('button', { name: '还原' }).click()
  await expect(page.getByRole('alert')).toContainText('还原稍后重试')
  await expect(page.getByRole('button', { name: '回收站', exact: true })).toHaveAttribute('aria-current', 'page')
  await expect(page.getByText('测试.txt')).toBeVisible()
})

test('mock: failures, malicious filename text and stale list response', async ({ page }) => {
  let release: (() => void) | undefined
  await page.route('**/api/resources**', async route => {
    const url = new URL(route.request().url())
    if (route.request().method() === 'POST') return json(route, { code: 'SERVICE_BUSY', message: '请稍后重试' }, 503)
    if (url.pathname.endsWith('/content') && route.request().method() === 'HEAD') return json(route, { code: 'RESOURCE_NOT_FOUND', message: '资源不存在' }, 404)
    if (url.pathname === '/api/resources' && url.searchParams.get('name') === '旧') {
      await new Promise<void>(resolve => { release = resolve })
      return json(route, { items: [resource(id1, '旧.txt')], total: 1, page: 1, size: 20 })
    }
    if (url.pathname === '/api/resources') {
      const name = url.searchParams.get('name')
      return json(route, { items: [resource(id1, name === '新' ? '<img src=x onerror=alert(1)>.txt' : '测试.txt')], total: 1, page: 1, size: 20 })
    }
    if (url.pathname.endsWith('/content')) return route.fulfill({ status: 200, body: 'hello' })
    return json(route, resource(id1, '<img src=x onerror=alert(1)>.txt'))
  })
  await page.goto('/')
  await page.getByLabel('选择文件').setInputFiles({ name: 'x.txt', mimeType: 'text/plain', buffer: Buffer.from('x') })
  await page.getByRole('button', { name: '上传', exact: true }).click()
  await expect(page.getByRole('alert')).toContainText('请稍后重试')
  await page.getByLabel('名称').fill('旧'); await page.getByRole('button', { name: '搜索' }).click()
  await expect.poll(() => Boolean(release)).toBe(true)
  await page.getByLabel('名称').fill('新'); await page.getByRole('button', { name: '搜索' }).click()
  await expect(page.getByText('<img src=x onerror=alert(1)>.txt')).toBeVisible()
  expect(await page.locator('img').count()).toBe(0)
  release?.()
  await expect(page.getByText('旧.txt')).toHaveCount(0)
  await page.getByRole('button', { name: '下载' }).click()
  await expect(page.getByRole('alert')).toContainText('下载失败')
})

test('mock: search keeps filters while paging and a failed clear reports failure', async ({ page }) => {
  const calls: string[] = []
  await page.route('**/api/resources**', async route => {
    const url = new URL(route.request().url())
    calls.push(`${route.request().method()} ${url.pathname}${url.search}`)
    if (url.pathname === '/api/resources/trash' && route.request().method() === 'DELETE') return json(route, { code: 'SERVICE_BUSY', message: '清空暂不可用' }, 503)
    if (url.pathname === '/api/resources/trash') return json(route, { items: [resource(id1)], total: 1, page: 1, size: 20 })
    const pageNumber = Number(url.searchParams.get('page'))
    return json(route, { items: [resource(pageNumber === 2 ? id2 : id1, pageNumber === 2 ? '第二页.txt' : '第一页.txt')], total: 21, page: pageNumber, size: 20 })
  })
  await page.goto('/')
  await page.getByLabel('名称').fill('报告')
  await page.getByLabel('标签').fill('重要')
  await page.getByRole('button', { name: '搜索' }).click()
  await page.getByRole('button', { name: '下一页' }).click()
  await expect(page.getByText('第二页.txt')).toBeVisible()
  expect(calls.some(call => call.includes('name=%E6%8A%A5%E5%91%8A') && call.includes('tag=%E9%87%8D%E8%A6%81') && call.includes('page=2'))).toBeTruthy()
  await page.getByRole('button', { name: '回收站', exact: true }).click()
  await page.getByRole('button', { name: '清空回收站' }).click()
  await page.getByRole('button', { name: '确认清空' }).click()
  await expect(page.getByRole('alert')).toContainText('清空暂不可用')
  await expect(page.getByRole('dialog')).toBeVisible()
  await expect(page.getByText('已清空回收站')).toHaveCount(0)
})
