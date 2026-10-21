# KIO GDrive on Fedora KDE: "Access denied to ." — Root Cause & Fix

**Scope:** Fedora (tested on Fedora 44, KDE Plasma 6, Wayland) with `kio-gdrive` + KAccounts ("Online Accounts").
**Status (2026-10-21):** root cause fully identified and confirmed on a live system; fix kit provided.
**Author's test system:** Fedora 44, `kio-gdrive-26.08.1`, `kaccounts-integration-26.08.1`, `kaccounts-providers-26.08.1`, Plasma 6.

---

## TL;DR

Google **blocked KDE's shared OAuth client from using the Google Drive scope** in June 2024
(KDE bug [480779](https://bugs.kde.org/show_bug.cgi?id=480779); upstream removed the scope from
`google.provider` in kaccounts-providers 24.12.2, commit `1652091b` "Google: stop requesting gdrive permission").

Consequence: every Google account you add through **System Settings → Online Accounts** gets an
OAuth token *without* `https://www.googleapis.com/auth/drive`. KIO GDrive then shows the account
but every Drive API call fails:

> **Access denied to .**

The fix: use **your own Google OAuth client** (client ID + secret) in a user-local override of the
provider definition, and re-create the Google account so the token is issued with the Drive scope.
If your Google account is on your own **Google Workspace** domain (e.g. `you@yourdomain.com`), you
can create an **Internal** app — no verification, no token expiry, permanent fix.
Kit: [`fix-kio-gdrive-provider.sh`](fix-kio-gdrive-provider.sh) + [`verify-gdrive.sh`](verify-gdrive.sh).

---

## Symptoms

- Dolphin → Network → Google Drive → your account shows up, but the folder is empty and a red
  banner says **"Access denied to ."** ("Loading canceled").
- `kioclient ls 'gdrive://g/<account>/'` → `Access denied to .`
- `kioclient ls gdrive://` → lists your account fine (this listing is **local only** — it never
  calls the Drive API, which is why "the account is visible but the files are not").
- Online Accounts login flow *succeeds* (no error shown), because today's provider template no
  longer requests the Drive scope.
- Stale Dolphin tabs from older attempts may spam the journal with
  `"google4 isn't a known GDrive account"` (`google4` = provider name + old credentials id, from a
  time when the account had no display name). Close those tabs; it's unrelated to the scope issue.

## Root cause (evidence chain)

1. On Linux, `kio-gdrive` obtains tokens via **KAccounts**: `KAccountsManager::getAccountCredentials()`
   → `GetCredentialsJob` → signond. The requested OAuth **scope list is the one stored in the
   account's settings at creation time**, which comes from
   `/usr/share/accounts/providers/kde/google.provider`.
2. That template (identical in Fedora 44 and upstream master) requests only:
   `userinfo.email`, `userinfo.profile`, `calendar`, `tasks`, `contacts (m8/feeds)`, `youtube.upload` —
   **no `https://www.googleapis.com/auth/drive`**.
3. Why? Upstream commit
   [`1652091b`](https://invent.kde.org/network/kaccounts-providers/-/commit/1652091be7df65ea16e6eb6d044460c90c19b420)
   (2025-01-14, FIXED-IN 24.12.2):
   > *Google blocked us from using this back in June because we weren't able to justify our API
   > usage to their satisfaction. As such, the permission is now blocked, and including it here
   > prevents people from logging into their Google accounts for any other purposes.*
4. A token without the Drive scope makes every Drive API call return **403 insufficient
   permissions**, which kio-gdrive surfaces as `Access denied to .`
5. Verified on the test machine: the stored scope list for the account contains no `auth/drive`
   and the Drive listing fails with exactly that error; the KAccounts service `google-drive` is
   enabled — so this is *not* a "forgot to enable Drive" problem.

**Therefore:** no amount of removing/re-adding the account, restarting signond, or re-enabling the
"Drive" service will fix it — the scope is never requested in the first place. You must make the
OAuth request contain the Drive scope, which (because of Google's block on KDE's client) requires
**your own OAuth client**.

---

## The fix — decision tree

| Your Google account | Fix | Result |
|---|---|---|
| On your own Google **Workspace** domain (custom domain, e.g. `you@yourcompany.com`) | Own OAuth client, **Internal** app | ✅ Permanent. No verification, no token expiry. **Recommended.** |
| Plain **`@gmail.com`** | Own OAuth client, **External + Testing** | ⚠️ Works, but Google expires the refresh token **every 7 days** (re-login weekly). Prefer [rclone](#alternative-rclone-mount-works-for-everyone) instead. |
| Any account, wants zero setup | [rclone mount](#alternative-rclone-mount-works-for-everyone) | ✅ Works for everyone, different mechanism (FUSE mount, not `gdrive://`). |

> **Optional quick probe (undocumented, may break any time):** kio-gdrive's non-KAccounts backend
> (used on Windows) ships a *different* KDE OAuth client
> (`836279663462-qq9rt1k4smgqhvt461r6l54vo9qm09bg.apps.googleusercontent.com`). If that client is
> still allowed to use the Drive scope, you could patch the provider with *it* and skip the Google
> Cloud Console entirely. Probe by opening this URL in a browser and seeing whether Google shows a
> consent page instead of an "Access blocked" page:
> `https://accounts.google.com/o/oauth2/auth?client_id=836279663462-qq9rt1k4smgqhvt461r6l54vo9qm09bg.apps.googleusercontent.com&redirect_uri=urn:ietf:wg:oauth:2.0:oob&response_type=code&scope=https://www.googleapis.com/auth/drive`
> If it is blocked (expected), use your own client as described below.

---

## Fix steps (Workspace "Internal" app — permanent)

### A. Create your own OAuth client (~5 minutes, one time)

1. Sign in to <https://console.cloud.google.com> **with the Google account you use for Drive**
   (must be on the Workspace domain so you can pick *Internal*).
2. Create a project, e.g. `my-drive-kio` (top bar → project picker → *New project*).
3. **APIs & Services → Library** → search **"Google Drive API"** → **Enable**.
   *(Skipping this gives a 403 `accessNotConfigured` later.)*
4. **APIs & Services → OAuth consent screen** → User type: **Internal** → fill app name/support
   email → under *Scopes* add `.../auth/drive` (and optionally the calendar/tasks/contact ones if
   you also use those KDE features).
5. **APIs & Services → Credentials → Create credentials → OAuth client ID** →
   Application type: **Desktop app** → *Create*.
6. Copy the **Client ID** (ends in `.apps.googleusercontent.com`) and **Client secret**.

> Security note: a "Desktop app" client secret is an *installed-application* secret (KDE's own
> provider file embeds theirs the same way). It is still a secret: enter it **only** into the
> script's hidden prompt — never into chats, screenshots or bug reports.

### B. Install the provider override (no sudo needed)

```bash
git clone https://github.com/ritchiegerona/kio-gdrive-fix.git
cd kio-gdrive-fix
./fix-kio-gdrive-provider.sh apply     # prompts for Client ID / Secret (hidden)
```

The script:

- writes a patched `google.provider` (your client ID/secret **+ the Drive scope** + a marker
  description) to `~/kio-gdrive-fix/xdg-provider/accounts/providers/kde/google.provider`
  (mode `0600`),
- uses an `XDG_DATA_DIRS` override — verified to work because `libaccounts-glib` resolves providers
  from `$XDG_DATA_DIRS` (it does **not** read `~/.local/share` for providers, so a plain file copy
  there is ignored),
- self-verifies that libaccounts actually picks up the override.

### C. Re-create the Google account (must be redone!)

Existing accounts keep their old scope list — you **must remove and re-add**:

```bash
./fix-kio-gdrive-provider.sh launch    # opens Online Accounts KCM *with the override active*
```

1. In the KCM, **Remove** the existing Google account.
2. **Add new → Google** — the provider description will read
   *"Google — personal OAuth client (KIO GDrive fix)"* — that's how you know the override is live.
3. Log in; the consent screen shows **your** app name. Keep **Drive** enabled.
4. Done.

> Make sure no other `kcmshell6`/System Settings instance is running (the script checks and warns),
> otherwise the KCM window may reuse the *unpatched* running instance and silently miss the override.

### D. Verify

```bash
./verify-gdrive.sh
```

Expected:

```
== Testing gdrive://g/you@yourdomain.com/
   OK — 12 entries listed at the Drive root:
     - Documents
     - Screenshots
     ...
```

Then in Dolphin: **Network → Google Drive → your account** (or type `gdrive:/` in the location
bar). Re-open the previously broken tab — the stale "Access denied" view does not refresh by itself.

`./fix-kio-gdrive-provider.sh status` cross-checks that the override is installed **and** that the
account's stored scope list now contains `auth/drive`:

```
==> Stored Google account OAuth scopes (accounts.db):
account 'you@yourdomain.com' (id 3): drive scope PRESENT
```

---

## Alternative: rclone mount (works for everyone)

If your account is a plain `@gmail.com` (or you don't want to touch Google Cloud Console):

```bash
sudo dnf install rclone
rclone config                # n) new remote → name: gdrive → type: drive → accept defaults,
                             #    browser-login at the end; scope: full "drive" access
mkdir -p ~/GoogleDrive
```

Systemd user mount (`~/.config/systemd/user/rclone-gdrive.service`):

```ini
[Unit]
Description=Google Drive via rclone
[Service]
ExecStart=/usr/bin/rclone mount gdrive: %h/GoogleDrive \
  --vfs-cache-mode writes --dir-cache-time 12h --daemon-wait 30s
ExecStop=/bin/fusermount -u %h/GoogleDrive
Restart=on-failure
[Install]
WantedBy=default.target
```

```bash
systemctl --user enable --now rclone-gdrive.service
```

`~/GoogleDrive` then behaves like a normal folder in Dolphin (you can bookmark it via
*Places → Add entry*). rclone uses its own verified OAuth client, so there is no 7-day expiry.

---

## Troubleshooting

| Symptom | Cause → Fix |
|---|---|
| Login page shows **"Access blocked … has not completed the Google verification process"** | The auth request still used KDE's client → the KCM ran **without** the override. Close *all* System Settings windows and use `./fix-kio-gdrive-provider.sh launch`. |
| `status` says drive scope **MISSING** after re-adding | The account was created before the override was active → remove & re-add the account again (scopes are snapshotted at creation). |
| **"Access denied to ."** persists even with drive scope PRESENT | The **Google Drive API is not enabled** in your Cloud project (→ step A.3), or old kio workers still run: `killall gdrive.so 2>/dev/null`, log out/in, then re-test. |
| `accessNotConfigured` / 403 "Drive API has not been used in project…" | Enable the Drive API in *your* project (A.3). |
| `google4 isn't a known GDrive account` in journal | Stale Dolphin tab from an old attempt → close the tab. Harmless. |
| KCM never opens a login window | `signond`/`signon-ui` issue: `killall signond` (it is D-Bus-activated and restarts), ensure `kwalletd` is enabled (secrets are stored in KWallet via `signon-kwallet-extension`). |
| Works, then stops after ~1 week (consumer accounts) | Google's 7-day refresh-token expiry for unverified "Testing" apps → re-login, or switch to rclone. Workspace **Internal** apps do not expire. |
| Just want it gone | `./fix-kio-gdrive-provider.sh restore` and remove the Google account in Online Accounts. |

## Why this hack (and not something simpler)?

- **Reinstalling/upgrading won't help** — every current `kaccounts-providers` release ships the
  scope-less provider, by upstream decision.
- **The KAccounts "Drive" toggle is a red herring** — enabling the service only marks the service
  enabled; the scope comes from the provider template captured at account creation.
- **Patching `/usr/share/accounts/providers/kde/google.provider` directly** also works but needs
  sudo and is overwritten on package updates; the `XDG_DATA_DIRS` override survives updates and is
  per-user.
- **GNOME Online Accounts + gvfs** is a working alternative on Fedora (GNOME's client is still
  verified for Drive), but on KDE it drags in GNOME components; rclone is the cleaner cross-desktop
  option.

## References

- KDE bug 480779 — *Can not add Google to Online Accounts…* (the block):
  <https://bugs.kde.org/show_bug.cgi?id=480779>
- kaccounts-providers commit removing the scope:
  <https://invent.kde.org/network/kaccounts-providers/-/commit/1652091be7df65ea16e6eb6d044460c90c19b420>
- kio-gdrive (account handling): <https://invent.kde.org/network/kio-gdrive>
- libaccounts-glib provider lookup via `$XDG_DATA_DIRS` (empirically verified on Fedora 44)
- Google OAuth: restricted scopes & unverified apps:
  <https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification>

---

## Shareable summary (paste into forum posts / bug reports)

> **KIO GDrive "Access denied to ." after adding a Google account — root cause: Google blocked
> KDE's OAuth client from using the Drive scope (KDE bug 480779, kaccounts-providers commit
> 1652091b). Online Accounts therefore issues tokens without
> `https://www.googleapis.com/auth/drive`, and every Drive API call 403s. Nothing is wrong with
> your local setup. Fix: create your own OAuth client (Google Cloud Console → enable Google Drive
> API → OAuth consent screen Internal if Workspace, else External/Testing → "Desktop app"
> credentials) and use a user-local provider override via `XDG_DATA_DIRS` that injects your
> client ID/secret plus the Drive scope, then remove and re-add the Google account. Ready-made
> scripts + full write-up: <https://github.com/ritchiegerona/kio-gdrive-fix> (rclone mount is the
> low-effort alternative for @gmail.com accounts).**

---

## Update (2026-10-21): installed on the author's machine via rclone (personal @gmail)

For a personal `@gmail.com` account the rclone path was chosen. Notes from the live install
(rclone v1.75.2, Fedora 44):

- `downloads.rclone.org` timed out on this connection; the GitHub release asset downloaded fine:
  `https://github.com/rclone/rclone/releases/download/v1.75.2/rclone-v1.75.2-linux-amd64.zip`
  → install to `~/.local/bin/rclone` (no sudo needed).
- Non-interactive remote creation: `rclone config create gdrive drive scope drive --non-interactive`
- `rclone config reconnect gdrive:` now asks **two** interactive questions (v1.75+: "Continue using
  the shared client_id anyway?" and "Use web browser to automatically authenticate?") — answer `y`
  to both (`printf 'y\ny\n' | rclone config reconnect gdrive:`), the browser opens and stores the
  token automatically.
- ⚠️ rclone warns its **shared Drive client_id is being retired during 2026**. When that time
  comes (or proactively), create your own client_id (same Console steps as in the kio-gdrive fix,
  section A) and run `rclone config reconnect gdrive:` with it — the *same* OAuth client can then
  also power native kio-gdrive via the provider override, if ever wanted.
- Auto-mount unit: `~/.config/systemd/user/rclone-gdrive.service` (see snippet above),
  `systemctl --user enable --now rclone-gdrive` — verified: `findmnt ~/GoogleDrive` shows
  `fuse.rclone`, files listed by Dolphin.
