#!/usr/bin/env bash
# Run analysis and tests for every package and the Flutter app.
#
# --no-tests runs the format and analysis gates only. CI pairs it with
# scripts/coverage.sh, which runs the same tests once with instrumentation.
set -euo pipefail

cd "$(dirname "$0")/.."

DART="${DART:-dart}"
FLUTTER="${FLUTTER:-flutter}"

run_tests=1
case "${1:-}" in
  "") ;;
  --no-tests) run_tests=0 ;;
  *)
    echo "usage: $0 [--no-tests]" >&2
    exit 64
    ;;
esac

echo "== pub get =="
for pkg in mesh_protocol device_link test_support companion_client ota_core wifi_ota_core; do
  (cd "packages/$pkg" && "$DART" pub get >/dev/null)
done
# Formatting uses the language version from .dart_tool/package_config.json;
# without it the bench falls back to the SDK's version and reformats.
(cd bench && "$DART" pub get >/dev/null)
(cd app && "$FLUTTER" pub get >/dev/null)

echo "== build scripts =="
./scripts/test_build_metadata.sh

echo "== format =="
"$DART" format --output=none --set-exit-if-changed \
  packages app/lib app/test app/integration_test tool bench

for pkg in mesh_protocol device_link test_support companion_client ota_core wifi_ota_core; do
  echo "== packages/$pkg =="
  (
    cd "packages/$pkg"
    "$DART" analyze
    if [[ "$run_tests" == 1 ]]; then
      "$DART" test
    fi
  )
done

# The hardware bench is not run in CI, but it must still compile and stay
# formatted — its rot is otherwise invisible until someone needs a radio.
echo "== bench =="
(
  cd bench
  "$DART" analyze
)

echo "== app =="
(
  cd app
  "$FLUTTER" analyze
  if [[ "$run_tests" == 1 ]]; then
    "$FLUTTER" test
  fi
)

if [[ "$run_tests" == 1 ]]; then
  echo "All checks passed."
else
  echo "Analysis passed (tests skipped)."
fi
