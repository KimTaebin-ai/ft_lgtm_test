import { afterEach, describe, expect, it, vi } from 'vitest'
import { execute } from './api'

function stubFetch(impl: () => Promise<Response>) {
  const f = vi.fn(impl)
  vi.stubGlobal('fetch', f)
  return f
}
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('execute()', () => {
  it('200 JSON → ok', async () => {
    const f = stubFetch(async () => json(200, { status: 'success', stdout: 'hi' }))
    const out = await execute('fn main(){}')
    expect(out).toEqual({ kind: 'ok', data: { status: 'success', stdout: 'hi' } })
    const [url, init] = f.mock.calls[0] as unknown as [string, RequestInit]
    expect(url).toBe('/api/execute')
    expect(JSON.parse(init.body as string)).toEqual({ language: 'rust', code: 'fn main(){}' })
  })
  it('413 → too_large', async () => {
    stubFetch(async () => json(413, { error: 'x' }))
    expect(await execute('')).toEqual({ kind: 'too_large' })
  })
  it('429 → busy', async () => {
    stubFetch(async () => json(429, {}))
    expect(await execute('')).toEqual({ kind: 'busy' })
  })
  it('500 → http_error', async () => {
    stubFetch(async () => new Response('oops', { status: 500 }))
    expect(await execute('')).toEqual({ kind: 'http_error', status: 500 })
  })
  it('400 → http_error', async () => {
    stubFetch(async () => json(400, { error: 'invalid_request' }))
    expect(await execute('')).toEqual({ kind: 'http_error', status: 400 })
  })
  it('200 이지만 비JSON → bad_body', async () => {
    stubFetch(async () => new Response('<html>', { status: 200 }))
    expect(await execute('')).toEqual({ kind: 'bad_body' })
  })
  it('200 이지만 JSON 이 객체가 아니거나 status 없음 → bad_body', async () => {
    stubFetch(async () => json(200, [1, 2]))
    expect(await execute('')).toEqual({ kind: 'bad_body' })
    stubFetch(async () => json(200, { stdout: 'x' }))
    expect(await execute('')).toEqual({ kind: 'bad_body' })
  })
  it('fetch reject → network', async () => {
    stubFetch(async () => {
      throw new TypeError('Failed to fetch')
    })
    expect(await execute('')).toEqual({ kind: 'network' })
  })
})
