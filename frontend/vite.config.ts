import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

export default defineConfig({
  plugins: [vue(), ...(process.env.CANGSHU_MOCK_TEST === '1' ? [{
    name: 'mock-download-for-browser-test',
    configureServer(server: import('vite').ViteDevServer) {
      server.middlewares.use((req, res, next) => {
        if (req.method !== 'GET' || !/^\/api\/resources\/[^/]+\/content(?:\?|$)/.test(req.url || '')) return next()
        res.statusCode = 200
        res.setHeader('Content-Type', 'text/plain')
        res.setHeader('Content-Disposition', 'attachment; filename="test.txt"')
        res.end('hello')
      })
    },
  }] : [])],
  base: '/',
  server: { proxy: { '/api': 'http://127.0.0.1:8080' } },
  build: { outDir: 'dist', emptyOutDir: true },
})
