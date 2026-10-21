#!/usr/bin/env bash
# verify-gdrive.sh — end-to-end check that KIO GDrive can actually list your
# Google Drive files (i.e. the OAuth token now carries the Drive scope).
#
# NOTE: in kio-gdrive the ACCOUNT is the first PATH component, not the URL host:
#   gdrive://<any-host>/<account>/    → lists that account's Drive
#   gdrive://                         → lists local accounts only (no API call!)

set -uo pipefail

db="$HOME/.config/libaccounts-glib/accounts.db"
[[ -f $db ]] || { echo "no accounts.db — no Google account has been added"; exit 1; }

mapfile -t accounts < <(python3 - "$db" <<'EOF'
import sqlite3, sys
con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
for (name,) in con.execute("select name from accounts where provider='google'"):
    print(name)
EOF
)

if [[ ${#accounts[@]} -eq 0 ]]; then
    echo "no Google account in KAccounts — add one first (see README.md)"
    exit 1
fi

fail=0
for acct in "${accounts[@]}"; do
    echo "== Testing gdrive://g/${acct}/"
    out="$(timeout 60 kioclient ls "gdrive://g/${acct}/" 2>&1)"
    rc=$?
    if echo "$out" | grep -qi "access denied\|isn't a known\|Could not\|Malformed"; then
        echo "   FAILED: $out"
        fail=1
    elif [[ $rc -ne 0 ]]; then
        echo "   FAILED (exit $rc): $out"
        fail=1
    else
        n=$(echo "$out" | grep -vc -E '^\.$|^\.\.$|^$')
        echo "   OK — $n entries listed at the Drive root:"
        echo "$out" | grep -v -E '^\.$|^\.\.$|^$' | head -8 | sed 's/^/     - /'
        [[ $n -eq 0 ]] && echo "     (Drive root is empty — check drive.google.com in a browser)"
    fi
done
exit $fail
