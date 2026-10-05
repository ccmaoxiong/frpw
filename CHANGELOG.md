# Changelog

## v1.0.0 - 2026-10-05

- First private-release baseline for FRPW.
- Added Linux release builds for the server, Agent, and remote Node.
- Added Windows, Linux, and macOS client packages for the user console.
- Added the Linux one-click installer for the server, Agent, and remote Node.
- Added authenticated release downloads with SHA-256 verification and mirror support.
- Hardened the Linux installer with HTTP/1.1 downloads, retries, atomic file replacement, and API-free public release downloads.
- Added a China mirror installer with jsDelivr entry points, multi-mirror failover, and pinned SHA-256 verification.
- Added systemd service installation for Linux.
- Hardened checksum manifest parsing and retry behavior for invalid downloads.
- Added repository licensing, release workflow, and release metadata.
- Simplified payment configuration to three fields per channel: an epay primary channel plus a 黑胡椒支付 (xunhupay) backup channel with independent credentials. Legacy `codepay_*` settings migrate automatically.
- Fixed the China installer after the v1.0.0 asset refresh: repinned `SHA256SUMS` and moved the installer entry point to the mirrored release asset, because Git CDN tag resolution kept serving the stale bootstrap script.
