import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { dirname } from 'node:path'

const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm'
const frontend = dirname(fileURLToPath(import.meta.url))
for (const args of [
  ['ci', '--registry=https://registry.npmjs.org', '--cache=../target/npm-cache', '--no-audit', '--no-fund'],
  ['run', 'build'],
]) {
  const result = spawnSync(npm, args, { cwd: frontend, stdio: 'inherit', shell: process.platform === 'win32' })
  if (result.error) throw result.error
  if (result.status !== 0) process.exit(result.status ?? 1)
}
