import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root

  property var shell: null
  property string moduleName: "omakid.download-manager"
  property var manifest: null

  // ---------- paths ----------
  readonly property string home: Quickshell.env("HOME")
  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config")
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") + "/omarchy-download-manager"
  readonly property string configDir: configHome + "/omarchy/omakid.download-manager"
  readonly property string queuePath: configDir + "/queue.json"

  readonly property string dmScript: decodeURIComponent(
    Qt.resolvedUrl("dm-dl.sh").toString().replace(/^file:\/\//, ""))
  readonly property string cliScript: decodeURIComponent(
    Qt.resolvedUrl("dm-cli.sh").toString().replace(/^file:\/\//, ""))
  readonly property string cliBin: home + "/.local/bin/omarchy-dl"

  // ---------- state ----------
  property var downloads: []
  property var statuses: ({})
  property var settings: ({ defaultDir: "~/Downloads", maxConcurrent: 3, segments: 8, speedLimit: 0 })
  property var pendingClipboard: []
  property bool ready: false
  property bool aria2Missing: true
  property bool _ariaNotified: false
  property bool _persistPending: false
  property var _spawnQueue: []

  // ---------- aggregates ----------
  readonly property int activeCount: _count("active")
  readonly property int pausedCount: _count("paused")
  readonly property int queuedCount: _count("queued")
  readonly property int completedCount: _count("completed")
  readonly property int errorCount: _count("error")
  readonly property int cancelledCount: _count("cancelled")
  readonly property real totalSpeed: {
    var sum = 0
    var now = Date.now()
    for (var i = 0; i < root.downloads.length; i++) {
      var e = root.downloads[i]
      if (e.state !== "active") continue
      var s = root.statuses[e.id]
      if (s && s.speed > 0 && now - (s.ts * 1000) < 30000) sum += s.speed
    }
    return sum
  }

  function _count(state) {
    var n = 0
    for (var i = 0; i < root.downloads.length; i++) {
      if (root.downloads[i].state === state) n++
    }
    return n
  }

  function progressFor(id) {
    return root.statuses[id] || null
  }

  function entryById(id) {
    for (var i = 0; i < root.downloads.length; i++) {
      if (root.downloads[i].id === id) return root.downloads[i]
    }
    return null
  }

  // ---------- persistence ----------
  function persist() {
    root._persistPending = false
    var q = { settings: root.settings, downloads: root.downloads }
    writeProc.content = JSON.stringify(q) + "\n"
    writeProc.running = true
  }

  function loadQueue() {
    readQueueProc.running = true
  }

  function ensureDirs() {
    mkdirProc.running = true
  }

  // ---------- mutators ----------
  function addUrl(url, dir, segments, speed) {
    var u = String(url || "").trim()
    if (!Model.isValidUrl(u)) return false
    if (Model.hasUrl(root.downloads, u)) return false

    var d = Model.normalizeDir(dir || root.settings.defaultDir, root.home)
    var seg = Number(segments || 0) > 0 ? Model.clamp(segments, 1, 16) : Model.clamp(root.settings.segments, 1, 16)
    var spd = Number(speed || 0) >= 0
      ? Model.clamp(speed, 0, 1073741824)
      : Model.clamp(root.settings.speedLimit, 0, 1073741824)

    var filename = Model.deriveFilename(u)
    var dot = filename.lastIndexOf(".")
    var base = (dot > 0) ? filename.slice(0, dot) : filename
    var ext = (dot > 0) ? filename.slice(dot) : ""
    var i = 1
    while (root._filenameTaken(d, filename)) {
      i++
      filename = base + " (" + i + ")" + ext
      if (i > 100) { filename = base + "." + Date.now() + ext; break }
    }

    var entry = {
      id: Model.makeId(),
      url: u,
      dir: d,
      filename: filename,
      segments: seg,
      speedLimit: spd,
      state: "queued",
      addedAt: Date.now(),
      completedAt: 0,
      error: "",
      totalBytes: 0
    }
    root.downloads = root.downloads.concat([entry])
    root.persist()
    root.sweep()
    return true
  }

  function _filenameTaken(dir, filename) {
    for (var i = 0; i < root.downloads.length; i++) {
      var e = root.downloads[i]
      if (e.dir === dir && e.filename === filename && !Model.isFinal(e.state)) return true
    }
    return false
  }

  function _pumpSpawn() {
    if (spawnProc.running) return
    if (!root._spawnQueue || root._spawnQueue.length === 0) return
    var entry = root._spawnQueue.splice(0, 1)[0]
    root._setState(entry.id, "active", false)
    root._persistPending = true
    spawnProc.command = [
      "bash", root.dmScript, "start",
      entry.id, entry.url, entry.dir, entry.filename,
      String(entry.segments), String(entry.speedLimit)
    ]
    spawnProc.running = true
  }

  function sweep() {
    var slots = Number(root.settings.maxConcurrent) || 3
    var count = root.activeCount
    var pending = []
    for (var i = 0; i < root.downloads.length && count < slots; i++) {
      var e = root.downloads[i]
      if (e.state === "queued") { pending.push(e); count++ }
    }
    root._spawnQueue = pending
    root._pumpSpawn()
  }

  function _setState(id, state, persistNow) {
    var e = root.entryById(id)
    if (!e || e.state === state) return
    var next = []
    for (var i = 0; i < root.downloads.length; i++) {
      var d = root.downloads[i]
      if (d.id === id) {
        var copy = JSON.parse(JSON.stringify(d))
        copy.state = state
        if (state === "completed") copy.completedAt = Date.now()
        if (state === "queued") copy.completedAt = 0
        next.push(copy)
      } else {
        next.push(d)
      }
    }
    root.downloads = next
    if (persistNow !== false) root.persist()
  }

  function _setError(id, message) {
    var e = root.entryById(id)
    if (!e) return
    var next = []
    for (var i = 0; i < root.downloads.length; i++) {
      var d = root.downloads[i]
      if (d.id === id) {
        var copy = JSON.parse(JSON.stringify(d))
        copy.state = "error"
        copy.error = message || "terhenti"
        next.push(copy)
      } else {
        next.push(d)
      }
    }
    root.downloads = next
    root.persist()
  }

  function pause(id) {
    var e = root.entryById(id)
    if (!e || e.state !== "active") return
    _setState(id, "paused", false)
    _runDm(["pause", id])
    root._persistPending = true
    root.sweep()
  }

  function resume(id) {
    var e = root.entryById(id)
    if (!e || e.state !== "paused") return
    _setState(id, "active", false)
    _runDm(["resume", id])
    root._persistPending = true
  }

  function cancel(id) {
    var e = root.entryById(id)
    if (!e || e.state === "completed" || e.state === "cancelled") return
    _setState(id, "cancelled", false)
    _runDm(["cancel", id])
    root._persistPending = true
  }

  function retry(id) {
    var e = root.entryById(id)
    if (!e) return
    if (e.state !== "error" && e.state !== "cancelled") return
    var next = []
    for (var i = 0; i < root.downloads.length; i++) {
      var d = root.downloads[i]
      if (d.id === id) {
        var copy = JSON.parse(JSON.stringify(d))
        copy.error = ""
        copy.state = "queued"
        next.push(copy)
      } else {
        next.push(d)
      }
    }
    root.downloads = next
    root.persist()
    root.sweep()
  }

  function removeEntry(id) {
    root.removeById(id)
  }

  function removeById(id) {
    var next = []
    for (var i = 0; i < root.downloads.length; i++) {
      if (root.downloads[i].id !== id) next.push(root.downloads[i])
    }
    root.downloads = next
    root.persist()
    _runDm(["cancel", id])
  }

  function clearFinished() {
    var next = []
    for (var i = 0; i < root.downloads.length; i++) {
      var d = root.downloads[i]
      if (Model.isFinal(d.state)) continue
      next.push(d)
    }
    root.downloads = next
    root.persist()
  }

  function open(id) {
    var e = root.entryById(id)
    if (!e) return
    openProc.command = ["bash", "-c", 'xdg-open "$1"', "dm-open", e.dir]
    openProc.running = true
  }

  function toggleAll() {
    var active = []
    for (var i = 0; i < root.downloads.length; i++) {
      if (root.downloads[i].state === "active") active.push(root.downloads[i].id)
    }
    if (active.length > 0) {
      for (var j = 0; j < active.length; j++) root.pause(active[j])
      return
    }
    for (var k = 0; k < root.downloads.length; k++) {
      if (root.downloads[k].state === "paused") root.resume(root.downloads[k].id)
    }
  }

  function _runDm(args) {
    actProc.command = ["bash", root.dmScript].concat(args)
    actProc.running = true
  }

  // ---------- settings ----------
  function setMaxConcurrent(n) {
    var s = JSON.parse(JSON.stringify(root.settings))
    s.maxConcurrent = Model.clamp(n, 1, 16)
    root.settings = s
    root.persist()
    root.sweep()
  }

  function setSegments(n) {
    var s = JSON.parse(JSON.stringify(root.settings))
    s.segments = Model.clamp(n, 1, 16)
    root.settings = s
    root.persist()
  }

  function setSpeedLimit(bytesPerSec) {
    var s = JSON.parse(JSON.stringify(root.settings))
    s.speedLimit = Model.clamp(bytesPerSec, 0, 1073741824)
    root.settings = s
    root.persist()
  }

  function setDefaultDir(d) {
    var s = JSON.parse(JSON.stringify(root.settings))
    s.defaultDir = Model.normalizeDir(d, root.home)
    root.settings = s
    root.persist()
  }

  // ---------- clipboard ----------
  function applyClipboard(url) {
    var idx = -1
    for (var i = 0; i < root.pendingClipboard.length; i++) {
      if (Model.sameUrl(root.pendingClipboard[i].url, url)) { idx = i; break }
    }
    if (idx < 0) return
    var ok = root.addUrl(url)
    if (ok) root.dismissClipboard(url)
  }

  function dismissClipboard(url) {
    var next = []
    for (var i = 0; i < root.pendingClipboard.length; i++) {
      if (!Model.sameUrl(root.pendingClipboard[i].url, url)) next.push(root.pendingClipboard[i])
    }
    root.pendingClipboard = next
  }

  function _pushClipboard(url) {
    if (Model.hasUrl(root.downloads, url)) return
    for (var i = 0; i < root.pendingClipboard.length; i++) {
      if (Model.sameUrl(root.pendingClipboard[i].url, url)) return
    }
    var next = root.pendingClipboard.concat([{ url: url, time: Date.now() }])
    while (next.length > 5) next.shift()
    root.pendingClipboard = next
  }

  // ---------- cli requests ----------
  function handleRequest(req) {
    if (!req || !req.op) return
    switch (req.op) {
      case "add":
        root.addUrl(
          req.url || "",
          req.dir || "",
          req.segments ? Number(req.segments) : 0,
          req.speed ? Number(req.speed) * 1024 : 0)
        break
      case "pause": root.pause(req.id); break
      case "resume": root.resume(req.id); break
      case "cancel": root.cancel(req.id); break
      case "retry": root.retry(req.id); break
      case "open": root.open(req.id); break
      case "clear": root.clearFinished(); break
    }
  }

  // ---------- reconcile on boot ----------
  function reconcile() {
    bootReconProc.running = true
  }

  function onBootRecon(lines) {
    var alive = {}
    var parts = String(lines || "").trim().split("\n")
    for (var i = 0; i < parts.length; i++) {
      var p = parts[i].trim()
      if (!p) continue
      var sp = p.split(" ")
      if (sp.length >= 3 && sp[0] === "W") alive[sp[1]] = (sp[2] === "1")
    }
    var changed = false
    for (var j = 0; j < root.downloads.length; j++) {
      var e = root.downloads[j]
      if (e.state !== "active" && e.state !== "paused") continue
      if (alive[e.id] === true) continue
      root._setError(e.id, "terhenti saat restart \u2014 retry untuk melanjutkan")
      changed = true
    }
    if (changed) root.persist()
    root.sweep()
  }

  // ---------- poll: statuses + alive ----------
  function pollStatuses() {
    statusProc.running = true
  }

  function onStatusOutput(lines) {
    var text = String(lines || "")
    var blockLines = text.split("\n")
    var status = {}
    var alive = {}
    var now = Date.now()
    for (var i = 0; i < blockLines.length; i++) {
      var line = blockLines[i]
      if (!line) continue
      if (line.indexOf("S ") === 0) {
        var sp = line.slice(2)
        var gap = sp.indexOf(" ")
        var id = sp.slice(0, gap)
        var json = sp.slice(gap + 1)
        try {
          var obj = JSON.parse(json)
          status[obj.id] = obj
        } catch (e) {}
        continue
      }
      if (line.indexOf("W ") === 0) {
        var wp = line.split(" ")
        if (wp.length >= 3) alive[wp[1]] = (wp[2] === "1")
      }
    }

    // replace statuses map atomically
    var merged = {}
    for (var sid in root.statuses) {
      if (status[sid]) merged[sid] = status[sid]
    }
    for (var sid2 in status) merged[sid2] = status[sid2]
    root.statuses = merged

    // apply transitions + propagate total bytes
    var changed = false
    for (var k = 0; k < root.downloads.length; k++) {
      var e = root.downloads[k]
      if (e.state !== "active") continue
      var st = status[e.id]
      var isAlive = (alive[e.id] === true)
      if (st && st.state === "completed") {
        root._setState(e.id, "completed", false)
        changed = true
      } else if (st && st.state === "cancelled") {
        root._setState(e.id, "cancelled", false)
        changed = true
      } else if (st && st.state === "error") {
        root._setError(e.id, st.error || "gagal")
        changed = true
      } else if (st && st.state === "active" && !isAlive && now - (st.ts * 1000) > 20000) {
        root._setError(e.id, "terhenti \u2014 retry untuk melanjutkan")
        changed = true
      }
      if (st && st.ts) {
        var ee = root.entryById(e.id)
        if (ee && ee.state === "active" && st.total > 0 && ee.totalBytes !== st.total) {
          var next = []
          for (var m = 0; m < root.downloads.length; m++) {
            var dd = root.downloads[m]
            if (dd.id === e.id) {
              var c = JSON.parse(JSON.stringify(dd))
              c.totalBytes = st.total
              next.push(c)
            } else next.push(dd)
          }
          root.downloads = next
        }
      }
    }
    if (changed) root.persist()
    root.sweep()
  }

  // ---------- events: cli + clipboard ----------
  function pollEvents() {
    eventsProc.running = true
  }

  function onEventsOutput(lines) {
    var text = String(lines || "")
    var section = ""
    var rows = text.split("\n")
    for (var i = 0; i < rows.length; i++) {
      var line = rows[i]
      if (line === "===CLI===") { section = "cli"; continue }
      if (line === "===CLIP===") { section = "clip"; continue }
      if (!line) continue
      if (section === "cli") {
        try { root.handleRequest(JSON.parse(line)) } catch (e) {}
      } else if (section === "clip") {
        try {
          var obj = JSON.parse(line)
          if (obj.url && Model.isValidUrl(obj.url)) root._pushClipboard(obj.url)
        } catch (e) {}
      }
    }
  }

  // ---------- notify ----------
  function notify(title, body) {
    notifProc.command = ["notify-send", "-a", "Download Manager", title, body]
    notifProc.running = true
  }

  // ---------- helpers ----------
  function ensureCliSymlink() {
    symlinkProc.running = true
  }

  function checkAria() {
    ariaProc.running = true
  }

  function _flushPending() {
    if (root._persistPending) root.persist()
  }

  // ---------- shell scripts for polling ----------
  readonly property string _statusScript: "\n" +
    '  rt="$1"\n' +
    '  for f in "$rt"/*.status.json; do\n' +
    '    [ -f "$f" ] || continue\n' +
    '    id=${f##*/}; id=${id%.status.json}\n' +
    '    printf "S %s " "$id"\n' +
    '    tr -d "\\n" < "$f"\n' +
    '    printf "\\n"\n' +
    '  done\n' +
    '  for f in "$rt"/*.wrapper.pid; do\n' +
    '    [ -f "$f" ] || continue\n' +
    '    id=${f##*/}; id=${id%.wrapper.pid}\n' +
    '    alive=0\n' +
    '    kill -0 "$(cat "$f")" 2>/dev/null && alive=1\n' +
    '    printf "W %s %s\\n" "$id" "$alive"\n' +
    '  done\n'

  readonly property string _reconScript: "\n" +
    '  rt="$1"\n' +
    '  for f in "$rt"/*.wrapper.pid; do\n' +
    '    [ -f "$f" ] || continue\n' +
    '    id=${f##*/}; id=${id%.wrapper.pid}\n' +
    '    alive=0\n' +
    '    kill -0 "$(cat "$f")" 2>/dev/null && alive=1\n' +
    '    printf "W %s %s\\n" "$id" "$alive"\n' +
    '  done\n'

  readonly property string _eventsScript: "\n" +
    '  rt="$1"\n' +
    '  if [ -f "$rt/cli.jsonl" ]; then\n' +
    '    echo "===CLI==="\n' +
    '    cat "$rt/cli.jsonl"\n' +
    '    : > "$rt/cli.jsonl"\n' +
    '  fi\n' +
    '  if [ -f "$rt/clipboard.jsonl" ]; then\n' +
    '    echo "===CLIP==="\n' +
    '    cat "$rt/clipboard.jsonl"\n' +
    '    : > "$rt/clipboard.jsonl"\n' +
    '  fi\n'

  // ---------- Processes ----------
  Process {
    id: mkdirProc
    command: ["bash", "-c", 'mkdir -p "$1" "$2"', "dm-mkdir", root.runtimeDir, root.configDir]
    onExited: function(code) { root.loadQueue() }
  }

  Process {
    id: readQueueProc
    command: ["bash", "-c", 'cat "$1" 2>/dev/null || :', "dm-read", root.queuePath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var q = JSON.parse(text || "{}")
          if (q.settings && typeof q.settings === "object") root.settings = q.settings
          if (Array.isArray(q.downloads)) root.downloads = q.downloads
        } catch (e) {}
        root.ready = true
        root.reconcile()
      }
    }
  }

  Process {
    id: writeProc
    property string content: ""
    command: ["bash", "-c", 'mkdir -p "$1" && cat > "$2"', "dm-write", root.configDir, root.queuePath]
    stdinEnabled: true
    onStarted: function() {
      writeProc.write(writeProc.content)
    }
  }

  Process {
    id: bootReconProc
    command: ["bash", "-c", root._reconScript, "dm-recon", root.runtimeDir]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { root.onBootRecon(text) }
    }
  }

  Process {
    id: statusProc
    command: ["bash", "-c", root._statusScript, "dm-status", root.runtimeDir]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { root.onStatusOutput(text) }
    }
  }

  Process {
    id: eventsProc
    command: ["bash", "-c", root._eventsScript, "dm-events", root.runtimeDir]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { root.onEventsOutput(text) }
    }
  }

  Process {
    id: spawnProc
    onExited: function(code) { root._pumpSpawn() }
  }

  Process {
    id: actProc
  }

  Process {
    id: openProc
  }

  Process {
    id: notifProc
  }

  Process {
    id: symlinkProc
    command: ["bash", "-c", 'mkdir -p "$(dirname "$2")"; ln -sfn "$1" "$2"', "dm-link", root.cliScript, root.cliBin]
  }

  Process {
    id: ariaProc
    command: ["bash", "-c", "command -v aria2c >/dev/null 2>&1"]
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      root.aria2Missing = (code !== 0)
      if (root.aria2Missing && !root._ariaNotified) {
        root._ariaNotified = true
        root.notify("Download Manager", "aria2 tidak terpasang \u2014 jalankan 'omarchy pkg add aria2'")
      }
    }
  }

  // ---------- timers ----------
  Timer {
    id: statusTimer
    interval: 2000
    running: root.ready
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.pollStatuses()
      root._flushPending()
    }
  }

  Timer {
    id: eventsTimer
    interval: 2000
    running: root.ready
    repeat: true
    triggeredOnStart: true
    onTriggered: root.pollEvents()
  }

  Component.onCompleted: {
    root.ensureDirs()
    root.checkAria()
    root.ensureCliSymlink()
  }
}