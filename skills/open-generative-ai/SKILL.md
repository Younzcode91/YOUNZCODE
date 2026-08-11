---
name: open-generative-ai
description: Install and launch the pinned Open Generative AI Windows desktop app.
license: MIT
metadata:
  tags: "generative-ai, image, video, desktop, windows"
  category: "media"
---

# Open Generative AI

Use the Open Generative AI desktop application for local or provider-backed image and video generation.

## Windows installation

1. Open PowerShell in this skill directory.
2. Run `powershell -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1`.
3. Confirm the installer publisher and destination in the Windows setup dialog.

The helper downloads the pinned upstream `v1.0.9` installer, verifies its published SHA-256 digest, and only then opens the installer. It never bypasses the setup dialog.

## Usage

1. Launch **Open Generative AI** from the Start menu.
2. Configure only the model providers or local endpoints you intend to use.
3. Keep API credentials in the application's credential UI; do not put credentials in prompts, project files, or this skill directory.

See `SOURCE.md` for the exact upstream source, commit, release asset, and digest bundled by YOUNZCODE.
