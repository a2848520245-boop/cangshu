import { spawn } from 'node:child_process'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const frontend = dirname(dirname(fileURLToPath(import.meta.url)))
const server = spawn(process.execPath, [join(frontend, 'node_modules/vite/bin/vite.js'), '--host', '127.0.0.1', '--port', '4173', '--strictPort'], {
  cwd: frontend, env: { ...process.env, CANGSHU_MOCK_TEST: '1' }, stdio: 'inherit',
})
let runner
try {
  let ready = false
  for (let attempt = 0; attempt < 60; attempt++) {
    if (server.exitCode !== null) throw new Error(`Vite exited with ${server.exitCode}`)
    try { const response = await fetch('http://127.0.0.1:4173/'); if (response.ok) { ready = true; break } } catch { /* booting */ }
    await new Promise(resolve => setTimeout(resolve, 250))
  }
  if (!ready) throw new Error('Vite did not become ready')
  runner = spawn(process.execPath, [join(frontend, 'node_modules/@playwright/test/cli.js'), 'test', '--project=mock'], { cwd: frontend, stdio: 'inherit', env: process.env })
  const code = await new Promise((resolve, reject) => { runner.once('error', reject); runner.once('exit', resolve) })
  process.exitCode = code ?? 1
} finally {
  if (runner && runner.exitCode === null) runner.kill()
  if (server.exitCode === null) server.kill()
}
