import { defineConfig } from '@playwright/test'

export default defineConfig({
  testDir: './tests',
  outputDir: process.env.PW_OUTPUT || '../target/ui-mock-results',
  reporter: [['list'], ['html', { outputFolder: process.env.PW_REPORT || '../target/ui-mock-report', open: 'never' }]],
  use: { baseURL: process.env.CANGSHU_BASE_URL || 'http://127.0.0.1:4173', browserName: 'chromium', launchOptions: process.env.CHROME_PATH || process.platform === 'win32' ? { executablePath: process.env.CHROME_PATH || 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe' } : {} },
  projects: [{ name: 'mock', testMatch: /mock\.spec\.ts/ }, { name: 'real', testMatch: /real\.spec\.ts/ }],
})
