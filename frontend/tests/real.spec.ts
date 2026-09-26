import { expect, test } from '@playwright/test'
import { createHash } from 'node:crypto'
import { readFile } from 'node:fs/promises'

test.beforeAll(() => {
  if (process.env.GITHUB_ACTIONS !== 'true' || process.env.CANGSHU_BASE_URL !== 'http://127.0.0.1:18081') {
    throw new Error('Real UI test is restricted to the isolated GitHub Actions loopback runner')
  }
})

test('real JAR + PostgreSQL browser lifecycle and streamed download digest', async ({ page }) => {
  const filename = `ci-${process.env.GITHUB_RUN_ID}-${Date.now()}.txt`
  const bytes = Buffer.from(`CangShu isolated UI test ${filename}\n`, 'utf8')
  const digest = createHash('sha256').update(bytes).digest('hex')
  const clearRequests: string[] = []
  page.on('request', request => {
    if (request.method() === 'DELETE' && request.url().includes('/api/resources/trash')) clearRequests.push(request.url())
  })
  await page.goto('/')
  await expect(page.getByRole('heading', { name: '仓鼠' })).toBeVisible()
  for (const repeat of [1, 2]) {
    await page.getByLabel('选择文件').setInputFiles({ name: filename, mimeType: 'text/plain', buffer: bytes })
    await page.getByRole('button', { name: '上传', exact: true }).click()
    await expect(page.getByRole('status').filter({ hasText: repeat === 1 ? '上传成功。' : '已复用存储' })).toBeVisible()
  }
  await page.getByLabel('名称').fill(filename)
  await page.getByRole('button', { name: '搜索' }).click()
  await expect(page.locator('.items li')).toHaveCount(2)
  await page.locator('.items li').first().getByRole('button', { name: '详情' }).click()
  await expect(page.getByRole('region', { name: '资源详情' })).toContainText(digest)
  const downloadPromise = page.waitForEvent('download')
  await page.locator('.items li').first().getByRole('button', { name: '下载' }).click()
  const download = await downloadPromise
  const downloaded = await readFile(await download.path())
  expect(createHash('sha256').update(downloaded).digest('hex')).toBe(digest)

  // Reload verifies that the two resources are visible through the persisted backend.
  await page.reload()
  await page.getByLabel('名称').fill(filename)
  await page.getByRole('button', { name: '搜索' }).click()
  await expect(page.locator('.items li')).toHaveCount(2)
  await page.locator('.items li').first().getByRole('button', { name: '移入回收站' }).click()
  await expect(page.locator('.items li')).toHaveCount(1)
  await page.getByRole('button', { name: '回收站', exact: true }).click()
  await expect(page.locator('.items li')).toHaveCount(1)
  await page.getByRole('button', { name: '清空回收站' }).click()
  await page.getByRole('button', { name: '取消' }).click()
  expect(clearRequests).toHaveLength(0)
  await page.getByRole('button', { name: '还原' }).click()
  await expect(page.getByRole('button', { name: '资源列表' })).toHaveAttribute('aria-current', 'page')
  await expect(page.locator('.items li')).toHaveCount(2)
  await page.locator('.items li').first().getByRole('button', { name: '移入回收站' }).click()
  await page.getByRole('button', { name: '回收站', exact: true }).click()
  await page.getByRole('button', { name: '清空回收站' }).click()
  await page.getByRole('button', { name: '确认清空' }).click()
  await expect(page.getByText('回收站是空的。')).toBeVisible()
  expect(clearRequests).toHaveLength(1)
  expect(new URL(clearRequests[0]).searchParams.get('confirm')).toBe('true')
  await page.screenshot({ path: process.env.PW_SCREENSHOT || '../target/ui-real-screen.png', fullPage: true })
})
