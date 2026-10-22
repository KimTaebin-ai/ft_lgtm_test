import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { App } from './App'

// Monaco 는 jsdom 에서 동작하지 않는다
vi.mock('./Editor', () => ({ Editor: () => <div data-testid="editor" /> }))

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('App', () => {
  it('Run 근처에 IPFS 공개 안내가 있다', () => {
    render(<App />)
    expect(screen.getByText('실행한 코드와 결과는 IPFS에 영구 공개됩니다')).toBeInTheDocument()
  })

  it('Run → 결과 표시', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => new Response(JSON.stringify({ status: 'timeout' }), { status: 200 })),
    )
    render(<App />)
    await userEvent.click(screen.getByRole('button', { name: 'Run' }))
    expect(await screen.findByText('Time limit exceeded (5s)')).toBeInTheDocument()
  })

  it('Run → 429 안내', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response('{}', { status: 429 })))
    render(<App />)
    await userEvent.click(screen.getByRole('button', { name: 'Run' }))
    expect(await screen.findByText('서버가 바쁩니다')).toBeInTheDocument()
  })
})
