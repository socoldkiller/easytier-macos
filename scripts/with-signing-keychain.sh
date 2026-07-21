#!/usr/bin/env bash
set -euo pipefail

SIGNING_KEYCHAIN="${EASYTIER_CODESIGN_KEYCHAIN:-}"

if [[ "$#" -eq 0 ]]; then
  printf '%s\n' "Usage: $0 command [arguments ...]" >&2
  exit 64
fi

if [[ -z "$SIGNING_KEYCHAIN" ]]; then
  exec "$@"
fi

if [[ ! -f "$SIGNING_KEYCHAIN" ]]; then
  printf '%s\n' "Signing keychain does not exist: $SIGNING_KEYCHAIN" >&2
  exit 1
fi

original_keychains=()
while IFS= read -r keychain; do
  keychain="${keychain#\"}"
  keychain="${keychain%\"}"
  [[ -n "$keychain" ]] && original_keychains+=("$keychain")
done < <(security list-keychains -d user | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

keychain_was_added=0
for keychain in "${original_keychains[@]}"; do
  if [[ "$keychain" == "$SIGNING_KEYCHAIN" ]]; then
    exec "$@"
  fi
done

restore_keychains() {
  local command_status="$?"
  if [[ "$keychain_was_added" -eq 1 ]]; then
    security list-keychains -d user -s "${original_keychains[@]}" \
      || printf '%s\n' "Warning: could not restore the user keychain search list." >&2
  fi
  return "$command_status"
}
trap restore_keychains EXIT

security list-keychains -d user -s "$SIGNING_KEYCHAIN" "${original_keychains[@]}"
keychain_was_added=1

"$@"
