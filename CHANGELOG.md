# Changelog

## v1.0.0 - 2026-10-05

- First private-release baseline for FRPW.
- Added cross-platform release builds for the server, Agent, and remote Node.
- Added Linux and Windows one-click installers for server, Agent, and Node.
- Added private GitHub Release downloads with SHA-256 verification.
- Added systemd and Windows startup-task service installation.
- Added support for an authenticated private release mirror.
- Fixed one-click installer asset resolution for compact GitHub API responses.
- Added automatic fallback from GitHub API asset downloads to public Release URLs.
- Hardened checksum manifest parsing and added retry for invalid checksum downloads.
- Unified server and node build-time version reporting.
- Added repository licensing, release workflow, and release metadata.
