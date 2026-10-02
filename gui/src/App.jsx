import { useCallback, useEffect, useMemo, useRef, useState } from 'react'

const CATS = [
  ['thirdparty', 'Third-party preloads'],
  ['oem', 'OEM / ODM apps'],
  ['carrier', 'Carrier apps'],
  ['google', 'Google apps'],
  ['chipset', 'Chipset services'],
  ['unknown', 'Unrecognised system'],
  ['user', 'Your installed apps'],
  ['system', 'Android system'],
  ['custom', 'Custom packages'],
]
const CAT_NAME = Object.fromEntries(CATS)
const RISKS = ['safe', 'optional', 'caution', 'keep']
const RISK_ORDER = { safe: 0, optional: 1, caution: 2, keep: 3 }
const RISK_HINT = {
  safe: 'Junk, ads and demo apps. Removing them is harmless',
  optional: 'Real apps like Gmail, Maps or Notes. Remove them if you use something else',
  caution: 'Background services. Removing one may break a feature like camera, sync or updates',
  keep: 'Core Android. Removing it can stop the device from working',
}
const CAT_HINT = {
  thirdparty: 'Apps from other companies that came pre-installed: Facebook, Netflix, games, ad installers',
  oem: 'Apps added by the phone maker: Samsung, Xiaomi, Lenovo, Realme...',
  carrier: 'Apps added by your mobile network: Jio, Airtel, Verizon...',
  google: 'Google apps and Google services',
  chipset: 'Hardware support services from the chip maker: Qualcomm, MediaTek',
  unknown: 'System apps no rule recognises. Check the name before removing',
  user: 'Apps you installed yourself. Never selected automatically',
  system: 'Parts of Android itself',
  custom: 'Package names you typed in yourself',
}
const STATUS_OPTS = [
  ['active', 'On device', 'Apps still on the device: installed or disabled'],
  ['installed', 'Installed', 'Apps that are installed and can run'],
  ['disabled', 'Disabled', 'Apps that are frozen: still on the device but cannot run'],
  ['removed', 'Removed', 'Apps already removed. Select them and use Restore to bring them back'],
  ['all', 'All', 'Everything, including removed apps'],
]
const LEVELS = {
  Recommended: ['safe'],
  Aggressive: ['safe', 'optional'],
  Maximum: ['safe', 'optional', 'caution'],
}
const LEVEL_HINT = {
  Recommended: 'Select only safe junk: ads, demos and leftovers',
  Aggressive: 'Select safe junk plus optional apps (Google and phone-maker apps you may not use)',
  Maximum: 'Select everything except core Android and your own apps',
}
const MODES = {
  Uninstall: 'Remove the selected apps. System apps can be brought back later with Restore',
  Disable: 'Freeze the selected apps. They stay on the device but cannot run',
  Restore: 'Bring back removed or disabled apps',
}
const PKG_RE = /^[A-Za-z]\w*(\.\w+)*$/

const store = {
  get(key, fallback) { try { const v = localStorage.getItem(key); return v ? JSON.parse(v) : fallback } catch { return fallback } },
  set(key, value) { try { localStorage.setItem(key, JSON.stringify(value)) } catch { /* private mode */ } },
}

async function streamPost(url, body, onEvent) {
  const res = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
  if (!res.ok) throw new Error((await res.json().catch(() => null))?.error || res.statusText)
  const reader = res.body.getReader()
  const decoder = new TextDecoder()
  let buf = ''
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    buf += decoder.decode(value, { stream: true })
    let i
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i)
      buf = buf.slice(i + 1)
      if (line.trim()) onEvent(JSON.parse(line))
    }
  }
}

function logClass(line) {
  if (/\[FAIL\]|FAILED|ERROR/i.test(line)) return 'err'
  if (/\[WARN\]/.test(line)) return 'warn'
  if (/\[OK\]|^\s*(PERMANENT|REMOVED|DISABLED|RESTORED)\b|Success/.test(line)) return 'ok'
  if (/^\[\d+\/\d+\]|^STEP|^===|^DONE/.test(line)) return 'head'
  return ''
}

export default function App() {
  const [theme, setTheme] = useState(() => store.get('theme', 'dark'))
  useEffect(() => { document.documentElement.dataset.theme = theme; store.set('theme', theme) }, [theme])

  // device + scan
  const [devices, setDevices] = useState([])
  const [serial, setSerial] = useState('')
  const [scan, setScan] = useState(null)
  const [scanLevel, setScanLevel] = useState(() => store.get('scanLevel', 'Recommended'))
  const [busy, setBusy] = useState('')
  const [error, setError] = useState('')

  // console
  const [logs, setLogs] = useState([])
  const [consoleOpen, setConsoleOpen] = useState(false)
  const [result, setResult] = useState(null)
  const logRef = useRef(null)

  // filters
  const [q, setQ] = useState('')
  const [statusFilter, setStatusFilter] = useState('active')
  const [riskFilter, setRiskFilter] = useState(() => new Set(RISKS))
  const [catFilter, setCatFilter] = useState('all')
  const [collapsed, setCollapsed] = useState(() => new Set(store.get('collapsed', ['system', 'chipset'])))

  // per-device memory
  const devKey = scan?.device?.serialNo || scan?.device?.serial || ''
  const [memKey, setMemKey] = useState('')
  const [selected, setSelected] = useState(() => new Set())
  const [pinned, setPinned] = useState(() => new Set())
  const [custom, setCustom] = useState([])
  const [customInput, setCustomInput] = useState('')

  // run options
  const [mode, setMode] = useState('Uninstall')
  const [dryRun, setDryRun] = useState(false)
  const [keepData, setKeepData] = useState(false)

  useEffect(() => {
    if (!devKey) return
    setSelected(new Set(store.get(`sel:${devKey}`, [])))
    setPinned(new Set(store.get(`pin:${devKey}`, [])))
    setCustom(store.get(`custom:${devKey}`, []))
    setMemKey(devKey)
  }, [devKey])
  useEffect(() => { if (memKey) store.set(`sel:${memKey}`, [...selected]) }, [selected, memKey])
  useEffect(() => { if (memKey) store.set(`pin:${memKey}`, [...pinned]) }, [pinned, memKey])
  useEffect(() => { if (memKey) store.set(`custom:${memKey}`, custom) }, [custom, memKey])
  useEffect(() => { store.set('collapsed', [...collapsed]) }, [collapsed])
  useEffect(() => { store.set('scanLevel', scanLevel) }, [scanLevel])
  useEffect(() => { if (logRef.current) logRef.current.scrollTop = logRef.current.scrollHeight }, [logs, consoleOpen])

  const pushLog = useCallback(line => setLogs(l => (l.length > 4000 ? [...l.slice(-3000), line] : [...l, line])), [])

  const loadDevices = useCallback(async () => {
    setError('')
    try {
      const res = await fetch('/api/devices').then(r => r.json())
      const list = res.devices || []
      setDevices(list)
      setSerial(cur => (list.some(d => d.serial === cur) ? cur : list.find(d => d.state === 'device')?.serial || list[0]?.serial || ''))
      if (!list.some(d => d.state === 'device')) {
        setError(list.length
          ? 'No device connected - showing the last saved scan. Reconnect and press ↻ to run actions.'
          : 'No device found. Enable USB debugging, connect, then refresh.')
      }
    } catch (e) { setError(`API unreachable: ${e.message}`) }
  }, [])
  useEffect(() => { loadDevices() }, [loadDevices])

  useEffect(() => {
    if (!serial) return
    fetch(`/api/latest?serial=${encodeURIComponent(serial)}`).then(r => r.json()).then(r => setScan(r.scan || null)).catch(() => {})
  }, [serial])

  const doScan = useCallback(async () => {
    if (!serial) return
    setBusy('scan'); setError('')
    pushLog(`--- scan ${serial} (${scanLevel}) ---`)
    let got = false
    try {
      await streamPost('/api/scan', { serial, level: scanLevel }, ev => {
        if (ev.t === 'log') pushLog(ev.line)
        else if (ev.t === 'scan') { got = true; setScan(ev.data) }
      })
    } catch (e) { pushLog(`[ERROR] ${e.message}`) }
    if (!got) { setError('Scan failed - see console.'); setConsoleOpen(true) }
    setBusy('')
  }, [serial, scanLevel, pushLog])

  // rows
  const all = useMemo(() => {
    const pkgs = scan?.packages || []
    const known = new Set(pkgs.map(p => p.name))
    const extra = custom.filter(n => !known.has(n)).map(name => ({ name, label: 'Added by you', category: 'custom', risk: 'optional', status: 'unknown', partition: '' }))
    return [...pkgs, ...extra]
  }, [scan, custom])
  const byName = useMemo(() => new Map(all.map(p => [p.name, p])), [all])

  const catCounts = useMemo(() => {
    const c = {}
    for (const p of all) c[p.category] = (c[p.category] || 0) + 1
    return c
  }, [all])
  const riskCounts = useMemo(() => {
    const c = {}
    for (const p of all) c[p.risk] = (c[p.risk] || 0) + 1
    return c
  }, [all])

  const filtersChanged = q !== '' || statusFilter !== 'active' || catFilter !== 'all' || riskFilter.size !== RISKS.length
  const resetFilters = () => { setQ(''); setStatusFilter('active'); setCatFilter('all'); setRiskFilter(new Set(RISKS)) }

  const groups = useMemo(() => {
    const ql = q.trim().toLowerCase()
    const rows = all.filter(p =>
      (catFilter === 'all' || p.category === catFilter) &&
      riskFilter.has(p.risk) &&
      (statusFilter === 'all' || (statusFilter === 'active' ? p.status !== 'removed' : p.status === statusFilter)) &&
      (!ql || p.name.toLowerCase().includes(ql) || (p.label || '').toLowerCase().includes(ql)))
    return CATS.map(([key, label]) => ({
      key, label,
      items: rows.filter(p => p.category === key).sort((a, b) => RISK_ORDER[a.risk] - RISK_ORDER[b.risk] || a.name.localeCompare(b.name)),
    })).filter(g => g.items.length)
  }, [all, q, catFilter, riskFilter, statusFilter])

  const visibleCount = groups.reduce((n, g) => n + g.items.length, 0)
  const selectedList = [...selected].filter(n => !pinned.has(n))
  const stats = useMemo(() => ({
    total: scan?.packages?.length || 0,
    installed: (scan?.packages || []).filter(p => p.status === 'installed').length,
    removed: (scan?.packages || []).filter(p => p.status === 'removed').length,
    disabled: (scan?.packages || []).filter(p => p.status === 'disabled').length,
    safe: (scan?.packages || []).filter(p => p.risk === 'safe' && p.status !== 'removed').length,
  }), [scan])

  // selection
  const toggle = name => setSelected(s => { const n = new Set(s); n.has(name) ? n.delete(name) : n.add(name); return n })
  const togglePin = name => {
    setPinned(s => { const n = new Set(s); n.has(name) ? n.delete(name) : n.add(name); return n })
    setSelected(s => { const n = new Set(s); n.delete(name); return n })
  }
  const toggleGroup = items => {
    const pickable = items.filter(p => !pinned.has(p.name) && p.risk !== 'keep')
    const allOn = pickable.length && pickable.every(p => selected.has(p.name))
    setSelected(s => { const n = new Set(s); pickable.forEach(p => (allOn ? n.delete(p.name) : n.add(p.name))); return n })
  }
  const applyLevel = level => {
    const risks = LEVELS[level]
    setMode('Uninstall')
    setSelected(new Set(all.filter(p =>
      p.status !== 'removed' && !p.byUser && !['user', 'custom'].includes(p.category) &&
      risks.includes(p.risk) && !pinned.has(p.name)).map(p => p.name)))
  }
  const selectRemoved = () => {
    setMode('Restore')
    setSelected(new Set(all.filter(p => p.status === 'removed' || p.status === 'disabled').map(p => p.name)))
  }
  const selectVisible = () => setSelected(s => {
    const n = new Set(s)
    groups.forEach(g => g.items.forEach(p => { if (!pinned.has(p.name)) n.add(p.name) }))
    return n
  })

  const addCustom = () => {
    const names = customInput.split(/[\s,;]+/).map(s => s.trim()).filter(Boolean)
    const bad = names.filter(n => !PKG_RE.test(n))
    const good = names.filter(n => PKG_RE.test(n))
    if (bad.length) setError(`Invalid package name: ${bad.join(', ')}`)
    if (!good.length) return
    setCustom(c => [...new Set([...c, ...good.filter(n => !scan?.packages?.some(p => p.name === n))])])
    setSelected(s => new Set([...s, ...good]))
    setCustomInput('')
  }
  const removeCustom = name => {
    setCustom(c => c.filter(n => n !== name))
    setSelected(s => { const n = new Set(s); n.delete(name); return n })
  }

  const run = async () => {
    if (!selectedList.length || busy) return
    const core = selectedList.filter(n => byName.get(n)?.risk === 'keep')
    if (!dryRun) {
      let msg = `${mode} ${selectedList.length} package(s) on ${scan?.device?.model || serial}?`
      if (mode === 'Uninstall') msg += '\n\nSystem apps are removed for user 0 (restorable). User apps are uninstalled permanently.'
      if (core.length && mode !== 'Restore') msg += `\n\nWARNING: ${core.length} core-OS package(s):\n${core.slice(0, 8).join('\n')}${core.length > 8 ? '\n...' : ''}\nThese can break boot or the UI.`
      if (!window.confirm(msg)) return
    }
    setBusy('run'); setResult(null); setConsoleOpen(true); setError('')
    pushLog(`--- ${mode}${dryRun ? ' (dry run)' : ''}: ${selectedList.length} package(s) ---`)
    let summary = null
    try {
      await streamPost('/api/run', { serial, mode, dryRun, keepData, packages: selectedList }, ev => {
        if (ev.t === 'log') pushLog(ev.line)
        else if (ev.t === 'summary') { summary = ev.data; setResult(ev.data) }
      })
    } catch (e) { pushLog(`[ERROR] ${e.message}`) }
    setBusy('')
    if (!dryRun && summary?.results) {
      const done = new Set(summary.results.filter(r => !['failed', 'skipped'].includes(r.result)).map(r => r.package))
      setSelected(s => new Set([...s].filter(n => !done.has(n))))
      await doScan()
    }
  }

  const cancel = () => fetch('/api/cancel', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' })
  const copyList = () => navigator.clipboard?.writeText(selectedList.join('\n'))
  // List file for scripts/debloat.sh (run on the phone via Shizuku / adb shell)
  const exportList = () => {
    const text = `# debloat.sh list - ${selectedList.length} package(s)\n# on the phone: sh debloat.sh uninstall -n -f debloat-list.txt\n${selectedList.join('\n')}\n`
    const a = document.createElement('a')
    a.href = URL.createObjectURL(new Blob([text], { type: 'text/plain' }))
    a.download = 'debloat-list.txt'
    a.click()
    URL.revokeObjectURL(a.href)
  }

  const dev = scan?.device
  const ready = devices.find(d => d.serial === serial)?.state === 'device'

  return (
    <div className={`app ${consoleOpen ? 'with-console' : ''}`}>
      <header className="top">
        <div className="brand"><span className="dot" />Debloat</div>
        <div className="top-actions">
          <select value={serial} onChange={e => setSerial(e.target.value)} disabled={!!busy} aria-label="Device" data-tip="Choose a device. Offline ones show their last saved scan">
            {!devices.length && <option value="">No device</option>}
            {devices.map(d => <option key={d.serial} value={d.serial}>{d.model || d.serial} · {d.state}</option>)}
          </select>
          <button className="ghost" onClick={loadDevices} disabled={!!busy} data-tip="Look for connected devices again">↻</button>
          <select value={scanLevel} onChange={e => setScanLevel(e.target.value)} disabled={!!busy} data-tip="How much the generated auto_remove_bloatware.ps1 script turns on by default">
            {Object.keys(LEVELS).map(l => <option key={l} value={l}>{l} script</option>)}
          </select>
          <button className="primary" onClick={doScan} disabled={!serial || !ready || !!busy} data-tip="Read every app from the device">{busy === 'scan' ? 'Scanning…' : scan ? 'Rescan' : 'Scan'}</button>
          <button className="ghost" onClick={() => setTheme(t => (t === 'dark' ? 'light' : 'dark'))} data-tip="Switch between dark and light theme">{theme === 'dark' ? '☀' : '☾'}</button>
        </div>
      </header>

      {error && <div className="banner">{error}<button className="link" onClick={() => setError('')}>dismiss</button></div>}

      {!scan ? (
        <div className="empty">
          <h1>Scan a device to begin</h1>
          <p>Connect an Android 9-16 phone or tablet with USB debugging on. Every package is listed and classified; nothing is locked - you decide what goes.</p>
          <button className="primary lg" onClick={doScan} disabled={!serial || !ready || !!busy}>{busy === 'scan' ? 'Scanning…' : 'Scan device'}</button>
        </div>
      ) : (
        <>
          <section className="device">
            <div>
              <div className="dev-name">{dev.manufacturer} {dev.model}</div>
              <div className="muted">Android {dev.android} · SDK {dev.sdk} · {dev.type} · {dev.build} · scanned {dev.scannedAt}</div>
            </div>
            <div className="stats">
              <Stat n={stats.total} l="packages" />
              <Stat n={stats.installed} l="installed" />
              <Stat n={stats.disabled} l="disabled" />
              <Stat n={stats.removed} l="removed" />
              <Stat n={stats.safe} l="recommended" accent tip="Safe junk still on the device" />
            </div>
          </section>

          <section className="filters">
            <div className="frow">
              <input className="search" placeholder="Search package or name…" value={q} onChange={e => setQ(e.target.value)} />
              <button className="ghost sm" disabled={!filtersChanged} onClick={resetFilters} data-tip="Clear search and show every app again">Reset filters</button>
            </div>
            <div className="frow">
              <span className="flabel" data-tip="Which apps to show, based on what state they are in on the device">Status</span>
              <Segmented value={statusFilter} onChange={setStatusFilter} options={STATUS_OPTS} />
            </div>
            <div className="frow">
              <span className="flabel" data-tip="How risky removing an app is. Click a level to show or hide those apps">Risk</span>
              <div className="chips">
                {RISKS.map(r => {
                  const on = riskFilter.has(r)
                  return (
                    <button key={r} className={`chip risk-${r} ${on ? 'on' : ''}`} data-tip={`${RISK_HINT[r]}. Click to ${on ? 'hide' : 'show'} these.`}
                      onClick={() => setRiskFilter(s => { const n = new Set(s); n.has(r) ? n.delete(r) : n.add(r); return n })}>
                      <span className="tick">{on ? '✓' : ''}</span>{r} <span>{riskCounts[r] || 0}</span>
                    </button>
                  )
                })}
              </div>
            </div>
            <div className="frow">
              <span className="flabel" data-tip="Who made or added the app">Category</span>
              <div className="chips">
                <button className={`chip ${catFilter === 'all' ? 'on' : ''}`} onClick={() => setCatFilter('all')} data-tip="Show every category">All <span>{all.length}</span></button>
                {CATS.filter(([k]) => catCounts[k]).map(([k, label]) => (
                  <button key={k} className={`chip ${catFilter === k ? 'on' : ''}`} onClick={() => setCatFilter(k)} data-tip={CAT_HINT[k]}>{label} <span>{catCounts[k]}</span></button>
                ))}
              </div>
            </div>
          </section>

          <section className="toolbar">
            <div className="quick">
              <span className="muted">Select</span>
              {Object.keys(LEVELS).map(l => <button key={l} className="ghost sm" data-tip={LEVEL_HINT[l]} onClick={() => applyLevel(l)}>{l}</button>)}
              <button className="ghost sm" onClick={selectVisible} data-tip="Add every app currently shown by the filters">Visible</button>
              <button className="ghost sm" onClick={selectRemoved} data-tip="Select all removed and disabled apps and switch to Restore, to bring them back">Removed</button>
              <button className="ghost sm" onClick={() => setSelected(new Set())} data-tip="Unselect everything">Clear</button>
            </div>
            <form className="add" onSubmit={e => { e.preventDefault(); addCustom() }}>
              <input placeholder="Add any package: com.example.app" value={customInput} onChange={e => setCustomInput(e.target.value)} />
              <button className="ghost sm" type="submit" data-tip="Add an app the list doesn't show, by its package name">Add</button>
            </form>
          </section>

          <main className="list">
            {!visibleCount && <div className="muted pad">Nothing matches these filters.</div>}
            {groups.map(g => {
              const open = !collapsed.has(g.key)
              const pickable = g.items.filter(p => !pinned.has(p.name) && p.risk !== 'keep')
              const nSel = g.items.filter(p => selected.has(p.name)).length
              const allOn = pickable.length > 0 && pickable.every(p => selected.has(p.name))
              return (
                <div className="group" key={g.key}>
                  <div className="group-head">
                    <input type="checkbox" checked={allOn} disabled={!pickable.length} onChange={() => toggleGroup(g.items)} title="Select every app in this group (except core Android)" />
                    <button className="group-title" onClick={() => setCollapsed(s => { const n = new Set(s); n.has(g.key) ? n.delete(g.key) : n.add(g.key); return n })}>
                      <span className={`caret ${open ? 'open' : ''}`}>›</span>{g.label}
                      <span className="muted">{g.items.length}{nSel ? ` · ${nSel} selected` : ''}</span>
                    </button>
                  </div>
                  {open && g.items.map(p => {
                    const isPinned = pinned.has(p.name)
                    return (
                      <label key={p.name} className={`row ${selected.has(p.name) ? 'sel' : ''} ${isPinned ? 'pinned' : ''}`}>
                        <input type="checkbox" checked={selected.has(p.name)} disabled={isPinned} onChange={() => toggle(p.name)} />
                        <div className="pkg">
                          <div className="pkg-name">{p.name}</div>
                          <div className="pkg-label">
                            {p.label || <span className="muted">-</span>}
                            {p.updated && <span className="tag">updated</span>}
                            {p.byUser && <span className="tag">yours</span>}
                          </div>
                        </div>
                        <span className={`badge risk-${p.risk}`} data-tip={RISK_HINT[p.risk]}>{p.risk}</span>
                        <span className={`status st-${p.status}`}>{p.status}</span>
                        <span className="part muted">{p.partition}</span>
                        <button type="button" className={`pin ${isPinned ? 'on' : ''}`} data-tip={isPinned ? 'Protected: click to allow selecting it again' : 'Protect this app so it can never be selected'}
                          onClick={e => { e.preventDefault(); togglePin(p.name) }}>{isPinned ? '●' : '○'}</button>
                        {p.category === 'custom' && <button type="button" className="pin" data-tip="Remove from this list" onClick={e => { e.preventDefault(); removeCustom(p.name) }}>×</button>}
                      </label>
                    )
                  })}
                </div>
              )
            })}
          </main>
        </>
      )}

      <footer className="dock">
        {consoleOpen && (
          <div className="console">
            <div className="console-head">
              <span>Console{result && !busy ? ` · ${result.dryRun ? 'dry run' : result.mode}: ${Object.entries(result.counts || {}).map(([k, v]) => `${k} ${v}`).join(', ') || `${result.planned?.length || 0} planned`}` : ''}</span>
              <span>
                {busy && <button className="link" onClick={cancel}>cancel</button>}
                <button className="link" onClick={() => setLogs([])}>clear</button>
                <button className="link" onClick={() => setConsoleOpen(false)}>hide</button>
              </span>
            </div>
            <pre ref={logRef}>{logs.map((l, i) => <div key={i} className={logClass(l)}>{l || ' '}</div>)}</pre>
          </div>
        )}
        <div className="bar">
          <div className="bar-left">
            <strong>{selectedList.length}</strong><span className="muted">selected</span>
            {selectedList.length > 0 && <button className="link" onClick={copyList} data-tip="Copy the selected package names">copy</button>}
            {selectedList.length > 0 && <button className="link" onClick={exportList} data-tip="Download the selection as a list file for debloat.sh, to run on the phone with Shizuku (no PC needed)">export</button>}
            {!consoleOpen && <button className="link" onClick={() => setConsoleOpen(true)} data-tip="Show the log output">console{busy ? ' ●' : ''}</button>}
          </div>
          <div className="bar-right">
            <Segmented value={mode} onChange={setMode} options={Object.keys(MODES).map(m => [m, m, MODES[m]])} />
            <label className="toggle" data-tip="Only show what would happen. Nothing on the device changes"><input type="checkbox" checked={dryRun} onChange={e => setDryRun(e.target.checked)} />Dry run</label>
            {mode === 'Uninstall' && <label className="toggle" data-tip="Keep the app's data so a later restore is quicker"><input type="checkbox" checked={keepData} onChange={e => setKeepData(e.target.checked)} />Keep data</label>}
            <button className={`primary ${mode === 'Uninstall' && !dryRun ? 'danger' : ''}`} disabled={!selectedList.length || !!busy || !ready} onClick={run}>
              {busy === 'run' ? 'Running…' : dryRun ? 'Preview' : mode}
            </button>
          </div>
        </div>
      </footer>
    </div>
  )
}

function Stat({ n, l, accent, tip }) {
  return <div className={`stat ${accent ? 'accent' : ''}`} data-tip={tip}><b>{n}</b><span>{l}</span></div>
}

function Segmented({ value, onChange, options }) {
  return (
    <div className="seg">
      {options.map(([v, label, title]) => (
        <button key={v} data-tip={title} className={value === v ? 'on' : ''} onClick={() => onChange(v)}>{label}</button>
      ))}
    </div>
  )
}
