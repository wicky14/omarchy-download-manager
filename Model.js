// Model.js - pure helpers for the Download Manager plugin.
// Kept transport-free so both QML and the shell scripts can agree on formats.

function clamp(v, min, max) {
  var n = Number(v)
  if (!isFinite(n)) return Number(min)
  return Math.max(Number(min), Math.min(Number(max), n))
}

function fmt(n, decimals) {
  var d = decimals === undefined ? 1 : decimals
  var s = n.toFixed(d)
  return s.replace(".", ",")
}

function formatBytes(bytes) {
  var n = Number(bytes)
  if (!isFinite(n) || n < 0) return "?"
  if (n < 1024) return Math.round(n) + " B"
  var units = ["KB", "MB", "GB", "TB"]
  var v = n
  var i = -1
  do {
    v = v / 1024
    i++
  } while (v >= 1024 && i < units.length - 1)
  return fmt(v) + " " + units[i]
}

function formatSpeed(bps) {
  var n = Number(bps)
  if (!isFinite(n) || n <= 0) return ""
  return formatBytes(n) + "/s"
}

function formatEta(sec) {
  var s = Number(sec)
  if (!isFinite(s) || s < 0) return ""
  s = Math.round(s)
  var h = Math.floor(s / 3600)
  var m = Math.floor((s % 3600) / 60)
  var r = s % 60
  if (h > 0) return h + "h " + m + "m"
  return m + ":" + (r < 10 ? "0" : "") + r
}

function percent(completed, total) {
  var done = Number(completed)
  var tot = Number(total)
  if (!isFinite(done) || !isFinite(tot) || tot <= 0) return -1
  if (done >= tot) return 100
  return Math.floor((done / tot) * 100)
}

function isValidUrl(s) {
  var str = String(s || "").trim()
  return /^https?:\/\/\S+$/i.test(str)
}

function deriveFilename(url) {
  var u = String(url || "").trim()
  var clean = u.split("#")[0].split("?")[0]
  var parts = clean.split("/")
  var last = parts[parts.length - 1] || ""
  try {
    last = decodeURIComponent(last)
  } catch (e) {}
  last = last.replace(/^[<>:"/\\|?*]+$/, "").trim()
  return last || "download"
}

function makeId() {
  var hex = "0123456789abcdef"
  var out = ""
  for (var i = 0; i < 16; i++) out += hex[Math.floor(Math.random() * 16)]
  return out
}

function normalizeDir(dir, home) {
  var d = String(dir || "").trim()
  if (!d) return String(home || "~/Downloads")
  if (d === "~") return String(home || "")
  if (d.indexOf("~/") === 0) return (home || "~") + d.slice(1)
  return d
}

function sameUrl(a, b) {
  return String(a || "").replace(/^https?:\/\//i, "").replace(/\/+$/, "") ===
    String(b || "").replace(/^https?:\/\//i, "").replace(/\/+$/, "")
}

function hasUrl(downloads, candidate) {
  for (var i = 0; i < downloads.length; i++) {
    if (sameUrl(downloads[i].url, candidate)) return true
  }
  return false
}

function hasActiveUrl(downloads, candidate) {
  for (var i = 0; i < downloads.length; i++) {
    if (!isFinal(downloads[i].state) && sameUrl(downloads[i].url, candidate)) return true
  }
  return false
}

function popMatchDelay(list) {
  // Returns a small delay so dismissed clipboard urls stay gone for a while.
  return null
}

function entryState(entry) {
  return entry && entry.state ? entry.state : "queued"
}

function isFinal(state) {
  return state === "completed" || state === "error" || state === "cancelled"
}

function describe(entry, status) {
  var state = entryState(entry)
  var p = status ? percent(status.completed, status.total) : -1
  var done = status ? Number(status.completed) : 0
  var total = status ? Number(status.total) : 0
  if (state === "active") {
    var speed = status && status.speed ? formatSpeed(status.speed) : ""
    var conn = status && Number(status.conn) > 0 ? Number(status.conn) : 0
    var parts = []
    if (p >= 0) parts.push(formatBytes(done) + " / " + formatBytes(total))
    else parts.push(formatBytes(done))
    if (speed) parts.push(speed)
    if (conn > 0) parts.push(conn + " conn")
    if (status && status.eta > 0) parts.push(formatEta(status.eta))
    return parts.join(" \u00b7 ")
  }
  if (state === "paused") {
    if (p >= 0) return "paused \u00b7 " + formatBytes(done) + " / " + formatBytes(total)
    return "paused"
  }
  if (state === "queued") return "queued (slots full)"
  if (state === "completed") return "Done \u00b7 " + (total > 0 ? formatBytes(total) : formatBytes(done))
  if (state === "cancelled") return "Canceled"
  if (state === "error") return "Failed" + (entry.error ? ": " + entry.error : "")
  return state
}

function statusIcon(state) {
  if (state === "active") return "\uf019"
  if (state === "paused") return "\uf04c"
  if (state === "queued") return "\uf1e0"
  if (state === "completed") return "\uf058"
  if (state === "cancelled") return "\uf00d"
  if (state === "error") return "\uf071"
  return "\uf019"
}

if (typeof module !== "undefined") {
  module.exports = {
    clamp: clamp,
    formatBytes: formatBytes,
    formatSpeed: formatSpeed,
    formatEta: formatEta,
    percent: percent,
    isValidUrl: isValidUrl,
    deriveFilename: deriveFilename,
    makeId: makeId,
    normalizeDir: normalizeDir,
    sameUrl: sameUrl,
    hasUrl: hasUrl,
    hasActiveUrl: hasActiveUrl,
    isFinal: isFinal,
    describe: describe,
    statusIcon: statusIcon
  }
}