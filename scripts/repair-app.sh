#!/usr/bin/env bash
#
# Repair and optionally package an existing DigitalPaper.app.
#
# This script intentionally does not build the project. It repairs the common
# release failure where the embedded DigitalPaperKit.framework and the outer
# application have incompatible signatures, causing dyld to reject the app at
# launch.
#
# Usage:
#   scripts/repair-app.sh /path/to/DigitalPaper.app
#
# Optional environment variables:
#   SIGN_IDENTITY             Signing identity; defaults to ad-hoc (-).
#   OPEN_AFTER_SIGNING        Set to 0 to skip opening the repaired app.
#   DIST                      Output directory for the repaired ZIP.
#   ZIP_NAME                  Output ZIP filename.
#   APP_ENTITLEMENTS          Entitlements file for the outer app.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  sed -n '2,22p' "$0"
  exit 2
}

APP_INPUT="${1:-${APP_PATH:-}}"
[[ -n "$APP_INPUT" ]] || usage

if [[ ! -d "$APP_INPUT" || ! "$(basename "$APP_INPUT")" == *.app ]]; then
  echo "Error: expected an existing .app bundle: $APP_INPUT" >&2
  exit 1
fi

APP_DIR="$(cd "$(dirname "$APP_INPUT")" && pwd)"
APP="$APP_DIR/$(basename "$APP_INPUT")"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
OPEN_AFTER_SIGNING="${OPEN_AFTER_SIGNING:-1}"
DIST="${DIST:-$APP_DIR/dist}"
ZIP_NAME="${ZIP_NAME:-$(basename "$APP" .app)-repaired.zip}"
ZIP="$DIST/$ZIP_NAME"
APP_ENTITLEMENTS="${APP_ENTITLEMENTS:-$ROOT_DIR/DigitalPaper/DigitalPaper.entitlements}"

for tool in codesign ditto; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Error: required macOS tool not found: $tool" >&2
    exit 1
  fi
done

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "==> Using ad-hoc signing for local repair"
  SIGN_ARGS=(--force --sign -)
else
  echo "==> Using signing identity: $SIGN_IDENTITY"
  SIGN_ARGS=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY")
fi

sign_embedded_code() {
  local item

  # Sign standalone dynamic libraries before framework bundles.
  if [[ -d "$APP/Contents/Frameworks" ]]; then
    while IFS= read -r -d '' item; do
      echo "==> Signing embedded library: $item"
      codesign "${SIGN_ARGS[@]}" "$item"
    done < <(find "$APP/Contents/Frameworks" -type f -name '*.dylib' -print0)

    # The framework must be signed before the outer application.
    while IFS= read -r -d '' item; do
      echo "==> Signing embedded framework: $item"
      codesign "${SIGN_ARGS[@]}" "$item"
    done < <(find "$APP/Contents/Frameworks" -type d -name '*.framework' -print0)
  fi
}

sign_outer_app() {
  local app_sign_args=("${SIGN_ARGS[@]}")

  if [[ -f "$APP_ENTITLEMENTS" ]]; then
    app_sign_args+=(--entitlements "$APP_ENTITLEMENTS")
  fi

  echo "==> Signing application: $APP"
  codesign "${app_sign_args[@]}" "$APP"
}

verify_bundle() {
  echo "==> Verifying nested code"
  if [[ -d "$APP/Contents/Frameworks" ]]; then
    while IFS= read -r -d '' item; do
      codesign --verify --strict --verbose=2 "$item"
    done < <(find "$APP/Contents/Frameworks" -type d -name '*.framework' -print0)
  fi

  echo "==> Verifying application"
  codesign --verify --deep --strict --verbose=2 "$APP"

  # Ad-hoc signatures are suitable for local repair but are not accepted by
  # Gatekeeper as a distributable Developer ID release. Only assess Gatekeeper
  # when a real signing identity was supplied.
  if [[ "$SIGN_IDENTITY" != "-" ]] && command -v spctl >/dev/null 2>&1; then
    spctl --assess --type execute --verbose=4 "$APP"
  fi
}

package_app() {
  mkdir -p "$DIST"
  rm -f "$ZIP"
  echo "==> Creating repaired archive: $ZIP"
  ditto --norsrc -c -k --keepParent "$APP" "$ZIP"
}

sign_embedded_code
sign_outer_app
verify_bundle
package_app

if [[ "$OPEN_AFTER_SIGNING" == "1" ]]; then
  echo "==> Opening repaired app"
  open -n "$APP"
  echo "==> Repaired app opened successfully: $APP"
fi

echo "==> Done: $ZIP"
