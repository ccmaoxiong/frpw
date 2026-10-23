# Changelog






## v1.0.2 - 2026-10-21

- Added real-name identity verification for tenants. The user console has a dedicated 实名认证 page (name + national ID, status, rejection reason); the admin console can enable verification, require it before creating tunnels, review submissions, approve/reject them, and delete records. Enforcement applies to new tunnel definitions only and never stops existing tunnels.
- Added five identity-provider protocols: Alibaba Cloud Marketplace APPCODE, Alibaba Cloud CloudAuth RPC (Id2MetaVerify), Tencent Cloud IAI IdCardVerification, Juhe ID-card query, and a generic JSON gateway with configurable success field/value. Provider secrets are redacted in the admin console; ID numbers are stored as a peppered digest plus a masked display value.
- Fixed email delivery readiness so the dedicated SMTP configuration counts as a usable channel even when no generic notification channel is enabled; registration no longer reports "邮件服务未配置" on SMTP-only deployments. Mail template validation now runs before either setting is persisted, so an invalid template cannot leave a half-saved SMTP configuration.
- Fixed remote-node heartbeats: a definition refresh now reconnects only Agents whose live routes actually differ from the desired set. Previously every refresh called DisconnectAll and could kick healthy Agents, including ones that had just come online.
- Fixed the admin instance dashboard agent count to deduplicate local and remote Agents and to count only the current tenant's online tunnels.
- Fixed user-console issues: a white screen caused by an undefined identity state, ticket reply/status requests using the wrong path or HTTP method, same-page navigation not refreshing stale data, and misleading email-readiness text.
- Client branding: the local client console window title, sidebar brand, and generated client-package README now read「FRPW 商业授权」instead of「FRPW Agent 控制台」/「FRPW 客户端」.
- License scope is now explicit: only the server role verifies `FRPW_LICENSE` and runs the runtime license service. Agent, remote-node and desktop-client binaries contain no license checks and never need a license key; the generated client README states this directly. Also corrected the documentation for missing/invalid keys: those states always refuse startup, while only expired/revoked keys are eligible for `degrade`.
- Installer: all three installers now use the QL-style Chinese status output (`==> 下载 X ...`, `==> 下载完成: X (42.5 MB)`), print human-readable sizes, and show the masked license key plus the verified customer, expiry and max-install count. Interactive terminals keep the download progress bar (`FRPW_NO_PROGRESS=1` disables it); temporary-directory cleanup is preserved.
- Bumped the default install version to `v1.0.2` and repinned `install-cn.sh` to the v1.0.2 `SHA256SUMS` and `install.sh`.

## v1.0.1 - 2026-10-12

- Reorganized the platform admin console into grouped sidebar pages: 业务运营 (运营工作台 / 站点公告 / 数据用量 / 工单管理), 客户与资源 (用户管理 / 实例管理 / 节点中心), 商业化 (套餐管理 / 订单与收款 / 卡密兑换), 系统 (系统配置 / 通知与投递) and 账号安全 (管理员账号). Each former in-page tab is now a first-class page with its own header; the workbench keeps the KPI dashboard plus deep-link tiles, and 卡密兑换 opens the settings console with the redeem category selected.
- Ships the announcement, daily check-in and site usage-recording systems that were hot-updated into the v1.0.0 assets; see the v1.0.0 entries below for the full behaviour.
- Repinned the China installer to the v1.0.1 assets and bumped the default install version to `v1.0.1`.
- The console sidebar and every sign-in screen (user console and admin entry) now end with a `v1.0.1 · by ccmaoxiong` credit line linking to the author's GitHub profile; the admin login page previously showed no version at all.
- Fixed the admin console update dialog: it used to claim "发现新版本" even when the running build was already the latest release, because the unsupported-environment branch unconditionally overwrote the result block. Branches are now mutually exclusive and each renders a distinct message.
- The in-panel updater can now be pointed at a proxy or self-hosted mirror via `FRPW_UPDATE_API_BASE`, `FRPW_UPDATE_MIRRORS` and `FRPW_UPDATE_REPO`; mirror downloads are tried in order, fall back to the canonical GitHub URL and must still match `SHA256SUMS`.
- Fixed the 卡密兑换 / 系统配置 state clash: the redeem shortcut used to overwrite the category 系统配置 remembered and therefore reopened 系统配置 on the redeem tab. The shortcut now pins its own tab per visit and leaves the settings page's selection untouched.

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
- Extended the paid-distribution license gate to `install-local.sh`: offline installs now verify the Ed25519-signed `FRPW_LICENSE` before touching any file and pass the key through to `install.sh`.
- Added prepaid redeem codes (card keys): admins generate `FRPW-` batches of 16-char codes in the new "redeem codes" settings category (balance face value or plan days, with optional expiry, per-code use cap, note, and enable/disable/delete), and users redeem them on the billing page of the user console. `(code_id, tenant_id)` is unique, so a tenant can redeem each code once; failed redemptions never consume uses, balance cards land in the immutable ledger as `redeem:<id>`, plan cards extend the current cycle in place, and the admin console lists every redemption across the platform. User-side submissions are rate limited to 10 attempts per minute.
- Added the announcement system: admins publish notices (info/success/warning/danger, pin, draft state, publish and expiry window) under the new "announcements and check-ins" admin section; the user console shows a sidebar unread badge, an overview banner, a list with per-notice and bulk read marks, and expired notices drop out of the feed automatically (read state is tracked per tenant in `announcement_reads`).
- Added daily check-in rewards: a platform-wide policy (enable switch, daily base amount, streak bonus, streak cap days) edited in the new "check-ins and rewards" settings category; each tenant can claim once per UTC+8 day, credits land in the immutable ledger as `checkin:<day>` with idempotent transactions, and both the user console (status KPIs, streak preview, history) and the admin console (today's count, 14-day trend, recent records) surface the data.
- Added usage recording: per-day traffic series plus per-tunnel / per-node / per-tenant breakdowns, powering a site-wide admin "data usage" section (traffic, requests, active tenants, three rankings) and a user-side usage view with 7/30/90-day ranges, a daily sparkline and tunnel/node rankings.
