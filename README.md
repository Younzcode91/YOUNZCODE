<div align="center">

<img src="assets/younzcode_logo_new.png" alt="YOUNZCODE" width="120"/>

# YOUNZCODE 🤖

**AI coding agent desktop untuk Windows.**

![Flutter](https://img.shields.io/badge/Flutter-3-0F766E?logo=flutter&logoColor=white&style=flat)
![Dart](https://img.shields.io/badge/Dart-^3.11-0175C2?logo=dart&logoColor=white&style=flat)
![Version](https://img.shields.io/badge/versi-1.3.5-16A34A?style=flat)
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
- **Update service** untuk pembaruan aplikasi

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

Installer Inno Setup yang sudah dikompilasi tersedia di `installer\output\YOUNZCODE-Setup-1.3.5.exe`. Membangun ulang:

```powershell
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" "installer\YOUNZCODE.iss"
```

Bundle installer menyertakan `tools\yt-dlp.exe` dan `tools\ffmpeg.exe`. Untuk development build, keduanya juga bisa tersedia di `PATH`; lokasi alternatif via `YOUNZCODE_YTDLP` dan `YOUNZCODE_FFMPEG`.

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

---

## 📄 Dokumentasi

- [ADDONS_GUIDE.md](ADDONS_GUIDE.md) — panduan pemasangan skill, plugin, MCP, dan extension

---

*Dibuat dengan ☕ dan Flutter — dari tanah Besemah.*
