// Tiny API used by the GUI. Everything device-related is done by the
// PowerShell scripts in ../../scripts - this file only spawns them and
// streams their output back as NDJSON lines:
//   {t:'log', line} | {t:'scan', data} | {t:'summary', data} | {t:'exit', code}
import { spawn, spawnSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const SCRIPTS = path.join(ROOT, 'scripts')
const OUTPUT = path.join(ROOT, 'output')
const PKG_RE = /^[A-Za-z]\w*(\.\w+)*$/
const SERIAL_RE = /^[\w.:-]+$/
const ANSI_RE = /\x1b\[[0-9;?]*[A-Za-z]/g

const PS = ['pwsh', 'powershell'].find(exe => {
  try { return spawnSync(exe, ['-NoProfile', '-Command', 'exit 0'], { windowsHide: true }).status === 0 } catch { return false }
}) || 'powershell'

let job = null

function runScript(script, args) {
  return spawn(PS, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', path.join(SCRIPTS, script), ...args], {
    cwd: ROOT, windowsHide: true,
  })
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^﻿/, ''))
}

function lineReader(onLine) {
  let buf = ''
  return {
    push(chunk) {
      buf += chunk.toString('utf8')
      let i
      while ((i = buf.indexOf('\n')) >= 0) {
        onLine(buf.slice(0, i).replace(/\r$/, '').replace(ANSI_RE, ''))
        buf = buf.slice(i + 1)
      }
    },
    flush() { if (buf) onLine(buf.replace(ANSI_RE, '')); buf = '' },
  }
}

// Stream a script run to the HTTP response. onMarker maps "@@KEY=value" lines to events.
function streamJob(res, child, onMarker) {
  res.writeHead(200, { 'Content-Type': 'application/x-ndjson; charset=utf-8', 'Cache-Control': 'no-cache' })
  const send = obj => { if (!res.writableEnded) res.write(JSON.stringify(obj) + '\n') }
  const reader = lineReader(line => {
    const m = line.match(/^@@(\w+)=(.*)$/)
    if (!m) return send({ t: 'log', line })
    try { const ev = onMarker?.(m[1], m[2]); if (ev) send(ev) } catch (e) { send({ t: 'log', line: `[gui] ${e.message}` }) }
  })
  job = child
  let done = false
  const finish = code => {
    if (done) return
    done = true
    reader.flush()
    send({ t: 'exit', code })
    res.end()
    if (job === child) job = null
  }
  child.stdout.on('data', d => reader.push(d))
  child.stderr.on('data', d => reader.push(d))
  child.on('error', e => { send({ t: 'log', line: `[ERROR] ${e.message}` }); finish(-1) })
  child.on('close', code => finish(code))
}

function collect(child) {
  return new Promise(resolve => {
    let out = ''
    child.stdout.on('data', d => { out += d })
    child.stderr.on('data', d => { out += d })
    child.on('error', () => resolve(out))
    child.on('close', () => resolve(out))
  })
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let raw = ''
    req.on('data', d => { raw += d; if (raw.length > 1e6) req.destroy() })
    req.on('end', () => { try { resolve(raw ? JSON.parse(raw) : {}) } catch (e) { reject(e) } })
    req.on('error', reject)
  })
}

function json(res, status, data) {
  res.writeHead(status, { 'Content-Type': 'application/json' })
  res.end(JSON.stringify(data))
}

// Every output/<device>/latest.json, newest first
function savedScans() {
  if (!fs.existsSync(OUTPUT)) return []
  const list = []
  for (const dir of fs.readdirSync(OUTPUT, { withFileTypes: true })) {
    if (!dir.isDirectory()) continue
    const file = path.join(OUTPUT, dir.name, 'latest.json')
    if (!fs.existsSync(file)) continue
    try { list.push({ file, mtime: fs.statSync(file).mtimeMs, device: readJson(file).device || {} }) } catch { /* ignore broken file */ }
  }
  return list.sort((a, b) => b.mtime - a.mtime)
}

function findLatestScan(serial) {
  const hit = savedScans().find(s => s.device.serial === serial || s.device.serialNo === serial)
  return hit ? readJson(hit.file) : null
}

export function apiMiddleware(port) {
  const allowedHosts = new Set([`127.0.0.1:${port}`, `localhost:${port}`])

  return async (req, res, next) => {
    if (!req.url.startsWith('/api/')) return next()

    // This API can uninstall apps: refuse anything that is not this local page.
    const origin = req.headers.origin
    if (!allowedHosts.has(req.headers.host) || (origin && !allowedHosts.has(origin.replace(/^https?:\/\//, '')))) {
      return json(res, 403, { error: 'forbidden' })
    }
    if (req.method === 'POST' && !String(req.headers['content-type']).startsWith('application/json')) {
      return json(res, 415, { error: 'json only' })
    }

    const url = new URL(req.url, 'http://local')
    try {
      if (req.method === 'GET' && url.pathname === '/api/devices') {
        const out = await collect(runScript('scanner.ps1', ['-ListDevices']))
        const m = out.match(/@@DEVICES=(.*)/)
        let devices = m ? JSON.parse(m[1]) : []
        if (!Array.isArray(devices)) devices = [devices]
        // devices that are not connected but have a saved scan can still be browsed
        for (const s of savedScans()) {
          if (!devices.some(d => d.serial === s.device.serial)) {
            devices.push({ serial: s.device.serial, model: `${s.device.model || s.device.serial}`, state: 'offline' })
          }
        }
        return json(res, 200, { devices, shell: PS })
      }

      if (req.method === 'GET' && url.pathname === '/api/latest') {
        const serial = url.searchParams.get('serial') || ''
        return json(res, 200, { scan: SERIAL_RE.test(serial) ? findLatestScan(serial) : null })
      }

      if (req.method === 'POST' && url.pathname === '/api/cancel') {
        if (job?.pid) spawnSync('taskkill', ['/pid', String(job.pid), '/T', '/F'], { windowsHide: true })
        return json(res, 200, { ok: true })
      }

      if (req.method === 'POST' && (url.pathname === '/api/scan' || url.pathname === '/api/run')) {
        if (job) return json(res, 409, { error: 'Another operation is still running.' })
        const body = await readBody(req)
        const args = []
        if (body.serial) {
          if (!SERIAL_RE.test(body.serial)) return json(res, 400, { error: 'bad serial' })
          args.push('-Serial', body.serial)
        }

        if (url.pathname === '/api/scan') {
          if (['Recommended', 'Aggressive', 'Maximum'].includes(body.level)) args.push('-Level', body.level)
          return streamJob(res, runScript('scanner.ps1', args), (key, value) =>
            key === 'SCAN_JSON' ? { t: 'scan', data: readJson(value.trim()) } : null)
        }

        const packages = [...new Set((body.packages || []).filter(p => typeof p === 'string' && PKG_RE.test(p)))]
        if (!packages.length) return json(res, 400, { error: 'no valid packages' })
        const mode = ['Uninstall', 'Disable', 'Restore'].includes(body.mode) ? body.mode : 'Uninstall'

        // Every run's list is kept on disk so it can be re-used with remover.ps1 -ListFile
        const selDir = path.join(OUTPUT, 'selections')
        fs.mkdirSync(selDir, { recursive: true })
        const stamp = new Date().toISOString().replace(/[-:]/g, '').replace('T', '_').slice(0, 15)
        const listFile = path.join(selDir, `${stamp}_${mode.toLowerCase()}${body.dryRun ? '_dryrun' : ''}.txt`)
        fs.writeFileSync(listFile, `# ${mode} via GUI ${new Date().toLocaleString()}\n${packages.join('\n')}\n`)

        args.push('-ListFile', listFile, '-Mode', mode)
        if (body.dryRun) args.push('-DryRun')
        if (body.keepData) args.push('-KeepData')
        return streamJob(res, runScript('remover.ps1', args), (key, value) =>
          key === 'SUMMARY' ? { t: 'summary', data: JSON.parse(value) } : null)
      }

      return json(res, 404, { error: 'not found' })
    } catch (e) {
      if (!res.headersSent) json(res, 500, { error: e.message })
      else res.end()
    }
  }
}
