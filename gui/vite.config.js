import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { apiMiddleware } from './server/api.js'

// The API runs PowerShell on this machine, so it is only ever bound to localhost.
const PORT = 5178

const api = {
  name: 'debloat-api',
  configureServer(server) { server.middlewares.use(apiMiddleware(PORT)) },
  configurePreviewServer(server) { server.middlewares.use(apiMiddleware(PORT)) },
}

export default defineConfig({
  plugins: [react(), api],
  server: { host: '127.0.0.1', port: PORT, strictPort: true },
  preview: { host: '127.0.0.1', port: PORT, strictPort: true },
})
