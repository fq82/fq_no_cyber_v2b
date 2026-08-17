#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_BASE="$(mktemp -d /tmp/mc_cache_security.XXXXXX)"
trap 'rm -rf "$TMP_BASE"' EXIT

assert_contains() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" == *"$expected"* ]]; then
    printf '[PASS] %s (%s)\n' "$label" "$actual"
  else
    printf '[FAIL] %s: expected to contain %s, got %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
}

SITE="$TMP_BASE/plugin"
mkdir -p "$SITE/src/Support" "$SITE/storage"
cp "$PLUGIN_ROOT/src/Support/PlatformSettings.php" "$SITE/src/Support/PlatformSettings.php"
chmod 0700 "$SITE/storage"

cat > "$SITE/probe.php" <<'PHP'
<?php
require __DIR__ . '/src/Support/PlatformSettings.php';
$r = new ReflectionClass('CoverPlugin\\Support\\PlatformSettings');
$m = $r->getMethod('cachePath');
$m->setAccessible(true);
if (isset($argv[1]) && $argv[1] === 'path') {
    $path = $m->invoke(null);
    echo is_string($path) ? $path : "NULL", "\n";
    exit;
}
$result = CoverPlugin\Support\PlatformSettings::resolve();
echo json_encode($result), "\n";
PHP

export COVER_PANEL_URL=http://127.0.0.1
export COVER_PLUGIN_TOKEN=cache-test-token
export COVER_BOARD_ID=cache-test-board
CACHE_PATH="$(php "$SITE/probe.php" path)"
[[ "$CACHE_PATH" != "NULL" ]] || { echo '[FAIL] trusted storage path unexpectedly unavailable' >&2; exit 1; }

PAYLOAD="$(php -r '$p=json_encode(array("kill_subscribe"=>false,"exp"=>time()+300,"negative"=>false,"fetched_at"=>time())); echo $p;')"
SIG="$(PAYLOAD="$PAYLOAD" php -r 'echo hash_hmac("sha256", getenv("PAYLOAD"), getenv("COVER_PLUGIN_TOKEN"));')"
CONTAINER="$(PAYLOAD="$PAYLOAD" SIG="$SIG" php -r 'echo json_encode(array("payload"=>getenv("PAYLOAD"),"sig"=>getenv("SIG")));')"

printf '%s' "$CONTAINER" > "$CACHE_PATH"
chmod 0660 "$CACHE_PATH"
result="$(php "$SITE/probe.php")"
assert_contains 'group-writable cache rejected' '"kill_subscribe":true' "$result"
assert_contains 'group-writable cache fails closed' 'fail_closed_fallback' "$result"

printf '%s' "$CONTAINER" > "$CACHE_PATH"
chmod 0600 "$CACHE_PATH"
result="$(php "$SITE/probe.php")"
assert_contains 'strict private cache accepted' '"kill_subscribe":false' "$result"
assert_contains 'strict private cache source' '"source":"cache"' "$result"

printf '%s' "$CONTAINER" > "$TMP_BASE/cache-target"
chmod 0600 "$TMP_BASE/cache-target"
target_hash_before="$(shasum -a 256 "$TMP_BASE/cache-target" | awk '{print $1}')"
unlink "$CACHE_PATH"
ln -s "$TMP_BASE/cache-target" "$CACHE_PATH"
result="$(php "$SITE/probe.php")"
assert_contains 'cache symlink rejected' '"kill_subscribe":true' "$result"
assert_contains 'cache symlink fails closed' 'fail_closed_fallback' "$result"
[[ "$target_hash_before" == "$(shasum -a 256 "$TMP_BASE/cache-target" | awk '{print $1}')" ]] || {
  echo '[FAIL] cache symlink target was modified' >&2
  exit 1
}
echo '[PASS] cache symlink target unchanged'

unlink "$CACHE_PATH"
rmdir "$SITE/storage"
path_without_storage="$(php "$SITE/probe.php" path)"
[[ "$path_without_storage" == 'NULL' ]] || { echo "[FAIL] public fallback still selected: $path_without_storage" >&2; exit 1; }
echo '[PASS] no public temporary fallback'
