import { useState } from 'react'
import { execute, type ExecuteResponse } from './api'
import { Editor } from './Editor'
import { EXAMPLE_CODE } from './example'

export function App() {
  const [code, setCode] = useState(EXAMPLE_CODE)
  const [running, setRunning] = useState(false)
  const [result, setResult] = useState<ExecuteResponse | null>(null)
  const [error, setError] = useState<string | null>(null)

  async function run() {
    setRunning(true)
    setError(null)
    try {
      setResult(await execute(code))
    } catch (e) {
      setResult(null)
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setRunning(false)
    }
  }

  return (
    <main>
      <header>
        <h1>LGTM Rust Playground</h1>
        <button onClick={run} disabled={running} className="run">
          {running && <span className="spinner" role="status" aria-label="실행 중" />}
          {running ? 'Running…' : 'Run'}
        </button>
      </header>
      <Editor value={code} onChange={setCode} />
      <section className="result">
        {error && <pre>요청 실패: {error}</pre>}
        {result && (
          <>
            <div>status: {result.status}</div>
            <pre>{result.stdout ?? result.message ?? ''}</pre>
          </>
        )}
      </section>
    </main>
  )
}
