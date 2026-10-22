// POST /api/execute (PRD 6.2). 모든 실패를 throw 가 아니라 ExecuteOutcome 으로 구분해 돌려준다.
export interface Timings {
  compile?: number
  execute?: number
  ipfs_upload?: number
}

export interface ExecuteResponse {
  status: string
  stdout?: string
  stderr?: string
  message?: string
  truncated?: boolean
  cid?: string
  ipfs_url?: string | null
  trace_id?: string
  timings_ms?: Timings
}

export type ExecuteOutcome =
  | { kind: 'ok'; data: ExecuteResponse }
  | { kind: 'too_large' } // 413
  | { kind: 'busy' } // 429
  | { kind: 'http_error'; status: number }
  | { kind: 'bad_body' } // 200 인데 JSON 이 아니거나 status 가 없음
  | { kind: 'network' }

export async function execute(code: string): Promise<ExecuteOutcome> {
  let res: Response
  try {
    res = await fetch('/api/execute', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ language: 'rust', code }),
    })
  } catch {
    return { kind: 'network' }
  }
  if (res.status === 413) return { kind: 'too_large' }
  if (res.status === 429) return { kind: 'busy' }
  if (!res.ok) return { kind: 'http_error', status: res.status }
  let body: unknown
  try {
    body = await res.json()
  } catch {
    return { kind: 'bad_body' }
  }
  if (typeof body !== 'object' || body === null || Array.isArray(body)) return { kind: 'bad_body' }
  if (typeof (body as { status?: unknown }).status !== 'string') return { kind: 'bad_body' }
  return { kind: 'ok', data: body as ExecuteResponse }
}
