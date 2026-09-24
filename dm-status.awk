# dm-status.awk - parses aria2c periodic summary lines and writes one JSON
# status file per download. Invoked by dm-dl.sh as:
#
#   gawk -v id=<id> -v out=<status.json> -v dir=<dir> -v file=<name> \
#        -f dm-status.awk
#
# Fed the combined stdout+stderr of a single aria2c process on stdin.
# Every matching summary line is written atomically (tmp+mv) to <out>.

function jesc(s) {
  gsub(/\\/, "\\\\", s)
  gsub(/"/, "\\\"", s)
  return s
}

function tobytes(n, u) {
  u = toupper(substr(u, 1, 1))
  if (u == "K") n *= 1024
  else if (u == "M") n *= 1024 * 1024
  else if (u == "G") n *= 1024 * 1024 * 1024
  else if (u == "T") n *= 1024 * 1024 * 1024 * 1024
  return n
}

function etasec(s) {
  if (s == "--" || s == "-" || s == "" || s == "?") return -1
  h = 0; mm = 0; sec = 0
  if (match(s, /([0-9]+)h/)) h = substr(s, RSTART, RLENGTH - 1) + 0
  if (match(s, /([0-9]+)m/)) mm = substr(s, RSTART, RLENGTH - 1) + 0
  if (match(s, /([0-9]+)s/)) sec = substr(s, RSTART, RLENGTH - 1) + 0
  return h * 3600 + mm * 60 + sec
}

/^\[#/ {
  line = $0
  # [#gid done<unit>B/total<unit>B(pct%) CN:n DL:speed B ETA:x]
  if (!match(line, /^\[#([0-9a-fA-F]+) ([0-9.]+)([a-zA-Z]*)?i?B\/([0-9.]+)([a-zA-Z]*)?i?B\(([0-9?]+)%\) CN:[0-9]+ DL:([0-9.]+)([a-zA-Z]*)[^ ]* ETA:([^\]]+)\]/, cap)) next

  done = tobytes(cap[2] + 0, cap[3])
  total = tobytes(cap[4] + 0, cap[5])
  pct = (cap[6] == "?" || cap[6] == "") ? -1 : cap[6] + 0
  spd = tobytes(cap[7] + 0, cap[8])
  eta = etasec(cap[9])

  json = sprintf("{\"id\":\"%s\",\"state\":\"active\",\"completed\":%d,\"total\":%d,\"percent\":%d,\"speed\":%d,\"eta\":%d,\"dir\":\"%s\",\"file\":\"%s\",\"ts\":%d}", jesc(id), done, total, pct, spd, eta, jesc(dir), jesc(file), systime())

  outtmp = out ".tmp"
  printf "%s\n", json > outtmp
  close(outtmp)
  system("mv -f " outtmp " " out)
}