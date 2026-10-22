// POST /api/execute (PRD 6.2). 결과 표시용 최소 필드만 선언한다. 상태별 처리는 F-M4-02.
export interface ExecuteResponse {
  status: string
  stdout?: string
  stderr?: string
  message?: string
}

export async function execute(code: string): Promise<ExecuteResponse> {
  const res = await fetch('/api/execute', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ language: 'rust', code }),
  })
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return (await res.json()) as ExecuteResponse
}
