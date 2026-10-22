import { useState } from 'react'
import { execute, type ExecuteOutcome } from './api'
import { Editor } from './Editor'
import { EXAMPLE_CODE } from './example'
import { ResultView } from './ResultView'

export function App() {
  const [code, setCode] = useState(EXAMPLE_CODE)
  const [running, setRunning] = useState(false)
  const [outcome, setOutcome] = useState<ExecuteOutcome | null>(null)

  async function run() {
    setRunning(true)
    try {
      setOutcome(await execute(code))
    } finally {
      setRunning(false)
    }
  }

  return (
    <main>
      <header>
        <h1>LGTM Rust Playground</h1>
        <div className="actions">
          <span className="public-note">실행한 코드와 결과는 IPFS에 영구 공개됩니다</span>
          <button onClick={run} disabled={running} className="run">
            {running && <span className="spinner" role="status" aria-label="실행 중" />}
            {running ? 'Running…' : 'Run'}
          </button>
        </div>
      </header>
      <Editor value={code} onChange={setCode} />
      <section className="result">
        {outcome && <ResultView outcome={outcome} />}
      </section>
    </main>
  )
}
