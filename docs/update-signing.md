# Update signing key: backup & recovery

YOUNZCODE's in-app update check (`UpdateService` in `lib/services/update_service.dart`)
verifies every release manifest against a **key ring** of Ed25519 public keys baked
into the app (`updateSigningPublicKeys`). A release is accepted when **any** trusted
key validates its signature. The matching **private keys are the only secrets required
to publish updates** — anyone holding one can sign a release that the app will accept.
Treat them as root credentials.

## Key facts

| Item | Location |
|---|---|
| Private keys (32-byte seed, base64) | `tool/signing/update_signing_private_key.txt` (+ rotation keys) |
| Trusted public keys (base64 list) | `updateSigningPublicKeys` in `lib/services/update_service.dart` |
| Generate a new keypair | `dart run tool/update_keys.dart` |
| Sign the manifest (one key) | `dart run tool/sign_update.dart [keyPath] [manifestPath]` |
| Sign the manifest (multi-key) | `dart run tool/sign_update.dart --key old.txt --key new.txt [manifestPath]` |
| Backup entry + encrypted copy | `tool/signing/backup/` |
| Fleet adoption pings | `.ci/update-pings.csv` (collected by `ping-collect.yml`) |

The signing tool writes every signature into the manifest's `signatures` array
(`public_key` + `signature` pairs) and keeps the legacy single `signature` field set
from the **first key** passed, so clients that predate the key ring keep verifying.
During rotation always pass the oldest in-field key first.

The whole `tool/signing/` directory is gitignored — the private key and backups must
never be committed, pushed, or shared.

## Making a backup (run before every release)

```bash
# 1. Emits a password-manager entry (fingerprint, public key, private key,
#    self-test) and writes it to tool/signing/backup/signing_key_vault_entry.txt
dart run tool/backup_signing_key.dart

# 2. Creates an AES-256 encrypted copy for offline storage; prints a fresh
#    passphrase ONCE. Store that passphrase in the password manager next to
#    the key entry, and move the .gpg file to a USB drive / offline vault.
PASS="$(openssl rand -base64 32)"
gpg --batch --yes --pinentry-mode loopback --passphrase "$PASS" \
  --cipher-algo AES256 \
  -o tool/signing/backup/update_signing_private_key.txt.gpg \
  -c tool/signing/update_signing_private_key.txt
```

Store in the password manager: the full vault entry (private key, public key,
fingerprint) **and** the gpg passphrase, as two fields of the same item or two
related items in two different vaults if you want split custody.

The tool also **upserts a commit-safe receipt** at `.ci/signing-backup-receipt.json`
— per-key fingerprint + timestamp, never key material. **Commit the receipt
with the backup**: the release gate (`.github/workflows/release-gate.yml`) fails
on any `v*` tag when the receipt is missing, older than `BACKUP_MAX_AGE_DAYS`
(default 30 days), or out of sync with the keys in `updateSigningPublicKeys`,
prompting a fresh backup before a manifest is signed.

## Verifying a backup

Before relying on any copy (old backup, restored file, new machine), point the
backup tool at it — it prints the fingerprint and checks the derived public key
against the baked-in key:

```bash
dart run tool/backup_signing_key.dart /path/to/candidate_key.txt
```

A valid backup prints `== updateSigningPublicKeys ...: YES`, a matching
fingerprint, and `Self-test: PASS`. Anything else means the copy is corrupt,
partial, or the wrong key — do not use it.

## Using the key on a new machine

1. Copy `update_signing_private_key.txt` (or decrypt the `.gpg` backup:
   `gpg -d backup.gpg > tool/signing/update_signing_private_key.txt`) into
   `tool/signing/`.
2. Verify it: `dart run tool/backup_signing_key.dart`.
3. Sign: `dart run tool/sign_update.dart`.

## Rotation (key still held): ships in a normal update

The key ring makes rotation a non-event:

1. **Generate the new key** — `dart run tool/update_keys.dart new_key.txt`.
2. **Add the new public key** to `updateSigningPublicKeys` in
   `lib/services/update_service.dart` (keep the old one too).
3. **Sign the transition release with both keys** —
   `dart run tool/sign_update.dart --key old.txt --key new.txt updates.json`.
   Old clients (trusting only the old key) accept it via the old key's
   signature; everyone who updates now trusts both.
4. **After the fleet has caught up**, sign with the new key only and remove the
   old key from the list in a later build.

No out-of-band installs, no channel outage — the transition release is just a
normal update.

4. **Retire the old key** once the fleet has caught up — `retire-key.yml`
   (manual dispatch) or `dart run tool/retire_signing_key.dart --retire <key>`
   locally. The gate measures **true fleet adoption** from update-ping
   telemetry when available, and falls back to the nightly margin history
   proxy when it is not. The next release is then signed with the surviving
   key only.

## Fleet adoption telemetry (update ping)

To retire on real adoption instead of a proxy, the app reports its installed
version to an endpoint you control:

- **Client** — `UpdatePingService` POSTs `{version, channel, os, install_id,
  timestamp}` (no personal data; install_id is a random per-install token) to
  `updatePingEndpointUrl`. HTTPS-only, host allowlist enforced
  (`updatePingAllowedHosts`), rate-limited to one ping per hour per install,
  fire-and-forget, and user-opt-out (Project Settings → UPDATE TELEMETRY,
  persisted via `updatePingEnabled`). Shipped disabled: set the two consts to
  your deployed collector.
- **Endpoint** — `tool/ping_server.dart` is a dependency-free reference
  collector: `POST /ping` (validated, appended to a JSONL file),
  `GET /export.csv` (CSV for the gate), `GET /health`. Deploy it anywhere
  `dart` runs and put its public HTTPS URL in the app consts.
- **Collection** — `ping-collect.yml` pulls the export into
  `.ci/update-pings.csv` nightly (dedup + bounded history), configured via the
  `PING_ENDPOINT_URL` repo variable (or secret).
- **Gate** — `retire_signing_key.dart` reads `.ci/update-pings.csv`: when
  telemetry exists, adoption = distinct installs whose latest version is ≥
  `--adoption-version` (default: newest release in the manifest) within
  `--adoption-window-days` (default 30), and retirement requires it to meet
  `--min-adoption-ratio` (default 0.9). Without ping data, the nightly margin
  history proxy (≥ 14 rows, fresh ≤ 7 days) applies so the gate keeps working
  before telemetry is live.

## Recovery if the key is lost

There is **no way to re-derive or reset a lost Ed25519 private key**. Whether the
key ring saves you depends on what the installed fleet already trusts:

- **A spare key is already trusted by the fleet** (recommended posture — keep at
  least two keys in `updateSigningPublicKeys`, stored in separate vaults). Then
  signing with the remaining key ships through the normal update flow, and the
  lost key is simply removed from the list.
- **The lost key is the only one the fleet trusts.** A new signature cannot
  verify against it, and you cannot sign the update that would introduce the new
  key — the ring only helps rotation of keys you still hold. Recovery requires
  the out-of-band path below.

Out-of-band recovery (last resort):

1. **Generate a new keypair** — `dart run tool/update_keys.dart`. It writes the
   new private key to `tool/signing/` and prints the new public key.
2. **Add the new public key** to `updateSigningPublicKeys` in
   `lib/services/update_service.dart`.
3. **Distribute the new build out-of-band** — bump the version, build the
   installer, and ship it by direct download/email/USB, **not** through the
   in-app updater (which cannot verify it). Anyone who installs it manually now
   trusts the new key.
4. **Resume normal updates** — update `updates.json` and sign it with the new
   key. Clients on the manual-install build (or later) accept it; clients stuck
   on the old build must also install manually.

**Cost of losing the only trusted key:** the update channel goes dark for the
installed fleet until they get a manual install. Backups are cheap; keep at least
two independent copies (password manager + encrypted offline file) per key and
re-verify them whenever a key is touched.

## Automated release pipeline (`release.yml`)

Pushing a `v*` tag runs `.github/workflows/release.yml`, which automates the
whole signing part of a release:

1. **Validate preparation** — the tag version must already be baked into
   `pubspec.yaml`, `lib/main.dart`, and `installer/YOUNZCODE.iss`; the signing
   backup receipt must be fresh and committed. Fails fast otherwise.
2. **Build** — `flutter build windows --release`, stage the `release/` folder,
   and compile the Inno Setup installer.
3. **Hash** — SHA-256 of the installer.
4. **Manifest** — append the new release entry to `updates.json`.
5. **Sign** — restore the private keys from repository secrets
   (`UPDATE_SIGNING_KEY`, optional `UPDATE_SIGNING_KEY_2` — the content of the
   matching `tool/signing/update_signing_key*.txt` files, base64 seeds) and run
   `sign_update.dart --key ...`. **To retire a key, delete its secret**: the
   next release is then signed with the surviving key(s) only.
6. **Verify** — `tool/e2e_update_check.dart --manifest updates.json
   --expect-version <tag>` checks the signed manifest against the baked-in key
   ring before anything is published; the signing-related test suites run.
7. **Publish** — commit `updates.json` to the manifest branch (default `main`,
   matching `updateManifestUrl`; override with the `MANIFEST_BRANCH` repo
   variable) using a fast-forward-only push, and create the GitHub release with
   the installer attached (`gh release create`).
8. **Live E2E** — the real in-app path is checked against the published
   manifest and release asset, with retries for CDN propagation.

The private keys themselves never appear in the repo, logs, or artifacts — only
in the secrets and in your offline backups.

## Release checklist (signing part)

Manual releases (or pre-tag preparation for the pipeline):

- [ ] `dart run tool/backup_signing_key.dart` prints `YES` + `PASS`
- [ ] Encrypted `.gpg` copy exists in `tool/signing/backup/` and decrypts
- [ ] Passphrase stored in the password manager
- [ ] `.ci/signing-backup-receipt.json` updated and committed
- [ ] Release gate (`.github/workflows/release-gate.yml`) passes on the `v*` tag
- [ ] `dart run tool/sign_update.dart` (add `--key` per rotation key) — manifest
      signed, no warnings, `signatures` array populated
- [ ] E2E update check (`dart run tool/e2e_update_check.dart`) — `E2E: PASS`

With the pipeline, the last three items run automatically on the tag — keep the
first four manual (backup is a human act) and make sure the secrets mirror the
keys you actually hold.
