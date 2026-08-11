<div align="center">

<img src="assets/younzcode_logo_new.png" alt="YOUNZCODE" width="120"/>

# YOUNZCODE 🤖

**AI coding agent desktop untuk Windows.**

![Flutter](https://img.shields.io/badge/Flutter-3-0F766E?logo=flutter&logoColor=white&style=flat)
![Dart](https://img.shields.io/badge/Dart-^3.11-0175C2?logo=dart&logoColor=white&style=flat)
![Version](https://img.shields.io/badge/versi-1.3.7-16A34A?style=flat)
![Platform](https://img.shields.io/badge/Platform-Windows-0EA5E9?style=flat)
![Tests](https://img.shields.io/badge/test-33+%20file-16A34A?style=flat)

Agen AI native yang membaca, mencari, dan mengubah kode di workspace-mu —
menjalankan PowerShell, debugger, browser agent, MCP/add-on, checkpoint perubahan,
dan quality gate otomatis. Semua tindakan yang mengubah sistem **selalu meminta izin dulu**.

</div>

---

## ✨ Fitur

### 🖥️ Editor & Debugging
- **Syntax highlighting**, autocomplete lokal (`Ctrl+Space`), minimap, diagnostics dari toolchain bahasa, dan breakpoint gutter
- **Run/Debug console** dengan breakpoint & stepping nyata:
  - **Dart** — Debug Adapter Protocol bawaan SDK
  - **Python** — `debugpy`
  - **Node.js** — standalone DAP resmi Microsoft `js-debug` (disertakan di installer; lokasi alternatif via `YOUNZCODE_JS_DEBUG`)
- Kontrol: `F5` mulai/lanjut · `F10` step over · `F11` step into · `Shift+F11` step out

### 🤖 Agen AI
- **Multi-agent paralel** — `/agents tugas 1 | tugas 2` menjalankan beberapa agent pada branch & Git worktree terisolasi
- **Goal mode** — `/goal <tujuan>` menyimpan tujuan per chat dan menjalankan turn lanjutan otomatis sampai selesai atau terblokir; staged edit dipertahankan
- **Provider multi** — urutan fallback, retry/failover, harga token, anggaran bulanan, dan dashboard `/usage`
- Respons provider kosong dicoba ulang otomatis dengan mode transport alternatif
- **Model Settings** — API key dikirim sebelum Fetch, mengenali preset AgentRouter, detail autentikasi untuk HTTP 401

### 🧠 Code Intelligence
- **Hybrid**: pencarian istilah Indonesia/Inggris, symbol index, go-to-definition, references, dan autocomplete workspace
- **Checkpoint perubahan** tersimpan per workspace, dapat dipulihkan dari Inspector

### 🛡️ Keamanan
- **API key hanya di memori** selama aplikasi berjalan — base URL, model, dan workspace disimpan sebagai preferensi lokal
- File `.env` dan variannya berlabel **LOCAL ONLY** — agent AI tidak dapat membaca/mengubahnya
- **Secret scanner** & kebijakan izin per tool; tindakan berisiko (delete, submit, publish, login, upload) **wajib approval**
- **Workspace trust** — folder baru diminta persetujuan sebelum diakses

### 🔌 Add-on & MCP
- **Add-on Manager** — health check, latensi, log, dan kebijakan izin per tool MCP
- Mendukung skill, plugin, MCP, dan extension — lihat [ADDONS_GUIDE.md](ADDONS_GUIDE.md)

### 🖼️ Media & Browser
- **Agent Browser** (Microsoft Edge WebView2) — buka URL HTTPS / preview `localhost`, baca halaman, klik, ketik, upload file workspace, simpan screenshot
- **`/download URL`** — unduh media publik via yt-dlp dengan validasi URL, konfirmasi hak akses, progres, dan pembatalan
- **Lampiran chat** — baca Markdown, PDF, DOCX, dan XLSX
- **Image Studio** — generasi gambar berbasis AI

### 💾 Workspace & Git
- **Git Center** — status detail, stage/unstage, discard, commit, branch, merge/abort, push, dan pengelolaan worktree
- **Terminal persisten** untuk menjalankan perintah shell
- **Percakapan otomatis tersimpan** per workspace — `NEW CHAT` membuat sesi baru, menu `HISTORY` membuka/melanjutkan/menghapus (maks. 50 sesi terbaru)

### ⚙️ Quality Gate & Update
- **Quality gate otomatis** — menjalankan analyzer atau test relevan setelah perubahan diterima, menawarkan rollback bila gagal
- **Update service** — periksa pembaruan via `/update` atau tombol *CHECK FOR UPDATES* di Model Settings; manifest HTTPS + host allowlist + tanda tangan **Ed25519** + checksum **SHA-256**, installer diunduh dan diverifikasi sebelum dijalankan. Diagnostik update & penandatanganan (`/update-status` atau tombol *UPDATE DIAGNOSTICS*) menampilkan kunci yang dipercaya, kunci mana yang memverifikasi pemeriksaan terakhir, dan latensinya. **Telemetri adopsi** (`UpdatePingService`): aplikasi melaporkan versi terpasang ke endpoint yang dikonfigurasi (HTTPS + host allowlist, rate-limited, tanpa data pribadi, bisa dimatikan di Project Settings → *UPDATE TELEMETRY*) agar gate retire memakai adopsi fleet nyata, bukan proksi

#### Menerbitkan pembaruan

1. Naikkan versi di `pubspec.yaml`, `installer/YOUNZCODE.iss`, dan konstanta `_appVersion` di `lib/main.dart`, lalu build installer
2. Di `updates.json`: naikkan `version`, isi `download_url` (host harus di allowlist `updateAllowedHosts`) dan `sha256` installer
3. Tandatangani manifest:
   ```powershell
   dart run tool/sign_update.dart
   ```
   (private key di `tool/signing/update_signing_private_key.txt` — jangan pernah di-commit)
4. Push `updates.json`; pengguna akan melihat tawaran pembaruan

> **Backup & recovery kunci penandatanganan** (wajib dibaca sebelum rilis):
> lihat [docs/update-signing.md](docs/update-signing.md) — cara backup ke
> password manager + vault offline (`dart run tool/backup_signing_key.dart`),
> verifikasi backup, dan langkah pemulihan bila kunci hilang.

Setiap rilis (tag `v*`) digate oleh **release gate** (`.github/workflows/release-gate.yml`):
jalankan `dart run tool/backup_signing_key.dart` (menulis receipt commit-safe
`.ci/signing-backup-receipt.json` berisi fingerprint + timestamp, tanpa material
kunci) dan commit receipt-nya. Gate gagal bila receipt hilang, lebih tua dari
`BACKUP_MAX_AGE_DAYS` (default 30 hari, bisa diubah lewat repo variable), atau
tidak sinkron dengan kunci di `updateSigningPublicKeys`.

**Rotasi kunci** berjalan lewat update biasa (`UpdateService` memercayai daftar
kunci `updateSigningPublicKeys`): tambahkan public key baru ke daftar, lalu
bubuhkan tanda tangan dari kedua kunci pada rilis transisi:

```powershell
dart run tool/update_keys.dart tool/signing/update_signing_key_new.txt
```

```powershell
dart run tool/sign_update.dart --key tool/signing/update_signing_private_key.txt --key tool/signing/update_signing_key_new.txt
```Setelah pengguna mengejar ke rilis tersebut, tandatangani hanya dengan kunci baru
dan hapus kunci lama dari daftar. Rilis lama tetap diverifikasi via field
`signature`/`signatures` yang sesuai.

**Retire kunci lama** dilakukan lewat workflow `retire-key.yml` (manual
dispatch). Prekondisi: kunci tersisa harus tetap memverifikasi manifest, ring
tidak boleh kosong, dan — yang utama — **adopsi fleet**. Bila telemetri ping
update tersedia (`.ci/update-pings.csv`, dikumpulkan workflow `ping-collect.yml`
dari endpoint yang di-deploy — lihat `tool/ping_server.dart`), retire hanya
lolos bila rasio install unik yang sudah memakai versi target (`--adoption-version`,
default rilis terbaru) dalam jendela `--adoption-window-days` (default 30 hari)
≥ `--min-adoption-ratio` (default 0.9). Tanpa data ping, alat memakai proksi
riwayat margin malam (baris ≥ 14 dan segar ≤ 7 hari) agar gate tetap bekerja
sebelum telemetri aktif. Bila lolos, kunci dihapus dari
`updateSigningPublicKeys`, diuji, dan di-commit; release gate juga memvalidasi
retire apa pun yang terdeteksi dibanding tag rilis sebelumnya.

---

## 🧰 Teknologi

| Lapisan | Teknologi |
|---|---|
| Framework | Flutter (desktop Windows) |
| HTTP | http · dio-style requests via package `http` |
| Browser agent | webview_windows (Edge WebView2) |
| Ekstraksi dokumen | pdfrx (PDF), xml (DOCX), archive (XLSX) |
| Keamanan | cryptography, secret scanner, workspace trust |
| Animasi | lottie |
| Skill pack | [`skills/graphify`](skills/graphify) — knowledge graph |

---

## 🚀 Menjalankan

### Development

```powershell
flutter pub get
flutter run -d windows
```

**Pemakaian pertama:**

1. Klik **workspace** di panel kiri dan pilih folder proyek
2. Klik ikon **pengaturan** di kanan atas
3. Isi **base URL, model, dan API key**
4. Tulis tugas pada kotak pesan

### Release build

```powershell
flutter build windows --release
```

Hasilnya di `build\windows\x64\runner\Release\YOUNZCODE.exe` — distribusikan **seluruh isi folder Release** (bukan hanya `.exe`), karena aplikasi memerlukan DLL dan data Flutter.

> Catatan: Flutter Windows menolak karakter `!` pada path proyek. Jika perlu build ulang, salin proyek ke path tanpa karakter tersebut, mis. `C:\kode_agent_build`.

### Installer

Installer Inno Setup yang sudah dikompilasi tersedia di `installer\output\YOUNZCODE-Setup-1.3.7.exe`. Membangun ulang:

```powershell
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" "installer\YOUNZCODE.iss"
```

Bundle installer menyertakan `tools\yt-dlp.exe` dan `tools\ffmpeg.exe`. Untuk development build, keduanya juga bisa tersedia di `PATH`; lokasi alternatif via `YOUNZCODE_YTDLP` dan `YOUNZCODE_FFMPEG`.

### Release otomatis (pipeline)

Push tag `vX.Y.Z` (mis. `v1.3.7`) memicu `.github/workflows/release.yml`: membangun installer Windows, menghitung SHA-256, menambahkan entri ke `updates.json`, menandatanganinya dengan kunci penandatanganan yang di-restore dari **secrets** (`UPDATE_SIGNING_KEY` dan opsional `UPDATE_SIGNING_KEY_2`), memverifikasi manifest terhadap key ring bawaan, memublikasikan `updates.json` ke cabang manifest, dan membuat GitHub release dengan installer terlampir.

Sebelum men-tag, pastikan versi sudah di-bump di `pubspec.yaml`, `lib/main.dart`, dan `installer/YOUNZCODE.iss`, serta receipt backup kunci segar sudah di-commit (`.ci/signing-backup-receipt.json`). Pipeline memvalidasi semuanya dan gagal cepat bila ada yang belum disiapkan. Lihat `docs/update-signing.md` untuk detail secret dan alur.

**Tag itu sendiri adalah artefak rilis** — tag `vX.Y.Z` harus berada tepat di ujung `main` DAN cabang manifest (cabang yang melayani `updates.json`), serta memuat workflow rilis. Invariant ini diperiksa otomatis oleh `tool/check_tag_sync.dart` (jalankan lokal: `dart run tool/check_tag_sync.dart --tag vX.Y.Z --main main --branch <cabang-manifest>`), sebagai langkah awal di `release-gate.yml` setiap tag, dan sebagai fail-fast sebelum build di `release.yml`. Bila tag menunjuk komit yang berbeda dari salah satu cabang, atau pohonnya tidak memuat `release.yml`/`release-gate.yml`/`workflow-lint.yml`, pipeline tidak akan rilis: merge/ff rilis ke `main`, pastikan cabang manifest di komit yang sama, baru tag.

**Pengaman workflow**: GitHub diam-diam mengabaikan workflow yang YAML-nya tidak bisa di-parse (pipeline rilis tidak akan pernah jalan, tanpa error). Untuk mencegahnya: (1) pasang hook lokal sekali dengan `bash tool/install_git_hooks.sh` — hook `pre-push` menolak push tag `v*` bila ada `.github/workflows/*.yml` yang rusak; (2) CI menjalankan cek yang sama via `.github/workflows/workflow-lint.yml` (setiap push/PR) dan sebagai langkah pertama `release-gate.yml` (setiap tag). Validator: `dart run tool/check_workflows.dart`.

---

## 📁 Struktur Project

```
lib/
├── main.dart                  # Shell aplikasi
├── app/                       # Workflow state: workspace lifecycle, konfigurasi agent,
│                              #   browser, command, goal, turn agent, session/editor/terminal
├── services/                  # 30+ service: git, MCP client, provider routing & usage,
│                              #   debug adapter, quality gate, code intelligence, checkpoint,
│                              #   secret scanner, workspace trust, update, media download
├── models/                    # Chat session, addon, agent goal, workspace change
├── ui/                        # Editor, browser panel, inspector, image studio, dialogs, overlays
├── skills/                    # Skill pack (graphify)
├── installer/                 # Inno Setup (YOUNZCODE.iss)
└── test/                      # 33+ file unit test + integration test (browser smoke)
```

---

## 🧪 Pengujian

```bash
flutter test
flutter test integration_test/browser_windows_smoke_test.dart -d windows
```

**Precompile tool CLI** (sekali saja, atau setelah mengubah `tool/*.dart`):
`dart run` membayar ~5–7 detik build hooks + kompilasi JIT tiap pemanggilan;
`tool/build_tools.sh` mengompilasi semua tool ke `build/tools/` (AOT,
~80 ms per jalankan). Test CLI dan script memakai binary ter-kompilasi saat
ada dan jatuh kembali ke `dart run` bila tidak — build bersifat opsional:

```bash
bash tool/build_tools.sh
```

**Load test debug adapter (CI: `.github/workflows/dap-load-test.yml`):**
menjalankan suite DAP sambil membakar CPU paralel (`tool/cpu_stress.dart`) agar
cold-start debugpy/js-debug diuji di bawah kontensi — menangkap flake
startup-timeout sebelum rilis:

```bash
tool/run_dap_load_test.sh
```

Set `YOUNZCODE_JS_DEBUG` ke `dapDebugServer.js` (mis. dari
`js-debug-dap-*.tar.gz` rilis vscode-js-debug) agar test Node.js ikut berjalan;
CI melakukannya otomatis dengan rilis yang di-pin + verifikasi SHA-256.

Setiap cold-start melaporkan margin-nya (`HANDSHAKE` line → `DebugAdapterTiming`),
jadi log CI menunjukkan seberapa dekat tiap adapter ke batas timeout 30 detik.
Knob env: `WORKERS` (jumlah pembakar CPU, default cores−1 max `STRESS_CAP=4`),
`HANDSHAKE_WARN_RATIO` (warn jika ≥ fraksi budget, default 0.5), dan
`HANDSHAKE_FAIL_RATIO` (jika di-set, run gagal bila margin di bawah fraksi
tersebut — default off agar kontensi biasa tidak membuat CI merah).

Margin tiap run malam dicatat ke `.ci/dap-load-history.csv` (commit otomatis
oleh job `persist-history`) — kolom `timestamp,os,workers,adapter,totalMs,ratio`
— sehingga tren degradasi cold-start terlihat lintas run sebelum menyentuh
batas timeout. Atur kedalaman riwayat via variable repo `HISTORY_ROWS`
(default 366 baris ≈ 2 bulan run malam).

Pada run push/PR, job menerapkan `HANDSHAKE_FAIL_RATIO` (default `0.5`,
tunable via variable repo dengan nama sama) — PR gagal bila margin handshake
di bawah ambang tersebut meski test lolos, jadi regresi startup-timeout
menghalangi merge. Run malam (schedule) tidak menerapkannya dan murni jadi
monitor drift.

Monitor drift malam: `tool/check_drift.py` menghitung median rasio per
(os, adapter) pada jendela `DRIFT_WINDOW` run terakhir (default 7) dan
meng-flag run bila median ≥ `DRIFT_RATIO` (default `0.35`, keduanya tunable
via variable repo) — peringatan dini sebelum tren menyentuh ambang gate merge.
Riwayat tetap di-commit meski drift ter-flag, jadi datanya tidak hilang.

Logika gate divalidasi oleh `tool/simulate_gating.dart` — simulator ekspresi
GitHub Actions yang membaca ekspresi langsung dari workflow dan menguji
11 kasus (event × nilai variable) — dijalankan di CI sebelum load test agar
typo pada ekspresi ketahuan lebih dulu.

Saat drift ter-flag, `tool/notify_drift.sh` mengirim notifikasi: (1) ke Slack
jika secret repo `SLACK_WEBHOOK_URL` di-set, dan (2) repository_dispatch
`dap-load-drift` jika variable repo `DRIFT_DISPATCH` = `1` (untuk workflow
konsumen, mis. membuka issue otomatis) — keduanya menyertakan link ke run
yang gagal dan `.ci/dap-load-history.csv`. Gagalnya pengiriman notifikasi
tidak menambah kegagalan; flag drift itu sendiri yang membuat run merah.

---

## 📄 Dokumentasi

- [ADDONS_GUIDE.md](ADDONS_GUIDE.md) — panduan pemasangan skill, plugin, MCP, dan extension

---

*Dibuat dengan ☕ dan Flutter — dari tanah Besemah.*
