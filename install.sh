#!/usr/bin/env bash
# Per-user install: no root needed. Assumes cecd is already set up (see README).
set -euo pipefail
cd "$(dirname "$0")"

install -Dm755 cec-sidecar "$HOME/.local/bin/cec-sidecar"
install -Dm644 systemd/cec-sidecar.service "$HOME/.config/systemd/user/cec-sidecar.service"

if [[ "${1:-}" == "--with-cecd-config" ]]; then
    dest="$HOME/.config/cecd/config.d/90-local.toml"
    if [[ -e "$dest" ]]; then
        echo "Not overwriting existing $dest" >&2
    else
        install -Dm644 examples/cecd/90-local.toml "$dest"
        echo "Installed example cecd config to $dest"
    fi
fi

systemctl --user daemon-reload
# cecd must be enabled for the helper (bound to it) to start at login.
systemctl --user enable cecd.service
systemctl --user enable cec-sidecar.service
systemctl --user restart cecd.service
echo "Done. Check: systemctl --user status cecd cec-sidecar"
