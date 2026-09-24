# Download Manager (omarchy)

Download manager ala IDM untuk bar Omarchy — unduh file langsung dari tombol di
top bar, CLI, atau deteksi URL dari clipboard.

- **Mesin**: aria2 (multi-koneksi, resume, pause)
- **Kontrol**: panel bar widget, CLI `omarchy-dl`, watcher clipboard
- **Antrean**: beberapa slot paralel, jeda/lanjut, retry, batas kecepatan
- **Persisten**: antrean tersimpan di disk, resume setelah restart shell/PC

## Dependensi

- `aria2c` (wajib). Pasang lewat:

  ```
  omarchy pkg add aria2
  ```

- `wl-paste` dari paket `wl-clipboard` (untuk deteksi URL clipboard).
- `gdbus` dari paket `glib2` (untuk pemilih folder via portal).

## Pemasangan

Repositori ini dipasang seperti plugin Omarchy lain:

```
omarchy plugin add <git-url-repo> --enable
```

Prompt interaktif dipakai untuk konfirmasi; `--enable` agar langsung aktif.
`omarchy plugin add` menolak duplikat (id `omakid.download-manager`).

Setelah aktif, tombol ikon unduh `` muncul di bar: klik kiri membuka panel,
klik kanan untuk jeda/lanjut semua.

## Penggunaan

### Panel (bar widget)

1. Tempel URL direct (http/https) di kolom paling atas, klik **Tambah**.
2. Pilih folder tujuan dengan tombol folder (portal system); nilai default
   diambil dari setelan `defaultDir` (`~/Downloads`).
3. Atur **Slot** (jumlah download berjalan), **Segmen** (koneksi per file), dan
   **Batas Kecepatan** lewat slider di bawah form.
4. Jika URL ter-copy saat clipboard watcher aktif, muncul blok "URL DARI
   KLIPBOARD" dengan tombol **Tambah** / tutup.
5. Setiap baris berisi nama file, progress bar, persen, meta (kecepatan/ETA),
   dan tombol aksi sesuai status:
   - *aktif*: jeda / batal
   - *dijeda*: lanjut / batal
   - *antre*: batal
   - *selesai*: buka folder / hapus
   - *gagal / batal*: coba lagi / hapus
6. Footer menampilkan ringkasan dan tombol **Bersihkan** untuk menghapus
   entri yang sudah berstatus akhir.

### CLI (`omarchy-dl`)

Symlink `~/.local/bin/omarchy-dl` dibuat otomatis oleh service saat plugin
dijalankan. Perintah:

```
omarchy-dl "https://contoh.com/file.iso"              # tambah ke antrean
omarchy-dl "https://contoh.com/a.iso" --dir ~/ISO      # folder tujuan
omarchy-dl "https://contoh.com/a.iso" --segments 8 --speed 500
omarchy-dl list                                        # daftar antrean
omarchy-dl pause <id> | resume <id> | cancel <id> | retry <id>
omarchy-dl open <id>                                   # buka folder file selesai
omarchy-dl clear                                       # bersihkan status akhir
```

## Arsitektur

```
BarWidget.qml       Tombol + panel (KeyboardPanel). Hanya UI, status dari service.
DownloadService.qml Pemilik antrean + setelan, penjadwal slot, watcher CLI/klip.
dm-dl.sh            Pembungkus satu download: spawn aria2c detached (setsid),
                    parse ringkasan via dm-status.awk, tulis status.json atomik,
                    notification via notify-send. pause/resume = SIGSTOP/SIGCONT.
dm-status.awk       Parser gawk untuk baris ringkasan aria2c
                    ([#gid done/tot(pct%) CN:n DL:speed ETA:...]).
clipwatch.sh        wl-paste --watch -> clipboard.jsonl (di runtime).
folderpick.sh       Pemilih folder via xdg-desktop-portal (gdbus).
dm-cli.sh           Front-end CLI; hanya menulis request ke cli.jsonl.
uninstall.sh        Uninstall lengkap interaktif.
```

### Alur event (tanpa race)

- CLI **tidak** menulis file antrean; ia menambah satu baris JSON (op) ke
  `$XDG_RUNTIME_DIR/omarchy-download-manager/cli.jsonl`.
- Service menge-tali file tersebut tiap 2 detik, mengeksekusi op, dan menulis
  `queue.json` (satu-satunya penulis). Watcher clipboard menulis
  `clipboard.jsonl`; service hanya menampilkan prompt "tambah?" di panel.
- Ringkasan kemajuan ditulis oleh `dm-dl.sh` ke
  `$XDG_RUNTIME_DIR/omarchy-download-manager/<id>.status.json` (tmp+mv atomik);
  service membacanya utuh per-poll.

### Resume & restart

- `aria2c` dijalankan dengan `--continue=true` dan file `.aria2` di folder
  tujuan; jeda di shell tidak membatalkan progress.
- Wrapper didetach (setsid) sehingga selamat dari restart shell/PC. Pada boot,
  service melakukan rekonsiliasi: entri `paused`/`active` yang tidak ada
  wrapper-nya ditandai `error` dengan pesan "retry untuk melanjutkan" —
  klik **coba lagi** (atau `retry <id>`) meneruskan dari posisi terhenti.

## Penyimpanan

| Hal | Lokasi |
| --- | ------ |
| Antrean & setelan | `~/.config/omarchy/omakid.download-manager/queue.json` |
| Status per download | `$XDG_RUNTIME_DIR/omarchy-download-manager/*.status.json` |
| Pid wrapper / aria2 | `$XDG_RUNTIME_DIR/omarchy-download-manager/*.pid` |
| Request CLI | `.../cli.jsonl` · clipboard `.../clipboard.jsonl` |
| Symlink CLI | `~/.local/bin/omarchy-dl` |

## Pencopotan

Hanya mencopot plugin (folder + entry bar) secara aman:

```
omarchy plugin remove omakid.download-manager
```

Uninstall penuh (memberhentikan download, menghapus runtime + konfigurasi +
symlink CLI, lalu mencopot plugin):

```
./uninstall.sh
```

## Pengembangan

Validasi struktur sebelum dipasang:

```
omarchy plugin validate /path/ke/repo-ini
```

Pasang dari folder untuk uji cepat:

```
omarchy plugin add file:///path/ke/repo-ini --enable --yes
```

Hapus plugin dari `~/.config/omarchy/plugins`, lalu `omarchy restart shell` —
entri bar ikut bersih (dicek via `PluginRegistry.setEnabled(false)`).

## Lisensi

MIT &copy; 2026 omakid