import { spawn } from 'node:child_process'
import { openSync, closeSync } from 'node:fs'
import { mkdir, writeFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { watchChild, stopChild } from './ci-child-process.mjs'

const repo = resolve(fileURLToPath(new URL('..', import.meta.url)))
const expectedUrl = 'jdbc:postgresql://127.0.0.1:15439/cangshu_ui_ci?currentSchema=cangshu_m1'
const approvedRepository = new Set([
  'a2848520245-boop/cangshu',
  'a2848520245-boop/cangshu-private-backup',
])
if (process.platform !== 'linux' || process.env.GITHUB_ACTIONS !== 'true' ||
    process.env.GITHUB_EVENT_NAME !== 'workflow_dispatch' ||
    process.env.CANGSHU_CI_REAL_E2E !== 'run-real-e2e' ||
    !approvedRepository.has(process.env.GITHUB_REPOSITORY) ||
    process.env.CI_PG_PORT !== '15439' || process.env.CANGSHU_DB_URL !== expectedUrl) {
  throw new Error('Real UI runner requires explicit manual CI and the isolated loopback UI database')
}
const runId = `${process.env.GITHUB_RUN_ID || 'unknown'}-${process.env.GITHUB_RUN_ATTEMPT || '1'}`
const output = resolve(repo, `target/ci-real-ui-${runId}`)
await mkdir(resolve(output, 'blobs'), { recursive: true })
const stdout = openSync(resolve(output, 'server.log'), 'w')
const stderr = openSync(resolve(output, 'server.err.log'), 'w')
const jar = resolve(repo, 'target/cangshu-0.1.0-SNAPSHOT.jar')
const server = spawn('java', ['-jar', jar, '--server.port=18081', '--spring.main.banner-mode=off'], {
  cwd: repo,
  env: { ...process.env, CANGSHU_DATA_ROOT: resolve(output, 'blobs'), CANGSHU_MIGRATION_DIR: resolve(repo, 'db/migration') },
  stdio: ['ignore', stdout, stderr],
})
const serverState = watchChild(server)
if (!server.pid) {
  await serverState.wait
  closeSync(stdout); closeSync(stderr)
  throw serverState.error || new Error('JAR process did not start')
}
let browserState
try {
  await writeFile(resolve(output, 'server.pid'), `${server.pid}\n`)
  let healthy = false
  const healthDeadline = Date.now() + 60_000
  while (Date.now() < healthDeadline) {
    if (serverState.error) throw serverState.error
    if (serverState.exited || serverState.settled) {
      throw serverState.error || new Error(`JAR exited before health check: code=${serverState.code} signal=${serverState.signal}`)
    }
    try {
      const remaining = healthDeadline - Date.now()
      const response = await fetch('http://127.0.0.1:18081/actuator/health', {
        signal: AbortSignal.timeout(Math.max(1, Math.min(1000, remaining))),
      })
      if (response.ok && (await response.json()).status === 'UP') { healthy = true; break }
    } catch { /* booting */ }
    const remaining = healthDeadline - Date.now()
    if (remaining > 0) await new Promise(resolve => setTimeout(resolve, Math.min(500, remaining)))
  }
  if (!healthy) throw new Error('JAR health check did not reach UP within 60 seconds')
  const frontend = resolve(repo, 'frontend')
  const browser = spawn(process.execPath, [resolve(frontend, 'node_modules/@playwright/test/cli.js'), 'test', '--project=real'], {
    cwd: frontend, stdio: 'inherit',
    env: { ...process.env, CANGSHU_BASE_URL: 'http://127.0.0.1:18081', PW_OUTPUT: resolve(output, 'results'), PW_REPORT: resolve(output, 'report'), PW_SCREENSHOT: resolve(output, 'screenshot.png') },
  })
  browserState = watchChild(browser)
  await Promise.race([
    browserState.wait,
    browserState.failure.then(error => { throw error }),
  ])
  if (browserState.error) throw browserState.error
  process.exitCode = browserState.code ?? 1
} catch (error) {
  process.exitCode = 1
  console.error(error)
} finally {
  for (const state of [browserState, serverState]) {
    if (!state) continue
    try {
      await stopChild(state)
    } catch (error) {
      console.error(error)
      process.exitCode = 1
    }
  }
  closeSync(stdout); closeSync(stderr)
  if (!serverState.settled) { console.error('JAR process did not stop'); process.exitCode = 1 }
}
