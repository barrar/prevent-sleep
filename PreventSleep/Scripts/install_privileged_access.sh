#!/bin/bash
set -euo pipefail

USERNAME="${1:-}"
TARGET_FILE="/etc/sudoers.d/preventsleep"
TMP_FILE="$(mktemp /tmp/preventsleep_sudoers.XXXXXX)"

cleanup() {
  rm -f "$TMP_FILE"
}
trap cleanup EXIT

if [[ -z "$USERNAME" ]]; then
  echo "Usage: $0 <username>" >&2
  exit 1
fi

if [[ ! "$USERNAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "Invalid username: $USERNAME" >&2
  exit 1
fi

cat > "$TMP_FILE" <<EOF
# Managed by PreventSleep
$USERNAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset sleepnow
EOF

/bin/chown root:wheel "$TMP_FILE"
/bin/chmod 440 "$TMP_FILE"
/usr/sbin/visudo -cf "$TMP_FILE" >/dev/null
/bin/mv "$TMP_FILE" "$TARGET_FILE"

echo "Installed $TARGET_FILE"
