#!/bin/bash
# Shared contract for any script that can replace a canonical app in /Applications.
# The caller must pass an explicit release request and the fully signed source bundle.
production_install_guard() {
  local release_requested="${1:-0}"
  local app_bundle="${2:-}"
  local signature=""

  if [[ "$release_requested" != "1" ]]; then
    echo "ABORT: canonical /Applications install requires explicit release mode." >&2
    return 64
  fi

  if [[ -z "$app_bundle" || ! -d "$app_bundle" ]]; then
    echo "ABORT: release bundle is missing: $app_bundle" >&2
    return 65
  fi

  if ! signature="$(codesign -dvvv "$app_bundle" 2>&1)"; then
    echo "ABORT: release bundle signature could not be inspected: $app_bundle" >&2
    return 65
  fi

  if [[ "$signature" == *"Signature=adhoc"* ]] ||
     [[ "$signature" != *"Authority=Developer ID Application:"* ]]; then
    echo "ABORT: canonical /Applications install requires a non-ad-hoc Developer ID Application signature." >&2
    return 65
  fi
}
