import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { ExecuteOutcome, ExecuteResponse } from './api'
import { ResultView } from './ResultView'

const CID = 'bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi'
const TRACE = '4bf92f3577b34da6a3ce929d0e0e4736'

function ok(over: Partial<ExecuteResponse>): ExecuteOutcome {
  return {
    kind: 'ok',
    data: {
      status: 'success',
      stdout: '',
      stderr: '',
      truncated: false,
      cid: CID,
      ipfs_url: `http://ipfs.lgtm.local/ipfs/${CID}`,
      trace_id: TRACE,
      timings_ms: { compile: 23, execute: 5, ipfs_upload: 142 },
      ...over,
    },
  }
}

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('status 별 표시', () => {
  it('success: stdout 과 stderr 를 구분한다', () => {
    render(<ResultView outcome={ok({ stdout: 'Hello, world!\n', stderr: 'warn: x' })} />)
    expect(within(screen.getByTestId('stdout')).getByText(/Hello, world!/)).toBeInTheDocument()
    expect(within(screen.getByTestId('stderr')).getByText(/warn: x/)).toBeInTheDocument()
    expect(screen.queryByText('Output truncated (10kB)')).not.toBeInTheDocument()
  })

  it('success + truncated: 배지를 표시한다', () => {
    render(<ResultView outcome={ok({ stdout: 'abc', truncated: true })} />)
    expect(screen.getByText('Output truncated (10kB)')).toBeInTheDocument()
  })

  it('compile_error: rustc 메시지를 monospace 로 표시한다', () => {
    const msg = 'error: expected expression, found `;`\n --> main.rs:2:13'
    render(<ResultView outcome={ok({ status: 'compile_error', stderr: msg, stdout: undefined })} />)
    const pre = screen.getByTestId('compile-error')
    expect(pre.tagName).toBe('PRE')
    expect(pre.textContent).toBe(msg)
  })

  it('runtime_error: stderr 와 message 를 표시한다', () => {
    render(<ResultView outcome={ok({ status: 'runtime_error', stderr: 'panicked at main.rs:3', message: 'exit code 101' })} />)
    expect(screen.getByText(/runtime error/i)).toBeInTheDocument()
    expect(screen.getByText(/panicked at main.rs:3/)).toBeInTheDocument()
    expect(screen.getByText(/exit code 101/)).toBeInTheDocument()
  })

  it('timeout', () => {
    render(<ResultView outcome={ok({ status: 'timeout' })} />)
    expect(screen.getByText('Time limit exceeded (5s)')).toBeInTheDocument()
  })

  it('memory_limit', () => {
    render(<ResultView outcome={ok({ status: 'memory_limit' })} />)
    expect(screen.getByText('Memory limit exceeded (10MB)')).toBeInTheDocument()
  })

  it('internal_error: 안내 문구와 message', () => {
    render(<ResultView outcome={ok({ status: 'internal_error', message: 'compiler unreachable' })} />)
    expect(screen.getByText(/서버 내부 오류, 잠시 후 다시 시도/)).toBeInTheDocument()
    expect(screen.getByText(/compiler unreachable/)).toBeInTheDocument()
  })

  it('알 수 없는 status 는 원문을 표시한다', () => {
    render(<ResultView outcome={ok({ status: 'quantum_error', message: 'm' })} />)
    expect(screen.getByText(/quantum_error/)).toBeInTheDocument()
  })
})

describe('timings', () => {
  it('compile / execute / ipfs_upload 를 표시한다', () => {
    render(<ResultView outcome={ok({})} />)
    const t = screen.getByTestId('timings')
    expect(t).toHaveTextContent('compile 23ms')
    expect(t).toHaveTextContent('execute 5ms')
    expect(t).toHaveTextContent('ipfs_upload 142ms')
  })

  it('timings_ms 가 없으면 영역을 그리지 않는다', () => {
    render(<ResultView outcome={ok({ timings_ms: undefined })} />)
    expect(screen.queryByTestId('timings')).not.toBeInTheDocument()
  })
})

describe('IPFS 링크', () => {
  it('로컬 + inbrowser.link 링크 2개, 새 탭, cid 로 직접 조립', () => {
    render(<ResultView outcome={ok({})} />)
    const local = screen.getByRole('link', { name: /ipfs\.lgtm\.local/ })
    const pub = screen.getByRole('link', { name: /inbrowser\.link/ })
    expect(local).toHaveAttribute('href', `http://ipfs.lgtm.local/ipfs/${CID}`)
    expect(pub).toHaveAttribute('href', `https://inbrowser.link/ipfs/${CID}`)
    for (const a of [local, pub]) {
      expect(a).toHaveAttribute('target', '_blank')
      expect(a.getAttribute('rel')).toContain('noopener')
    }
  })

  it('응답의 ipfs_url 은 href 에 쓰지 않는다', () => {
    render(<ResultView outcome={ok({ ipfs_url: 'http://evil.example/x' })} />)
    for (const a of screen.getAllByRole('link')) {
      expect(a.getAttribute('href')).not.toContain('evil.example')
    }
  })

  it('ipfs_url null → 공유 링크 생성 실패', () => {
    render(<ResultView outcome={ok({ ipfs_url: null, cid: '' })} />)
    expect(screen.getByText('공유 링크 생성 실패(IPFS timeout)')).toBeInTheDocument()
    expect(screen.queryByRole('link')).not.toBeInTheDocument()
  })

  it.each(['"><script>alert(1)</script>', '../etc/passwd', 'javascript:alert(1)', 'short', `${CID}/../x`])(
    'cid 검증 실패(%s) → 링크 없음',
    (bad) => {
      render(<ResultView outcome={ok({ cid: bad })} />)
      expect(screen.queryByRole('link')).not.toBeInTheDocument()
      expect(screen.getByText(/유효하지 않은 CID/)).toBeInTheDocument()
    },
  )
})

describe('텍스트 렌더링', () => {
  it('HTML 이 섞인 출력도 요소가 아니라 텍스트로 렌더링된다', () => {
    const evil = '<img src=x onerror="alert(1)"><script>alert(2)</script>'
    const { container } = render(<ResultView outcome={ok({ stdout: evil })} />)
    expect(container.querySelector('img')).toBeNull()
    expect(container.querySelector('script')).toBeNull()
    expect(screen.getByTestId('stdout').textContent).toContain(evil)
  })
})

describe('trace_id', () => {
  it('표시하고 복사 버튼이 clipboard 에 쓴다', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined)
    vi.stubGlobal('navigator', { ...navigator, clipboard: { writeText } })
    render(<ResultView outcome={ok({})} />)
    expect(screen.getByTestId('trace-id')).toHaveTextContent(TRACE)
    await userEvent.click(screen.getByRole('button', { name: /복사/ }))
    expect(writeText).toHaveBeenCalledWith(TRACE)
    expect(await screen.findByText('복사됨')).toBeInTheDocument()
  })

  it('navigator.clipboard 가 없으면(비보안 컨텍스트) 텍스트를 선택하고 안내한다', async () => {
    vi.stubGlobal('navigator', { ...navigator, clipboard: undefined })
    render(<ResultView outcome={ok({})} />)
    await userEvent.click(screen.getByRole('button', { name: /복사/ }))
    expect(await screen.findByText('선택됨 — Ctrl+C로 복사')).toBeInTheDocument()
    expect(window.getSelection()?.toString()).toBe(TRACE)
  })

  it('clipboard.writeText 가 거부돼도 fallback 한다', async () => {
    const writeText = vi.fn().mockRejectedValue(new Error('denied'))
    vi.stubGlobal('navigator', { ...navigator, clipboard: { writeText } })
    render(<ResultView outcome={ok({})} />)
    await userEvent.click(screen.getByRole('button', { name: /복사/ }))
    expect(await screen.findByText('선택됨 — Ctrl+C로 복사')).toBeInTheDocument()
    expect(window.getSelection()?.toString()).toBe(TRACE)
  })

  it('trace_id 가 없으면 영역을 그리지 않는다', () => {
    render(<ResultView outcome={ok({ trace_id: undefined })} />)
    expect(screen.queryByTestId('trace-id')).not.toBeInTheDocument()
  })
})

describe('요청 실패', () => {
  it('413', () => {
    render(<ResultView outcome={{ kind: 'too_large' }} />)
    expect(screen.getByText('코드가 너무 깁니다 (64KB)')).toBeInTheDocument()
  })
  it('429', () => {
    render(<ResultView outcome={{ kind: 'busy' }} />)
    expect(screen.getByText('서버가 바쁩니다')).toBeInTheDocument()
  })
  it('기타 HTTP 오류는 상태 코드를 표시한다', () => {
    render(<ResultView outcome={{ kind: 'http_error', status: 502 }} />)
    expect(screen.getByText(/서버 오류 \(HTTP 502\)/)).toBeInTheDocument()
  })
  it('비JSON 응답', () => {
    render(<ResultView outcome={{ kind: 'bad_body' }} />)
    expect(screen.getByText(/응답을 해석할 수 없습니다/)).toBeInTheDocument()
  })
  it('네트워크 오류', () => {
    render(<ResultView outcome={{ kind: 'network' }} />)
    expect(screen.getByText(/네트워크 오류/)).toBeInTheDocument()
  })
})
