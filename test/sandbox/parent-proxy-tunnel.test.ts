import { describe, test, expect, beforeAll, afterAll } from 'bun:test'
import { createServer as createHttpServer, type Server } from 'node:http'
import { connect, type Socket } from 'node:net'
import { type AddressInfo } from 'node:net'
import { createHttpProxyServer } from '../../src/sandbox/http-proxy.js'
import { resolveParentProxy } from '../../src/sandbox/parent-proxy.js'

/**
 * End-to-end: client -> SRT HTTP proxy -> parent HTTP proxy -> origin.
 * The parent proxy records every CONNECT it receives so we can assert SRT
 * chained through it rather than dialing the origin directly.
 */
describe('parent-proxy: HTTP CONNECT tunnelling', () => {
  let origin: Server
  let originPort: number
  let parent: Server
  let parentPort: number
  let srt: Server
  let srtPort: number
  const parentConnects: string[] = []

  beforeAll(async () => {
    // Origin: plain HTTP server that responds with a marker body.
    origin = createHttpServer((_req, res) => {
      res.writeHead(200, { 'content-type': 'text/plain' })
      res.end('hello-from-origin')
    })
    await new Promise<void>(r => origin.listen(0, '127.0.0.1', r))
    originPort = (origin.address() as AddressInfo).port

    // Parent proxy: handles CONNECT by dialing the requested host:port and
    // piping. Records each CONNECT target.
    parent = createHttpServer()
    parent.on('connect', (req, clientSock) => {
      parentConnects.push(req.url!)
      const [h, p] = req.url!.split(':')
      const up = connect(Number(p), h, () => {
        clientSock.write('HTTP/1.1 200 OK\r\n\r\n')
        up.pipe(clientSock)
        clientSock.pipe(up)
      })
      up.on('error', () => clientSock.destroy())
    })
    await new Promise<void>(r => parent.listen(0, '127.0.0.1', r))
    parentPort = (parent.address() as AddressInfo).port

    // SRT proxy configured with the parent.
    srt = createHttpProxyServer({
      filter: () => true,
      parentProxy: resolveParentProxy({
        http: `http://127.0.0.1:${parentPort}`,
        // The parent listens on loopback, so a loopback destination is
        // tunnelled through it rather than dialed direct.
        noProxy: '',
      }),
    })
    await new Promise<void>(r => srt.listen(0, '127.0.0.1', () => r()))
    srtPort = (srt.address() as AddressInfo).port
  })

  afterAll(async () => {
    await Promise.all([
      new Promise<void>(r => origin.close(() => r())),
      new Promise<void>(r => parent.close(() => r())),
      new Promise<void>(r => srt.close(() => r())),
    ])
  })

  test('loopback destination tunnels when the parent is loopback', async () => {
    parentConnects.length = 0
    const body = await connectAndGet(srtPort, '127.0.0.1', originPort, '/')
    expect(body).toContain('hello-from-origin')
    expect(parentConnects).toEqual([`127.0.0.1:${originPort}`])
  })

  test('non-loopback destination tunnels through parent', async () => {
    // Spin up a second SRT proxy whose parentProxy has noProxy empty, and
    // hit a non-loopback hostname that resolves to the origin. We fake this
    // by having the parent proxy rewrite the CONNECT target to our origin.
    parentConnects.length = 0

    const rewritingParent = createHttpServer()
    rewritingParent.on('connect', (req, clientSock) => {
      parentConnects.push(req.url!)
      // Ignore requested target; always connect to our local origin.
      const up = connect(originPort, '127.0.0.1', () => {
        clientSock.write('HTTP/1.1 200 OK\r\n\r\n')
        up.pipe(clientSock)
        clientSock.pipe(up)
      })
      up.on('error', () => clientSock.destroy())
    })
    await new Promise<void>(r => rewritingParent.listen(0, '127.0.0.1', r))
    const rpPort = (rewritingParent.address() as AddressInfo).port

    const srt2 = createHttpProxyServer({
      filter: () => true,
      parentProxy: resolveParentProxy({
        http: `http://127.0.0.1:${rpPort}`,
        noProxy: '',
      }),
    })
    await new Promise<void>(r => srt2.listen(0, '127.0.0.1', () => r()))
    const srt2Port = (srt2.address() as AddressInfo).port

    try {
      const body = await connectAndGet(srt2Port, 'upstream.example', 80, '/')
      expect(body).toContain('hello-from-origin')
      expect(parentConnects).toEqual(['upstream.example:80'])
    } finally {
      await new Promise<void>(r => srt2.close(() => r()))
      await new Promise<void>(r => rewritingParent.close(() => r()))
    }
  })
})

describe('parent-proxy: delegateDomainPolicy skips the domain filter', () => {
  let parent: Server
  let parentPort: number
  const parentConnects: string[] = []

  beforeAll(async () => {
    parent = createHttpServer()
    parent.on('connect', (req, clientSock) => {
      parentConnects.push(req.url!)
      clientSock.write('HTTP/1.1 200 OK\r\n\r\n')
      clientSock.end()
    })
    await new Promise<void>(r => parent.listen(0, '127.0.0.1', r))
    parentPort = (parent.address() as AddressInfo).port
  })

  afterAll(async () => {
    await new Promise<void>(r => parent.close(() => r()))
  })

  async function serve(opts: {
    delegate: boolean
    mitm?: boolean
  }): Promise<{ port: number; asked: string[]; close: () => Promise<void> }> {
    const asked: string[] = []
    const srt = createHttpProxyServer({
      filter: (_port, host) => {
        asked.push(host)
        return false
      },
      getMitmSocketPath: opts.mitm ? () => '/tmp/srt-mitm-unused' : undefined,
      parentProxy: resolveParentProxy({
        http: `http://127.0.0.1:${parentPort}`,
        delegateDomainPolicy: opts.delegate,
      }),
    })
    await new Promise<void>(r => srt.listen(0, '127.0.0.1', () => r()))
    return {
      port: (srt.address() as AddressInfo).port,
      asked,
      close: () => new Promise(r => srt.close(() => r())),
    }
  }

  test('a chained destination is not shown to the domain filter', async () => {
    parentConnects.length = 0
    const srt = await serve({ delegate: true })
    try {
      const status = await connectStatus(srt.port, 'upstream.example', 443)
      expect(status).toContain(' 200 ')
      expect(srt.asked).toEqual([])
      expect(parentConnects).toEqual(['upstream.example:443'])
    } finally {
      await srt.close()
    }
  })

  test('without the flag the domain filter still denies', async () => {
    parentConnects.length = 0
    const srt = await serve({ delegate: false })
    try {
      const status = await connectStatus(srt.port, 'upstream.example', 443)
      expect(status).toContain(' 403 ')
      expect(srt.asked).toEqual(['upstream.example'])
      expect(parentConnects).toEqual([])
    } finally {
      await srt.close()
    }
  })

  test('loopback is delegated when the parent is loopback', async () => {
    parentConnects.length = 0
    const srt = await serve({ delegate: true })
    try {
      const status = await connectStatus(srt.port, '127.0.0.1', 9)
      expect(status).toContain(' 200 ')
      expect(srt.asked).toEqual([])
      expect(parentConnects).toEqual(['127.0.0.1:9'])
    } finally {
      await srt.close()
    }
  })

  test('a mitmProxy host still goes through the domain filter', async () => {
    parentConnects.length = 0
    const srt = await serve({ delegate: true, mitm: true })
    try {
      const status = await connectStatus(srt.port, 'upstream.example', 443)
      expect(status).toContain(' 403 ')
      expect(srt.asked).toEqual(['upstream.example'])
      expect(parentConnects).toEqual([])
    } finally {
      await srt.close()
    }
  })
})

/** CONNECT to proxyPort and return the status line. */
function connectStatus(
  proxyPort: number,
  destHost: string,
  destPort: number,
): Promise<string> {
  return new Promise((resolve, reject) => {
    const sock: Socket = connect(proxyPort, '127.0.0.1', () => {
      sock.write(
        `CONNECT ${destHost}:${destPort} HTTP/1.1\r\n` +
          `Host: ${destHost}:${destPort}\r\n\r\n`,
      )
    })
    let buf = ''
    sock.on('data', chunk => {
      buf += chunk.toString()
      const end = buf.indexOf('\r\n')
      if (end === -1) return
      const status = buf.slice(0, end)
      sock.destroy()
      resolve(status)
    })
    sock.on('error', err => {
      if (buf.includes('HTTP/')) return
      reject(err)
    })
  })
}

/** Issue CONNECT to proxyPort, then GET path over the tunnel. Returns body. */
function connectAndGet(
  proxyPort: number,
  destHost: string,
  destPort: number,
  path: string,
): Promise<string> {
  return new Promise((resolve, reject) => {
    const sock: Socket = connect(proxyPort, '127.0.0.1', () => {
      sock.write(
        `CONNECT ${destHost}:${destPort} HTTP/1.1\r\n` +
          `Host: ${destHost}:${destPort}\r\n\r\n`,
      )
    })
    let phase: 'connect' | 'body' = 'connect'
    let buf = ''
    sock.on('data', chunk => {
      buf += chunk.toString()
      if (phase === 'connect') {
        const i = buf.indexOf('\r\n\r\n')
        if (i === -1) return
        const status = buf.slice(0, buf.indexOf('\r\n'))
        if (!status.includes(' 200 ')) {
          return reject(new Error(`CONNECT failed: ${status}`))
        }
        buf = buf.slice(i + 4)
        phase = 'body'
        sock.write(
          `GET ${path} HTTP/1.1\r\nHost: ${destHost}\r\nConnection: close\r\n\r\n`,
        )
      }
    })
    sock.on('end', () => resolve(buf))
    sock.on('error', reject)
  })
}
