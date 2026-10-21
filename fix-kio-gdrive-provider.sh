#!/usr/bin/env bash
# fix-kio-gdrive-provider.sh — make KIO GDrive work again after Google blocked
# KDE's OAuth client for the Drive scope (https://bugs.kde.org/480779).
#
# It generates a user-local override of the KAccounts "google" provider that
# uses YOUR OWN Google OAuth client and requests the Drive scope, then launches
# the Online Accounts KCM with XDG_DATA_DIRS pointed at the override.
#
# No sudo, no system files touched. Fully reversible (see: restore).
#
# Usage:
#   ./fix-kio-gdrive-provider.sh apply      # patch provider (prompts for client id/secret)
#   ./fix-kio-gdrive-provider.sh launch     # open Online Accounts KCM with the override
#   ./fix-kio-gdrive-provider.sh status     # check override + stored account scopes
#   ./fix-kio-gdrive-provider.sh restore    # remove the override
#   ./fix-kio-gdrive-provider.sh selftest   # validate the patcher with dummy values

set -euo pipefail

FIX_DIR="${FIX_DIR:-$HOME/kio-gdrive-fix}"
OVERRIDE_ROOT="$FIX_DIR/xdg-provider"
DEST="$OVERRIDE_ROOT/accounts/providers/kde/google.provider"
SRC="/usr/share/accounts/providers/kde/google.provider"
MARKER="Google — personal OAuth client (KIO GDrive fix)"
DRIVE_SCOPE="https://www.googleapis.com/auth/drive"

say() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

pygi_check() {
    XDG_DATA_DIRS="$OVERRIDE_ROOT:/usr/share" python3 - <<'EOF' 2>/dev/null
import gi
gi.require_version('Accounts', '1.0')
from gi.repository import Accounts
p = Accounts.Manager.new().get_provider('google')
print(p.get_description())
EOF
}

patch_provider() {
    local src="$1" dest="$2"
    # Client id/secret arrive via env (never as argv, keeps them out of `ps`).
    python3 - "$src" "$dest" <<'EOF'
import ast, os, sys
import xml.etree.ElementTree as ET

src, dest = sys.argv[1], sys.argv[2]
client_id = os.environ["GDRIVE_CLIENT_ID"].strip()
client_secret = os.environ["GDRIVE_CLIENT_SECRET"].strip()

assert client_id.endswith(".apps.googleusercontent.com"), "Client ID should end in .apps.googleusercontent.com"
assert len(client_secret) >= 10, "Client Secret looks too short"

tree = ET.parse(src)
root = tree.getroot()

for tag, val in (("ClientId", client_id), ("ClientSecret", client_secret)):
    el = root.find(f".//setting[@name='{tag}']")
    if el is None:
        sys.exit(f"template setting {tag} not found in {src}")
    el.text = val

scope_el = root.find(".//setting[@name='Scope']")
scopes = ast.literal_eval(scope_el.text)
DRIVE = "https://www.googleapis.com/auth/drive"
if DRIVE not in scopes:
    scopes.append(DRIVE)
scope_el.text = repr(scopes)

desc = root.find("description")
if desc is not None:
    desc.text = "Google — personal OAuth client (KIO GDrive fix)"

ET.indent(tree, space="  ")
tree.write(dest, encoding="UTF-8", xml_declaration=True)

# Validate what we wrote
t2 = ET.parse(dest)
r2 = t2.getroot()
assert r2.find(".//setting[@name='ClientId']").text == client_id
assert r2.find(".//setting[@name='ClientSecret']").text == client_secret
assert DRIVE in ast.literal_eval(r2.find(".//setting[@name='Scope']").text)
print("patched OK:", dest)
EOF
}

check_db_scopes() {
    python3 - <<'EOF' 2>/dev/null
import ast, sqlite3, glob, os
db = os.path.expanduser("~/.config/libaccounts-glib/accounts.db")
if not os.path.exists(db):
    print("no accounts.db — no Google account added yet")
    raise SystemExit(0)
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
cur = con.cursor()
try:
    rows = cur.execute(
        "select a.id, a.name, s.value from Accounts a "
        "join Settings s on s.account=a.id and s.key='auth/oauth2/web_server/Scope' "
        "where a.provider='google'").fetchall()
except sqlite3.OperationalError:
    print("could not read settings table"); raise SystemExit(0)
if not rows:
    print("no google accounts with stored OAuth scope")
for aid, name, val in rows:
    try:
        scopes = ast.literal_eval(val)
    except Exception:
        scopes = [val]
    has = any("auth/drive" in s for s in scopes)
    print(f"account '{name}' (id {aid}): drive scope {'PRESENT' if has else 'MISSING'}")
EOF
}

cmd="${1:-apply}"
case "$cmd" in
    apply)
        [[ -f $SRC ]] || die "system provider not found at $SRC (is kaccounts-providers installed?)"
        say "Enter YOUR Google OAuth client (see README.md — Google Cloud Console, 'Desktop app' type)."
        say "Values are read with hidden input and kept in a local root-0600 file, never in chat."
        read -rp "Client ID: " GDRIVE_CLIENT_ID
        read -rsp "Client Secret: " GDRIVE_CLIENT_SECRET; echo
        export GDRIVE_CLIENT_ID GDRIVE_CLIENT_SECRET
        mkdir -p "$(dirname "$DEST")"
        patch_provider "$SRC" "$DEST"
        chmod 600 "$DEST"
        unset GDRIVE_CLIENT_ID GDRIVE_CLIENT_SECRET
        say "Verifying that libaccounts picks up the override..."
        got="$(pygi_check || true)"
        [[ "$got" == "$MARKER" ]] || die "override not visible to libaccounts-glib (got: '${got:-nothing}')"
        say "Override is active: provider description now reads \"$got\""
        say "Next steps:"
        echo "  1. Close any open System Settings / Online Accounts window."
        echo "  2. Run:  $FIX_DIR/fix-kio-gdrive-provider.sh launch"
        echo "  3. REMOVE your existing Google account, then ADD it again (login),"
        echo "     and make sure 'Drive' stays enabled. Old accounts keep old scopes!"
        echo "  4. Verify:  $FIX_DIR/verify-gdrive.sh"
        ;;
    launch)
        [[ -f $DEST ]] || die "no override yet — run 'apply' first"
        if pgrep -u "$USER" -f kcmshell6 >/dev/null 2>&1; then
            say "A kcmshell6 process is already running — close System Settings windows first!"
            pgrep -a -u "$USER" -f kcmshell6 || true
            read -rp "Press Enter once closed (or Ctrl+C to abort)..."
        fi
        say "Launching Online Accounts with the patched provider..."
        exec env XDG_DATA_DIRS="$OVERRIDE_ROOT:/usr/share" kcmshell6 kcm_accounts
        ;;
    status)
        if [[ -f $DEST ]]; then
            say "Override file exists: $DEST"
            grep -o "personal OAuth client" "$DEST" >/dev/null && echo "  description marker: OK"
            grep -q "$DRIVE_SCOPE" "$DEST" && echo "  drive scope in template: OK" || echo "  drive scope in template: MISSING"
            grep -o "<setting name=\"ClientId\">[^<]*" "$DEST" | sed 's/.*>/  ClientId: /'
        else
            say "No override installed ($DEST missing)."
        fi
        say "Stored Google account OAuth scopes (accounts.db):"
        check_db_scopes
        ;;
    restore)
        rm -rf "$OVERRIDE_ROOT"
        say "Override removed. (Already-created accounts keep their settings; remove them in Online Accounts if you want a clean slate.)"
        ;;
    selftest)
        export GDRIVE_CLIENT_ID="111111111111-dummyclientid1234567890abcdef.apps.googleusercontent.com"
        export GDRIVE_CLIENT_SECRET="DUMMY-SECRET-fOr-SelfTeSt-0123456789"
        tmp="$OVERRIDE_ROOT/accounts/providers/kde/google.provider"
        mkdir -p "$(dirname "$tmp")"
        patch_provider "$SRC" "$tmp"
        chmod 600 "$tmp"
        got="$(pygi_check || true)"
        [[ "$got" == "$MARKER" ]] || { rm -rf "$OVERRIDE_ROOT"; die "selftest FAILED (override not visible)"; }
        rm -rf "$OVERRIDE_ROOT"
        say "selftest PASSED (dummy override applied, seen by libaccounts, then removed)"
        ;;
    *)
        die "unknown command: $cmd (use apply|launch|status|restore|selftest)"
        ;;
esac
