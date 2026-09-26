import { after, test } from 'node:test'
import assert from 'node:assert/strict'
import { api, canPreview } from '../src/api.ts'

const originalFetch = globalThis.fetch
after(() => { globalThis.fetch = originalFetch })

test('non-JSON server failure remains visible', async () => {
  globalThis.fetch = async () => new Response('<html>gateway failure</html>', { status: 502, headers: { 'Content-Type': 'text/html' } })
  await assert.rejects(api('/api/resources'), /HTTP 502/)
})

test('204 delete has no JSON body to parse', async () => {
  globalThis.fetch = async () => new Response(null, { status: 204 })
  assert.equal(await api('/api/resources/id', { method: 'DELETE' }), undefined)
})

test('active same-origin formats cannot enter preview', () => {
  for (const mime of ['text/html', 'image/svg+xml', 'application/xhtml+xml', 'application/javascript']) {
    assert.equal(canPreview(mime), false, mime)
  }
  assert.equal(canPreview('image/png'), true)
  assert.equal(canPreview('application/pdf'), true)
})
