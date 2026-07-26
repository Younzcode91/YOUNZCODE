# YOUNZCODE

Panduan pemasangan skill, plugin, MCP, dan extension tersedia di [`ADDONS_GUIDE.md`](ADDONS_GUIDE.md).

Aplikasi AI coding agent native untuk Windows, dibuat dengan Flutter. Aplikasi dapat membaca dan mencari kode, mengubah file, menjalankan PowerShell, serta meminta izin sebelum tindakan yang mengubah sistem.

Editor workspace menyediakan syntax highlighting, autocomplete lokal (`Ctrl+Space`), minimap, diagnostics dari toolchain bahasa, breakpoint gutter, serta Run/Debug console. Dart memakai Debug Adapter Protocol bawaan SDK. Python memakai `debugpy`. Node.js memakai standalone DAP server resmi Microsoft `js-debug` yang disertakan dalam installer; lokasi alternatif dapat ditentukan dengan `YOUNZCODE_JS_DEBUG`. Ketiganya mendukung breakpoint dan stepping nyata.

Kontrol debugger: `F5` untuk mulai/lanjut, `F10` untuk step over, `F11` untuk step into, dan `Shift+F11` untuk step out.

## Menjalankan

```powershell
cd "C:\Users\F!DH0-PC\OneDrive\Dokumen\Default Project\kode_agent_desktop"
flutter pub get
flutter run -d windows
```

Di aplikasi:

1. Klik workspace di panel kiri dan pilih folder proyek.
2. Klik ikon pengaturan di kanan atas.
3. Isi base URL, model, dan API key.
4. Tulis tugas pada kotak pesan.

API key hanya berada di memori selama aplikasi berjalan. Base URL, nama model, dan workspace disimpan sebagai preferensi lokal.

File `.env` dan variannya dapat dibuka secara manual setelah konfirmasi keamanan. File tersebut diberi label `LOCAL ONLY`; tool agent AI tetap tidak dapat membaca atau mengubahnya.

Percakapan disimpan otomatis secara lokal per workspace. Tombol `NEW CHAT` membuat sesi baru tanpa menghapus sesi sebelumnya; gunakan menu `HISTORY` untuk membuka, melanjutkan, atau menghapus percakapan lama. Maksimal 50 sesi terbaru disimpan.

Root file tree dapat dilipat dengan mengklik baris folder workspace. Composer memiliki `BUILD` mode dan `PLAN` mode; Plan Mode hanya menyediakan tool baca/search, menonaktifkan write, terminal, dan MCP eksternal, lalu meminta agent menghasilkan rencana tanpa mengubah sistem.

Menu `ADD-ONS` dapat mengimpor file atau folder lokal:

- OpenCode/Claude `SKILL.md`: aktif sebagai instruksi agent.
- Plugin YOUNZCODE JSON: field `prompt` atau `instructions` aktif; kode plugin tidak dijalankan otomatis.
- MCP JSON: server stdio aktif sebagai dynamic tools. Konfigurasi HTTP disimpan tetapi belum dieksekusi pada versi ini.
- VSIX: dapat disimpan, diaktifkan/dinonaktifkan, dan dihapus; extension yang membutuhkan VS Code Extension Host tidak dijalankan.

Add-on disalin ke `%LOCALAPPDATA%\\YOUNZCODE\\addons`, tidak dijalankan saat proses import, dan dapat dikelola dari Add-on Manager. MCP stdio yang diaktifkan berjalan dengan izin pengguna Windows, sehingga hanya aktif di BUILD mode.

## Provider

Konfigurasi OpenAI:

- Base URL: `https://api.openai.com/v1`
- Model: model yang mendukung function/tool calling

Provider lain dapat digunakan jika endpoint-nya kompatibel dengan OpenAI Chat Completions dan mendukung tool calling.

## Build Windows

```powershell
flutter build windows --release
```

Hasil aplikasi berada di:

```text
build\windows\x64\runner\Release\YOUNZCODE.exe
```

Bundle release yang sudah dibuat juga tersedia langsung di:

```text
release\YOUNZCODE.exe
```

Distribusikan seluruh isi folder `Release`, bukan hanya file `.exe`, karena aplikasi memerlukan DLL dan data Flutter di folder tersebut.

## Installer Windows

Installer Inno Setup yang sudah dikompilasi tersedia di:

```text
installer\output\YOUNZCODE-Setup-1.0.0.exe
```

Untuk membangun ulang installer:

```powershell
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" "installer\YOUNZCODE.iss"
```

Catatan: Flutter Windows menolak karakter `!` pada path proyek. Jika perlu membangun ulang pada komputer ini, salin proyek sementara ke path tanpa karakter tersebut, misalnya `C:\kode_agent_build`, lalu jalankan perintah build dari sana.
