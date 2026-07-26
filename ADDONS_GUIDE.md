# Panduan Add-on YOUNZCODE

Panduan ini menjelaskan cara memasang dan mengelola skill, plugin, MCP server, dan extension VSIX di YOUNZCODE.

## Membuka Add-on Manager

1. Jalankan YOUNZCODE.
2. Klik `ADD-ONS` pada sidebar kiri.
3. Pilih salah satu tindakan:
   - `IMPORT FILE` untuk memasang `SKILL.md`, konfigurasi JSON, atau `.vsix`.
   - `IMPORT FOLDER` untuk memasang folder skill atau plugin.
4. Konfirmasi proses import.
5. Pastikan switch add-on berada dalam kondisi aktif.

Add-on yang diimpor disalin ke:

```text
%LOCALAPPDATA%\YOUNZCODE\addons
```

File atau folder sumber asli tidak dihapus ketika add-on dihapus dari YOUNZCODE.

## Memasang Skill

YOUNZCODE mendukung skill dengan format `SKILL.md` yang kompatibel dengan pola OpenCode dan Claude Code.

### Struktur Folder

```text
code-reviewer/
|-- SKILL.md
`-- references/
    `-- checklist.md
```

### Contoh SKILL.md

```markdown
---
name: Code Reviewer
description: Memeriksa bug, keamanan, regresi, dan kualitas kode.
---

# Code Reviewer

Periksa kode sebelum memberikan kesimpulan.

Prioritaskan:

- Bug dan behavioral regression.
- Masalah keamanan.
- Error handling yang hilang.
- Test yang belum tersedia.
- Perubahan yang terlalu kompleks.

Cantumkan file dan nomor baris pada setiap temuan.
```

### Cara Memasang

1. Buka `ADD-ONS`.
2. Klik `IMPORT FOLDER`.
3. Pilih folder yang berisi `SKILL.md`.
4. Konfirmasi import.
5. Pastikan status skill menunjukkan:

```text
ACTIVE AS AGENT INSTRUCTIONS
```

Anda juga dapat memilih `IMPORT FILE` dan membuka `SKILL.md` secara langsung.

Skill aktif otomatis ditambahkan ke instruksi agent. Skill tidak perlu dipanggil dengan slash command.

## Memasang Plugin

Plugin YOUNZCODE menggunakan manifest JSON. Pada versi ini, field `prompt` atau `instructions` dapat menambahkan perilaku khusus pada agent. Kode executable plugin tidak dijalankan otomatis.

### Struktur Folder

```text
security-review/
|-- younzcode-plugin.json
`-- resources/
    `-- rules.md
```

### Contoh Manifest

```json
{
  "name": "security-review",
  "displayName": "Security Review",
  "version": "1.0.0",
  "description": "Menambahkan aturan pemeriksaan keamanan.",
  "instructions": "Periksa hardcoded secret, path traversal, command injection, SQL injection, SSRF, dan penyimpanan credential yang tidak aman."
}
```

Alternatif menggunakan `prompt`:

```json
{
  "name": "flutter-expert",
  "displayName": "Flutter Expert",
  "version": "1.0.0",
  "description": "Panduan khusus Flutter.",
  "prompt": "Gunakan pola Flutter modern, jaga lifecycle controller, dan verifikasi dengan flutter analyze serta flutter test."
}
```

Nama manifest yang dikenali:

```text
younzcode-plugin.json
younzcode.plugin.json
plugin.json
manifest.json
package.json
```

### Cara Memasang

1. Buka `ADD-ONS`.
2. Klik `IMPORT FOLDER`.
3. Pilih folder plugin.
4. Konfirmasi import.
5. Aktifkan switch plugin.

Status plugin:

```text
MANIFEST/PROMPT ACTIVE - CODE EXECUTION DISABLED
```

Status tersebut berarti instruksi plugin aktif, tetapi JavaScript, executable, atau entry point plugin tidak dijalankan.

## Memasang MCP

YOUNZCODE dapat menghubungkan MCP stdio sebagai dynamic tools untuk agent.

MCP hanya dijalankan dalam mode `BUILD`. Seluruh MCP dinonaktifkan dalam `PLAN` mode karena proses eksternal tidak dapat dijamin read-only.

### Contoh Konfigurasi Claude-style

Simpan sebagai `mcp.json`:

```json
{
  "mcpServers": {
    "filesystem-tools": {
      "command": "node",
      "args": [
        "C:\\tools\\filesystem-mcp\\server.js"
      ],
      "env": {
        "MODE": "safe"
      }
    }
  }
}
```

### Contoh Konfigurasi OpenCode-style

```json
{
  "mcp": {
    "local-tools": {
      "type": "local",
      "command": [
        "node",
        "C:\\tools\\local-mcp\\server.js",
        "--safe"
      ]
    }
  }
}
```

### Contoh MCP Python

```json
{
  "mcpServers": {
    "python-tools": {
      "command": "python",
      "args": [
        "-m",
        "my_mcp_server"
      ],
      "env": {
        "PYTHONUNBUFFERED": "1"
      }
    }
  }
}
```

### Nama File yang Dikenali

```text
mcp.json
.mcp.json
mcp-config.json
mcp_config.json
```

### Cara Memasang

1. Pastikan runtime server tersedia, seperti `node`, `python`, atau executable lain.
2. Pastikan command dapat dijalankan dari PowerShell.
3. Buka `ADD-ONS`.
4. Klik `IMPORT FILE`.
5. Pilih konfigurasi JSON MCP.
6. Konfirmasi import.
7. Aktifkan switch MCP.
8. Pilih mode `BUILD` pada composer.
9. Buat `NEW CHAT` jika agent lama sudah dibuat sebelum MCP diaktifkan.

Status MCP stdio:

```text
MCP STDIO TOOLS ACTIVE
```

### Persyaratan Server MCP Stdio

Server harus:

- Menggunakan JSON-RPC MCP melalui stdio.
- Menulis satu pesan JSON per baris ke `stdout`.
- Menulis log biasa ke `stderr`, bukan `stdout`.
- Mendukung `initialize`.
- Mendukung `tools/list`.
- Mendukung `tools/call`.

### MCP HTTP

Konfigurasi HTTP dapat diimpor:

```json
{
  "mcpServers": {
    "remote-docs": {
      "url": "https://mcp.example.com/api",
      "headers": {
        "Authorization": "Bearer token"
      }
    }
  }
}
```

MCP HTTP saat ini berstatus configuration-only dan belum dijalankan. Dukungan lengkap memerlukan Streamable HTTP/SSE, session ID, reconnect, cancellation, dan perlindungan credential tambahan.

Jangan menyimpan token sensitif dalam file JSON yang akan dimasukkan ke Git atau dibagikan.

## Memasang Extension VSIX

YOUNZCODE dapat mengimpor dan mengelola file `.vsix`.

Format nama file yang disarankan:

```text
publisher.extension-name-1.0.0.vsix
```

### Cara Memasang

1. Buka `ADD-ONS`.
2. Klik `IMPORT FILE`.
3. Pilih file `.vsix`.
4. Konfirmasi import.
5. Extension akan muncul dalam daftar add-on.

Status VSIX:

```text
STORED ONLY - VS CODE API RUNTIME NOT EMBEDDED
```

YOUNZCODE belum menyediakan VS Code Extension Host. Extension yang membutuhkan API berikut tidak dapat dijalankan secara penuh:

```javascript
vscode.commands
vscode.workspace
vscode.window
vscode.languages
```

Gunakan VS Code untuk menjalankan extension VSIX yang membutuhkan runtime API VS Code. Di YOUNZCODE, VSIX saat ini hanya dapat disimpan, diaktifkan atau dinonaktifkan, dan dihapus.

## Mengelola Add-on

Setiap add-on menyediakan:

- Switch aktif: add-on digunakan oleh sesi agent baru.
- Switch nonaktif: add-on tetap terpasang tetapi tidak digunakan.
- Ikon tempat sampah: menghapus salinan add-on dari storage YOUNZCODE.

Setelah mengaktifkan, menonaktifkan, atau menghapus add-on, buat `NEW CHAT` bila sesi yang sedang berjalan belum memuat konfigurasi terbaru.

## Plan Mode dan Add-on

Dalam `PLAN` mode:

- Skill tetap dapat memberikan instruksi analisis.
- Prompt plugin tetap dapat memberikan panduan.
- Tool tulis dinonaktifkan.
- Terminal dinonaktifkan.
- Seluruh MCP eksternal dinonaktifkan.
- Agent hanya dapat membaca, mencari, dan menyusun rencana.

Dalam `BUILD` mode:

- Skill dan prompt plugin aktif.
- MCP stdio aktif jika switch diaktifkan.
- Tool tulis dan terminal mengikuti permission project.

## Troubleshooting MCP

### Command Tidak Ditemukan

Uji command dari PowerShell:

```powershell
node "C:\tools\server.js"
```

atau:

```powershell
python -m my_mcp_server
```

Jika command gagal, tambahkan runtime ke `PATH` atau gunakan path executable absolut pada konfigurasi MCP.

### Tool MCP Tidak Muncul

Periksa bahwa:

- Add-on MCP dalam keadaan aktif.
- Composer menggunakan mode `BUILD`.
- Konfigurasi JSON valid.
- Command dan seluruh argument benar.
- Server mendukung `initialize`, `tools/list`, dan `tools/call`.
- Server tidak menulis log biasa ke `stdout`.
- Sesi chat baru sudah dibuat setelah konfigurasi berubah.

### Path Windows Tidak Valid

Dalam JSON, gunakan backslash ganda:

```json
{
  "command": "C:\\Program Files\\NodeJS\\node.exe"
}
```

Atau gunakan slash:

```json
{
  "command": "C:/Program Files/NodeJS/node.exe"
}
```

## Catatan Keamanan

- Add-on tidak dieksekusi saat proses import.
- Symbolic link dalam folder add-on ditolak.
- Path traversal dan import dari managed add-on directory ditolak.
- Plugin executable dan VSIX tidak dijalankan otomatis.
- MCP stdio berjalan dengan izin pengguna Windows ketika agent menginisialisasinya.
- Aktifkan hanya MCP dari sumber yang dipercaya.
- Jangan menyimpan token atau password dalam manifest yang dibagikan.
- Gunakan `PLAN` mode bila hanya ingin analisis read-only.
