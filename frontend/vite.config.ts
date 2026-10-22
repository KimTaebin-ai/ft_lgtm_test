import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// 개발 모드: /api 를 VM 의 Ingress 로 프록시한다. VM IP 는 LGTM_VM_URL 로 바꾼다.
// Ingress 가 Host 헤더로 라우팅하므로 lgtm.local 을 고정으로 보낸다.
const vm = process.env.LGTM_VM_URL ?? 'http://192.168.64.8'

export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      '/api': { target: vm, headers: { Host: 'lgtm.local' } },
    },
  },
})
