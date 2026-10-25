import { useRef, useState } from 'react'
import type { ExecuteOutcome, ExecuteResponse } from './api'

// CIDv0(base58, Qm…) / CIDv1(base32, bafy…) 가 만족하는 느슨한 형태. href 에 넣기 전 검증용
const CID_RE = /^[A-Za-z0-9]{10,100}$/
const LOCAL_IPFS = 'http://ipfs.lgtm.local/ipfs/'
// ipfs.io 는 service worker gateway 로 옮겨 가는 중이라 inbrowser.link 를 쓴다 (출제자 확인, README IPFS and NAT)
const PUBLIC_IPFS = 'https://inbrowser.link/ipfs/'

export function ResultView({ outcome }: { outcome: ExecuteOutcome }) {
  switch (outcome.kind) {
    case 'ok':
      return <Executed data={outcome.data} />
    case 'too_large':
      return <p className="notice error">코드가 너무 깁니다 (64KB)</p>
    case 'busy':
      return <p className="notice error">서버가 바쁩니다</p>
    case 'http_error':
      return <p className="notice error">서버 오류 (HTTP {outcome.status})</p>
    case 'bad_body':
      return <p className="notice error">응답을 해석할 수 없습니다</p>
    case 'network':
      return <p className="notice error">네트워크 오류: 서버에 연결할 수 없습니다</p>
  }
}

function Executed({ data }: { data: ExecuteResponse }) {
  return (
    <div>
      <StatusBody data={data} />
      {data.timings_ms && <Timings t={data.timings_ms} />}
      <IpfsLinks data={data} />
      {data.trace_id && <TraceId id={data.trace_id} />}
    </div>
  )
}

function StatusBody({ data }: { data: ExecuteResponse }) {
  switch (data.status) {
    case 'success':
      return (
        <>
          {data.truncated && <span className="badge">Output truncated (10kB)</span>}
          <Stream label="stdout" testId="stdout" text={data.stdout} />
          <Stream label="stderr" testId="stderr" text={data.stderr} />
        </>
      )
    case 'compile_error':
      return (
        <>
          <p className="notice error">Compile error</p>
          <pre data-testid="compile-error">{data.stderr || data.message || ''}</pre>
        </>
      )
    case 'runtime_error':
      return (
        <>
          <p className="notice error">Runtime error</p>
          {data.message && <p>{data.message}</p>}
          <Stream label="stderr" testId="stderr" text={data.stderr} />
          <Stream label="stdout" testId="stdout" text={data.stdout} />
        </>
      )
    case 'timeout':
      return <p className="notice error">Time limit exceeded (5s)</p>
    case 'memory_limit':
      return <p className="notice error">Memory limit exceeded (10MB)</p>
    case 'internal_error':
      return (
        <>
          <p className="notice error">서버 내부 오류, 잠시 후 다시 시도</p>
          {data.message && <pre>{data.message}</pre>}
        </>
      )
    default:
      return (
        <>
          <p className="notice">status: {data.status}</p>
          {data.message && <pre>{data.message}</pre>}
          {data.stdout && <pre>{data.stdout}</pre>}
          {data.stderr && <pre>{data.stderr}</pre>}
        </>
      )
  }
}

function Stream({ label, testId, text }: { label: string; testId: string; text?: string }) {
  if (!text) return null
  return (
    <div>
      <div className="label">{label}</div>
      <pre data-testid={testId} className={label}>
        {text}
      </pre>
    </div>
  )
}

function Timings({ t }: { t: NonNullable<ExecuteResponse['timings_ms']> }) {
  const parts = (['compile', 'execute', 'ipfs_upload'] as const)
    .filter((k) => typeof t[k] === 'number')
    .map((k) => `${k} ${t[k]}ms`)
  if (parts.length === 0) return null
  return (
    <div className="meta" data-testid="timings">
      {parts.join(' · ')}
    </div>
  )
}

// 응답의 ipfs_url 은 href 에 쓰지 않는다. null/빈 값이면 업로드 실패로만 판단하고, 링크는 검증된 cid 로 직접 조립한다.
function IpfsLinks({ data }: { data: ExecuteResponse }) {
  if (!data.ipfs_url) return <p className="notice">공유 링크 생성 실패(IPFS timeout)</p>
  const cid = data.cid ?? ''
  if (!CID_RE.test(cid)) return <p className="notice error">유효하지 않은 CID라 링크를 만들지 않았습니다</p>
  return (
    <div className="meta">
      <a href={LOCAL_IPFS + cid} target="_blank" rel="noopener noreferrer">
        ipfs.lgtm.local/ipfs/{cid}
      </a>
      {' · '}
      <a href={PUBLIC_IPFS + cid} target="_blank" rel="noopener noreferrer">
        inbrowser.link/ipfs/{cid}
      </a>
    </div>
  )
}

// http://lgtm.local 은 보안 컨텍스트가 아니라 navigator.clipboard 가 없다. 그 경우(또는 거부) 텍스트를 선택하고 안내한다.
function TraceId({ id }: { id: string }) {
  const ref = useRef<HTMLElement>(null)
  const [state, setState] = useState<'idle' | 'copied' | 'selected'>('idle')

  function select() {
    const el = ref.current
    const sel = window.getSelection()
    if (!el || !sel) return
    const range = document.createRange()
    range.selectNodeContents(el)
    sel.removeAllRanges()
    sel.addRange(range)
    setState('selected')
  }

  async function copy() {
    try {
      if (!navigator.clipboard) throw new Error('no clipboard')
      await navigator.clipboard.writeText(id)
      setState('copied')
    } catch {
      select()
    }
  }

  return (
    <div className="meta">
      trace_id: <code ref={ref} data-testid="trace-id">{id}</code>{' '}
      <button type="button" onClick={copy}>
        복사
      </button>{' '}
      {state === 'copied' && <span>복사됨</span>}
      {state === 'selected' && <span>선택됨 — Ctrl+C로 복사</span>}
    </div>
  )
}
