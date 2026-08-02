# YOUNZCODE

Panduan pemasangan skill, plugin, MCP, dan extension tersedia di [`ADDONS_GUIDE.md`](ADDONS_GUIDE.md).

Aplikasi AI coding agent native untuk Windows, dibuat dengan Flutter. Aplikasi dapat membaca dan mencari kode, mengubah file, menjalankan PowerShell, serta meminta izin sebelum tindakan yang mengubah sistem.

Editor workspace menyediakan syntax highlighting, autocomplete lokal (`Ctrl+Space`), minimap, diagnostics dari toolchain bahasa, breakpoint gutter, serta Run/Debug console. Dart memakai Debug Adapter Protocol bawaan SDK. Python memakai `debugpy`. Node.js memakai standalone DAP server resmi Microsoft `js-debug` yang disertakan dalam installer; lokasi alternatif dapat ditentukan dengan `YOUNZCODE_JS_DEBUG`. Ketiganya mendukung breakpoint dan stepping nyata.

Kontrol debugger: `F5` untuk mulai/lanjut, `F10` untuk step over, `F11` untuk step into, dan `Shift+F11` untuk step out.

## Fitur pengembangan

- Checkpoint perubahan tersimpan per workspace dan dapat dipulihkan dari Inspector.
- Hybrid code intelligence menggabungkan pencarian istilah Indonesia/Inggris, symbol index, go-to-definition, references, dan autocomplete workspace.
- Perintah `/agents tugas 1 | tugas 2` menjalankan beberapa agent secara paralel pada branch dan Git worktree yang terisolasi.
- Perintah `/goal <tujuan>` menyimpan tujuan per chat dan menjalankan turn lanjutan otomatis sampai agent menandainya selesai atau terblokir. Staged edit dipertahankan sepanjang rangkaian goal.
- Git Center mendukung status detail, stage/unstage, discard, commit, branch, merge/abort, push, serta pengelolaan worktree.
- Add-on Manager menampilkan health check, latensi, log, dan kebijakan izin per tool MCP.
- Provider mendukung urutan fallback, retry/failover, harga token, anggaran bulanan, dan dashboard `/usage`.
- Respons provider kosong dicoba ulang otomatis dengan mode transport alternatif, serta tidak lagi ditampilkan sebagai kartu agent sukses tanpa isi.
- Model Settings menempatkan API key sebelum Fetch, mengenali preset AgentRouter, dan menampilkan detail autentikasi yang berguna untuk HTTP 401.
- Quality gate otomatis menjalankan analyzer atau test yang relevan setelah perubahan diterima, lalu menawarkan rollback bila gagal.
- Lampiran chat membaca teks dari Markdown, PDF, DOCX, dan XLSX. PDF hasil scan tetap memerlukan OCR; format lama `.doc`/`.xls` perlu disimpan ulang sebagai `.docx`/`.xlsx`.
- Perintah `/download URL` atau pesan seperti `tolong download URL` mengunduh media publik ke folder `downloads` workspace melalui yt-dlp, dengan validasi URL, konfirmasi hak akses, progres, dan pembatalan.
- Agent Browser berbasis Microsoft Edge WebView2 dapat membuka URL HTTPS atau preview `localhost`, membaca halaman, klik, mengetik, upload file workspace, dan menyimpan screenshot. Upload serta aksi penting seperti delete/submit/publish/login selalu melewati approval.
- Fondasi agent dipisahkan menjadi transport completion, sesi edit transaksional, routing provider, usage store, checkpoint store, dan quality gate agar lebih mudah diuji serta dikembangkan.

Shell aplikasi tetap berada di `lib/main.dart`, sedangkan workflow state dipisahkan ke `lib/app/`: lifecycle workspace, konfigurasi agent, browser, command, turn agent, serta session/editor/terminal. Service dan panel browser berada di file mandiri agar `main.dart` tidak kembali menumpuk. Semuanya memakai Dart `part` dalam satu library agar private state tetap tertutup tanpa membuat siklus import.

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

Gunakan `/goal tujuan yang ingin diselesaikan` untuk pekerjaan panjang. Statusnya tampil di atas pemilih model. Perintah `/goal status`, `/goal resume`, `/goal stop`, dan `/goal clear` mengelola goal aktif. Delapan kelanjutan otomatis diizinkan per batch; bila pekerjaan masih belum selesai, goal dijeda dengan checkpoint tetap tersimpan dan dapat dilanjutkan melalui `/goal resume`. Goal aktif yang dipulihkan setelah aplikasi dibuka ulang juga dijeda sampai pengguna memilih resume, agar pekerjaan dan biaya provider tidak berjalan tanpa sepengetahuan pengguna.

Root file tree dapat dilipat dengan mengklik baris folder workspace. Composer memiliki `BUILD` mode dan `PLAN` mode; Plan Mode hanya menyediakan tool baca/search, menonaktifkan write, terminal, dan MCP eksternal, lalu meminta agent menghasilkan rencana tanpa mengubah sistem.

Agent Browser dapat dibuka dari command rail, tab `Browser`, command palette, atau `/browser URL`. Browser memakai profil khusus di `%LOCALAPPDATA%\YOUNZCODE\AgentBrowser`, terpisah dari profil Edge pribadi. Situs publik wajib HTTPS; HTTP hanya diizinkan untuk preview `localhost`. Microsoft Edge WebView2 Runtime diperlukan.

Saat Agent Browser dibuka otomatis oleh tool, aplikasi kembali ke chat setelah turn selesai agar jawaban langsung terlihat. Buka/read/klik aman tidak menampilkan approval; upload, submit, password, delete, publish, pembayaran, dan aksi penting lain tetap meminta konfirmasi.

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

Endpoint native Anthropic dan Gemini juga dikenali otomatis. Tambahkan beberapa Base URL fallback di Model Settings untuk failover berurutan. Harga input/output per satu juta token dan anggaran token bulanan bersifat opsional; statistik pemakaian dapat dibuka dengan `/usage`.

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
  installer\output\YOUNZCODE-Setup-1.3.5.exe
```

Untuk membangun ulang installer:

```powershell
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" "installer\YOUNZCODE.iss"
```

Catatan: Flutter Windows menolak karakter `!` pada path proyek. Jika perlu membangun ulang pada komputer ini, salin proyek sementara ke path tanpa karakter tersebut, misalnya `C:\kode_agent_build`, lalu jalankan perintah build dari sana.

Bundle installer menyertakan `tools\yt-dlp.exe` dan `tools\ffmpeg.exe`. Untuk development build, keduanya juga dapat tersedia di `PATH`; lokasi alternatif dapat ditentukan dengan `YOUNZCODE_YTDLP` dan `YOUNZCODE_FFMPEG`.
