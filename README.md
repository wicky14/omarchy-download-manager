# Download Manager (omarchy)

An IDM-style download manager for the Omarchy bar: download files directly from
a button in the top bar, from the CLI, or via clipboard URL detection.

- **Engine**: aria2 (multi-connection, resume, pause)
- **Control**: bar widget panel, `omarchy-dl` CLI, clipboard watcher
- **Queue**: parallel slots, pause/resume, retry, speed limits
- **Persistent**: queue is stored on disk and survives shell/PC restarts

## Dependencies

- `aria2c` (required). Install it with:

  ```
  omarchy pkg add aria2
  ```

- `wl-paste` from the `wl-clipboard` package (for clipboard URL detection).
- `gdbus` from the `glib2` package (for the portal folder picker).

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
2. Choose the destination folder with the folder button (system portal); the
   default is taken from the `defaultDir` setting (`~/Downloads`).
3. Adjust **Slots** (number of parallel downloads), **Segments** (connections
   per file), and **Speed Limit** with the sliders below the form.
4. If a URL is copied while the clipboard watcher is active, a "URL FROM
   CLIPBOARD" block appears with **Add** / close buttons.
5. Each row shows the file name, progress bar, percentage, meta
   (speed/ETA), and status-dependent action buttons:
   - *active*: pause / cancel
   - *paused*: resume / cancel
   - *queued*: cancel
   - *done*: open folder / remove
   - *failed / canceled*: retry / remove
6. The footer shows a summary and a **Clear** button to remove all entries in
   a final state.

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

## Architecture

```
BarWidget.qml       Button + panel (KeyboardPanel). UI only; state comes from the service.
DownloadService.qml Owns the queue + settings, slot scheduler, CLI/clipboard watchers.
dm-dl.sh            Per-download wrapper: spawns detached aria2c (setsid), parses
                    summaries via dm-status.awk, writes status.json atomically, sends
                    notifications via notify-send. pause/resume = SIGSTOP/SIGCONT.
dm-status.awk       gawk parser for aria2c summary lines
                    ([#gid done/tot(pct%) CN:n DL:speed ETA:...]).
clipwatch.sh        wl-paste --watch -> clipboard.jsonl (in the runtime dir).
folderpick.sh       Folder picker via xdg-desktop-portal (gdbus).
dm-cli.sh           CLI front-end; only writes requests to cli.jsonl.
uninstall.sh        Full interactive uninstall.
```

### Event flow (race-free)

- The CLI does **not** write the queue file; it appends one JSON (op) line to
  `$XDG_RUNTIME_DIR/omarchy-download-manager/cli.jsonl`.
- The service tails that file every 2 seconds, executes the ops, and is the
  sole writer of `queue.json`. The clipboard watcher writes `clipboard.jsonl`;
  the service only shows an "Add?" prompt in the panel.
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
| CLI requests | `.../cli.jsonl` · clipboard `.../clipboard.jsonl` |
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