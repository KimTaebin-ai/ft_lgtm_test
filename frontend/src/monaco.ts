// Monaco 를 npm 패키지에서 로컬 번들로 쓴다 (CDN 로드 없음).
// Rust 는 전용 language worker 가 없으므로 기본 editor worker 하나만 필요하다.
import * as monaco from 'monaco-editor/editor/editor.api'
import 'monaco-editor/languages/definitions/rust/register'
import EditorWorker from 'monaco-editor/editor/editor.worker?worker'

self.MonacoEnvironment = { getWorker: () => new EditorWorker() }

export { monaco }
