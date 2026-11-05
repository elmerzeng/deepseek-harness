// TCP front end for the stdio-only SDK runtime: one runtime process per accepted connection.
// Usage: DSH_SDK_BRIDGE_TOKEN=<secret> node sdk-bridge.mjs <port> <maxConnections> <command> [args...]
// The client's first line must be the token; everything after it is the newline-delimited
// JSON-RPC stream, forwarded unchanged in both directions.
import { spawn } from 'node:child_process'
import { timingSafeEqual } from 'node:crypto'
import { createServer } from 'node:net'

const [port, maxConnections, ...command] = process.argv.slice(2)
const token = Buffer.from(process.env.DSH_SDK_BRIDGE_TOKEN ?? '')
if (token.length === 0 || command.length === 0 || !Number.isInteger(Number(port)) || !(Number(maxConnections) > 0)) {
  console.error('usage: DSH_SDK_BRIDGE_TOKEN=<secret> sdk-bridge.mjs <port> <maxConnections> <command> [args...]')
  process.exit(2)
}

const authDeadlineMs = 10_000
const maxTokenLineBytes = 1024
let active = 0

const server = createServer(socket => {
  if (active >= Number(maxConnections)) {
    socket.destroy()
    return
  }
  active += 1
  let child
  let pending = Buffer.alloc(0)
  socket.setNoDelay(true)
  socket.on('error', error => console.error(`connection error: ${error.message}`))
  socket.on('close', () => {
    active -= 1
    // The runtime exits on stdin EOF; the signal covers a runtime stuck mid-turn.
    child?.kill('SIGTERM')
  })
  socket.setTimeout(authDeadlineMs, () => socket.destroy())

  const authenticate = chunk => {
    pending = Buffer.concat([pending, chunk])
    const newline = pending.indexOf(0x0a)
    if (newline < 0) {
      if (pending.length > maxTokenLineBytes) socket.destroy()
      return
    }
    socket.off('data', authenticate)
    const presented = pending.subarray(0, newline)
    if (presented.length !== token.length || !timingSafeEqual(presented, token)) {
      socket.destroy()
      return
    }
    socket.setTimeout(0)
    child = spawn(command[0], command.slice(1), { stdio: ['pipe', 'pipe', 'inherit'] })
    child.on('error', error => {
      console.error(`runtime spawn failed: ${error.message}`)
      socket.destroy()
    })
    child.on('exit', () => socket.end())
    child.stdin.on('error', error => console.error(`runtime stdin: ${error.message}`))
    const rest = pending.subarray(newline + 1)
    if (rest.length > 0) child.stdin.write(rest)
    socket.pipe(child.stdin)
    child.stdout.pipe(socket)
  }
  socket.on('data', authenticate)
})

server.listen(Number(port), () => console.error(`sdk bridge listening on :${port}`))
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => process.exit(0))
