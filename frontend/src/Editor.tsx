import { useEffect, useRef } from 'react'
import { monaco } from './monaco'

interface Props {
  value: string
  onChange: (value: string) => void
}

export function Editor({ value, onChange }: Props) {
  const host = useRef<HTMLDivElement>(null)
  const onChangeRef = useRef(onChange)
  useEffect(() => {
    onChangeRef.current = onChange
  }, [onChange])

  useEffect(() => {
    const editor = monaco.editor.create(host.current!, {
      value,
      language: 'rust',
      lineNumbers: 'on',
      automaticLayout: true,
      minimap: { enabled: false },
      fontSize: 14,
      theme: 'vs-dark',
    })
    const sub = editor.onDidChangeModelContent(() => onChangeRef.current(editor.getValue()))
    return () => {
      sub.dispose()
      editor.dispose()
    }
    // 초기값만 사용한다 (이후는 에디터가 상태의 원본)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  return <div ref={host} className="editor" />
}
