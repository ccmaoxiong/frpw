# Changelog






## v1.0.0 - 2026-10-05

- First private-release baseline for FRPW.
- Added Linux release builds for the server, Agent, and remote Node.
- Added Windows, Linux, and macOS client packages for the user console.
- Added the Linux one-click installer for the server, Agent, and remote Node.
- Added authenticated release downloads with SHA-256 verification and mirror support.
- Hardened the Linux installer with HTTP/1.1 downloads, retries, atomic file replacement, and API-free public release downloads.
- Added a China mirror installer with mirror-proxied release-asset entry points, multi-mirror failover, and pinned SHA-256 verification.
- Added systemd service installation for Linux.
- Hardened checksum manifest parsing and retry behavior for invalid downloads.
- Added repository licensing, release workflow, and release metadata.
- Simplified payment configuration to three fields per channel: an epay primary channel plus a 黑胡椒支付 (xunhupay) backup channel with independent credentials. Legacy `codepay_*` settings migrate automatically.
- Fixed the China installer after the v1.0.0 asset refresh: repinned `SHA256SUMS` and moved the installer entry point to the mirrored release asset, because Git CDN tag resolution kept serving the stale bootstrap script.
- Added a paid-distribution license gate: `install.sh` and `install-cn.sh` verify an Ed25519-signed `FRPW_LICENSE` before downloading anything, for the server, Agent, and remote Node roles alike.
- Embedded the vendor public key in the server binary: startup refuses a missing or tampered key, re-verifies the license every 6 hours, and refreshes a signed revocation list every 24 hours.
- Added the `degrade` (default) and `strict` enforcement policies plus `FRPW_LICENSE_FILE` and `FRPW_REVOCATION_URL`; degraded deployments are limited to one new tunnel definition and cannot create new orders.
- Added the admin console license panel (`GET /admin/license`, `POST /admin/license/refresh`) showing state, customer, expiry, key fingerprint, revocation reason, and policy.
- Published the signed revocation list `revocations.json` at the repository root; servers refresh it every 24 hours and instantly reject revoked keys.
- Added an optional garble build (`scripts/build-release.ps1 -Garble`) that obfuscates literals and symbols for hardened releases.
- `v1.0.0` assets were refreshed: the Linux server, Agent, and remote Node binaries are now garble-obfuscated (`-literals`), and the China installer pin for `SHA256SUMS` was updated accordingly.
