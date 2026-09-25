# Download Manager (omarchy)

<img width="458" height="409" alt="download-manager" src="https://github.com/user-attachments/assets/8c30a539-4cc6-4734-b87c-8e620c85a8df" />

An IDM-style download manager for the Omarchy bar: download files directly from
a button in the top bar or from the CLI.

- **Engine**: aria2 (multi-connection, resume, pause)
- **Control**: bar widget panel and the `omarchy-dl` CLI
- **Queue**: parallel slots, pause/resume, retry, speed limits
- **Persistent**: queue is stored on disk and survives shell/PC restarts

## Dependencies

- `aria2c` (required). Install it with:

  ```
  omarchy pkg add aria2
  ```

  If it is missing, the panel shows an *aria2 is not installed* banner with an
  **Install** button. That button runs `omarchy pkg add aria2` through `pkexec`,
  so your desktop asks for your password once (polkit). Installing aria2 is the
  only thing in this plugin that needs elevated privileges — everything else
  runs as your normal user.

- `gawk` and `python3` (required, already on Omarchy). `gawk` parses aria2's
  progress lines and `python3` backs the `omarchy-dl` CLI. Both ship with the
  base system — `gawk` is a hard dependency of `pacman` — so there is normally
  nothing to install. If a download sits in *active* with no progress bar and no
  speed, check them with `command -v gawk python3`. The transfer itself keeps
  running in that case: only the progress readout depends on `gawk`.

- `libnotify` (optional). Desktop notifications on download complete/failure;
  skipped silently when `notify-send` is missing.

## Installation

Install this repository like any other Omarchy plugin:

```
omarchy plugin add https://github.com/wicky14/omarchy-download-manager.git --enable
```

An interactive prompt is used for confirmation; `--enable` activates it
immediately. `omarchy plugin add` rejects duplicates (id
`omakid.download-manager`).

Once active, a download icon `` appears in the bar: left-click opens the
panel, right-click pauses/resumes all.

## Usage

### Panel (bar widget)

1. Paste a direct URL (http/https) into the field at the top, click **Add**.
2. The destination folder is the `defaultDir` setting (`~/Downloads`); there is
   no folder picker in the panel — override the destination per download with
   the CLI `--dir` option.
3. Adjust **Slots** (number of parallel downloads), **Segments** (connections
   per file), and **Speed Limit** with the sliders below the form.
4. Each row shows the file name, progress bar, percentage, meta
   (speed/ETA), and status-dependent action buttons:
   - *active*: pause / cancel
   - *paused*: resume / cancel
   - *queued*: cancel
   - *done*: open folder / remove
   - *failed / canceled*: retry / remove
5. The footer shows a summary of final-state entries; clear them per row with
   the ✕ remove button or all at once with `omarchy-dl clear`.
6. The **MB/s** ⇄ **Mb/s** button in the footer right switches every displayed
   speed between bytes (`11,0 MB/s`, base 1024) and bits (`92,3 Mb/s`, base
   1000 — the unit ISPs advertise). It affects display only; the limit itself
   is always stored in bytes per second, and the choice persists in
   `queue.json`.

### CLI (`omarchy-dl`)

The `~/.local/bin/omarchy-dl` symlink is created automatically by the service
when the plugin runs. Commands:

```
omarchy-dl "https://example.com/file.iso"              # add to queue
omarchy-dl "https://example.com/a.iso" --dir ~/ISO      # destination folder
omarchy-dl "https://example.com/a.iso" --segments 8 --speed 500
omarchy-dl list                                        # list the queue
omarchy-dl pause <id> | resume <id> | cancel <id> | retry <id>
omarchy-dl open <id>                                   # open folder of a finished file
omarchy-dl clear                                       # clear final-state entries
```

`--speed` is always in **KB/s** (`--speed 500` = 500 KB/s = 4 Mb/s), independent
of the unit shown in the panel.

The symlink is only created when that name is free. If something else already
occupies `~/.local/bin/omarchy-dl`, the plugin leaves it alone and skips the
link — run `dm-cli.sh` from the plugin folder directly instead.

## Architecture

```
BarWidget.qml       Button + panel (KeyboardPanel). UI only; state comes from the service.
DownloadService.qml Owns the queue + settings, slot scheduler, CLI watcher.
dm-dl.sh            Per-download wrapper: spawns detached aria2c (setsid), parses
                    summaries via dm-status.awk, writes status.json atomically, sends
                    notifications via notify-send. pause/resume = SIGSTOP/SIGCONT.
dm-status.awk       gawk parser for aria2c summary lines
                    ([#gid done/tot(pct%) CN:n DL:speed ETA:...]).
dm-cli.sh           CLI front-end; only writes requests to cli.jsonl.
uninstall.sh        Full interactive uninstall.
```

### Event flow (race-free)

- The CLI does **not** write the queue file; it appends one JSON (op) line to
  `$XDG_RUNTIME_DIR/omarchy-download-manager/cli.jsonl`.
- The service tails that file every 2 seconds, executes the ops, and is the
  sole writer of `queue.json`.
- Progress summaries are written by `dm-dl.sh` to
  `$XDG_RUNTIME_DIR/omarchy-download-manager/<id>.status.json` (tmp+mv atomic);
  the service reads them whole per poll.

### Resume & restart

- `aria2c` runs with `--continue=true` and a `.aria2` control file in the
  destination folder; pausing the shell does not cancel progress.
- The wrapper is detached (`setsid`) so it survives an `omarchy restart shell`.
  After a shell or PC restart, boot reconciliation marks `paused`/`active`
  entries that lost their wrapper as `error` with "retry to continue" — click
  **retry** (or `retry <id>`) and aria2 resumes from the saved `.aria2` control
  file at the exact byte offset.

## Storage

| Thing | Location |
| --- | ------ |
| Queue & settings | `~/.config/omarchy/omakid.download-manager/queue.json` |
| Per-download status | `$XDG_RUNTIME_DIR/omarchy-download-manager/*.status.json` |
| Wrapper / aria2 pids | `$XDG_RUNTIME_DIR/omarchy-download-manager/*.pid` |
| CLI requests | `.../cli.jsonl` |
| CLI symlink | `~/.local/bin/omarchy-dl` |

## Uninstall

Remove the plugin only (folder + bar entry) safely:

```
omarchy plugin remove omakid.download-manager
```

Full uninstall (stops downloads, removes runtime + config + CLI symlink, then
removes the plugin):

```
./uninstall.sh
```

## Development

Validate the structure before installing:

```
omarchy plugin validate /path/to/repo
```

Install from a folder for quick testing:

```
omarchy plugin add file:///path/to/repo --enable --yes
```

Remove the plugin (folder + bar entry), then restart the shell to clear any
loaded state:

```
omarchy plugin remove omakid.download-manager
omarchy restart shell
```

## License

MIT &copy; 2026 omakid
