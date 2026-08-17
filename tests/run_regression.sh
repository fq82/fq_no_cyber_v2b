#!/usr/bin/env bash
# MediaCover 插件全量自动化回归测试矩阵 (Regression Test Suite)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  [PASS] $label (value: $actual)"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] $label - Expected: '$expected', Got: '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

echo "=========================================================="
echo " Running MediaCover Plugin Comprehensive Test Matrix"
echo "=========================================================="

TMP_BASE="$(mktemp -d /tmp/mc_test_board.XXXXXX)"
trap 'rm -rf "$TMP_BASE"' EXIT

# 1. 测试普通全新安装与 UTF-8 BOM 入口
echo "Test 1: Fresh install with UTF-8 BOM index.php"
SITE1="$TMP_BASE/site1"
mkdir -p "$SITE1/public"
printf '\xef\xbb\xbf<?php\n\ndeclare(strict_types=1);\n\necho "original_site_1";\n' > "$SITE1/public/index.php"
echo "APP_NAME=Site1" > "$SITE1/.env"

COVER_PANEL_URL="https://kaka2.lol" COVER_TENANT_ID="ten_test" COVER_BOARD_ID="board_test" COVER_PLUGIN_TOKEN="ptk_test" \
  bash "$PLUGIN_ROOT/install.sh" "$SITE1" >/dev/null

hook_cnt=$(grep -c 'Cover plugin (non-invasive, auto)' "$SITE1/public/index.php" || true)
assert_eq "Loader hooked block count" "1" "$hook_cnt"

# 检查 BOM 已经被剥离且开头是 <?php
first_bytes=$(head -c 5 "$SITE1/public/index.php")
assert_eq "Index starts with <?php" "<?php" "$first_bytes"

# 2. 测试幂等性：重复安装
echo "Test 2: Idempotent repeat installation"
COVER_PANEL_URL="https://kaka2.lol" COVER_TENANT_ID="ten_test" COVER_BOARD_ID="board_test" COVER_PLUGIN_TOKEN="ptk_test" \
  bash "$PLUGIN_ROOT/install.sh" "$SITE1" >/dev/null

hook_cnt2=$(grep -c 'Cover plugin (non-invasive, auto)' "$SITE1/public/index.php" || true)
assert_eq "Loader still has exactly 1 block" "1" "$hook_cnt2"

# 3. 测试卸载与清理
echo "Test 3: Uninstallation and clean rollback"
bash "$PLUGIN_ROOT/install.sh" uninstall "$SITE1" >/dev/null
hook_cnt_un=$(grep -c 'Cover plugin' "$SITE1/public/index.php" || true)
assert_eq "Loader count after uninstall" "0" "$hook_cnt_un"
env_has_cover=$(grep -c 'COVER_' "$SITE1/.env" || true)
assert_eq "Env COVER_* count after uninstall" "0" "$env_has_cover"

# 4. 字节级快照恢复：BOM、CRLF 和非 UTF-8 字节必须保持不变
echo "Test 4: Byte-preserving snapshot rollback"
SITE_BYTES="$TMP_BASE/site_bytes"
mkdir -p "$SITE_BYTES/public"
python3 - "$SITE_BYTES/public/index.php" "$SITE_BYTES/.env" <<'PY'
import sys
idx, env = sys.argv[1:]
open(idx, 'wb').write(b'\xef\xbb\xbf<?php\r\n// original\xc3\xa9\r\n')
open(env, 'wb').write(b'APP_NAME=bytes\r\nRAW=\xff\xfe\r\n')
PY
idx_hash_before=$(shasum -a 256 "$SITE_BYTES/public/index.php" | awk '{print $1}')
env_hash_before=$(shasum -a 256 "$SITE_BYTES/.env" | awk '{print $1}')
COVER_PANEL_URL="https://kaka2.lol" COVER_TENANT_ID="ten_test" COVER_BOARD_ID="board_bytes" COVER_PLUGIN_TOKEN="ptk_test" \
  bash "$PLUGIN_ROOT/install.sh" "$SITE_BYTES" >/dev/null
# 非 UTF-8 字节必须在生效入口中保留；重复安装也不能因文本解码而改变它们。
invalid_bytes_present=$(python3 - "$SITE_BYTES/public/index.php" <<'PY'
import sys
raw = open(sys.argv[1], 'rb').read()
print(1 if b'\xc3\xa9' in raw else 0)
PY
)
assert_eq "Non-UTF8 bytes preserved during hook" "1" "$invalid_bytes_present"
installed_idx_hash=$(shasum -a 256 "$SITE_BYTES/public/index.php" | awk '{print $1}')
COVER_PANEL_URL="https://kaka2.lol" COVER_TENANT_ID="ten_test" COVER_BOARD_ID="board_bytes" COVER_PLUGIN_TOKEN="ptk_test" \
  bash "$PLUGIN_ROOT/install.sh" "$SITE_BYTES" >/dev/null
assert_eq "Non-UTF8 repeat install is stable" "$installed_idx_hash" "$(shasum -a 256 "$SITE_BYTES/public/index.php" | awk '{print $1}')"
bash "$PLUGIN_ROOT/install.sh" uninstall "$SITE_BYTES" >/dev/null
assert_eq "Index byte snapshot hash" "$idx_hash_before" "$(shasum -a 256 "$SITE_BYTES/public/index.php" | awk '{print $1}')"
assert_eq "Env byte snapshot hash" "$env_hash_before" "$(shasum -a 256 "$SITE_BYTES/.env" | awk '{print $1}')"

# 5. symlink 入口必须拒绝卸载，且不能覆盖链接目标
echo "Test 5: Symlink-safe uninstall"
SITE_LINK="$TMP_BASE/site_link"
mkdir -p "$SITE_LINK/public"
printf '%s\n' '<?php' 'echo "link";' > "$SITE_LINK/public/index.php"
printf '%s\n' 'APP_NAME=link' > "$SITE_LINK/.env"
COVER_PANEL_URL="https://kaka2.lol" COVER_TENANT_ID="ten_test" COVER_BOARD_ID="board_link" COVER_PLUGIN_TOKEN="ptk_test" \
  bash "$PLUGIN_ROOT/install.sh" "$SITE_LINK" >/dev/null
printf '%s\n' 'outside' > "$SITE_LINK/outside.txt"
unlink "$SITE_LINK/public/index.php"
ln -s "$SITE_LINK/outside.txt" "$SITE_LINK/public/index.php"
outside_hash_before=$(shasum -a 256 "$SITE_LINK/outside.txt" | awk '{print $1}')
set +e
bash "$PLUGIN_ROOT/install.sh" uninstall "$SITE_LINK" >/dev/null 2>&1
link_uninstall_rc=$?
set -e
assert_eq "Symlink uninstall exit" "1" "$link_uninstall_rc"
assert_eq "Symlink target unchanged" "$outside_hash_before" "$(shasum -a 256 "$SITE_LINK/outside.txt" | awk '{print $1}')"
assert_eq "Plugin retained after symlink refusal" "1" "$([[ -d "$SITE_LINK/cover-plugin" ]] && echo 1 || echo 0)"

# 6. 插件目录本身为 symlink 时必须拒绝，不能跟随链接写到站点外
echo "Test 6: Symlink-safe plugin directory"
SITE_PLUGIN_LINK="$TMP_BASE/site_plugin_link"
PLUGIN_OUTSIDE="$TMP_BASE/plugin-outside"
mkdir -p "$SITE_PLUGIN_LINK/public" "$PLUGIN_OUTSIDE"
printf '%s\n' '<?php' 'echo "plugin-link";' > "$SITE_PLUGIN_LINK/public/index.php"
printf '%s\n' 'outside-plugin-marker' > "$PLUGIN_OUTSIDE/marker"
ln -s "$PLUGIN_OUTSIDE" "$SITE_PLUGIN_LINK/cover-plugin"
idx_hash_before=$(shasum -a 256 "$SITE_PLUGIN_LINK/public/index.php" | awk '{print $1}')
set +e
COVER_PANEL_URL="https://kaka2.lol" COVER_TENANT_ID="ten_test" COVER_BOARD_ID="board_plugin_link" COVER_PLUGIN_TOKEN="ptk_test" \
  bash "$PLUGIN_ROOT/install.sh" "$SITE_PLUGIN_LINK" >/dev/null 2>&1
plugin_link_rc=$?
set -e
assert_eq "Symlink plugin install exit" "1" "$plugin_link_rc"
assert_eq "Symlink plugin entry unchanged" "$idx_hash_before" "$(shasum -a 256 "$SITE_PLUGIN_LINK/public/index.php" | awk '{print $1}')"
assert_eq "Symlink plugin target unchanged" "outside-plugin-marker" "$(cat "$PLUGIN_OUTSIDE/marker")"
assert_eq "Symlink plugin retained" "1" "$([[ -L "$SITE_PLUGIN_LINK/cover-plugin" ]] && echo 1 || echo 0)"

# 7. 无快照且无 python3 时必须失败，不能清空 .env 或删除插件
echo "Test 7: No-python uninstall fails closed"
SITE_NOP="${TMP_BASE}/site_nopython"
FAKE_BIN="${TMP_BASE}/fake-bin"
mkdir -p "$SITE_NOP/public" "$FAKE_BIN"
printf '%s\n' '<?php' 'echo "nopython";' > "$SITE_NOP/public/index.php"
printf '%s\n' 'APP_NAME=nopython' 'COVER_PLUGIN_TOKEN=secret' > "$SITE_NOP/.env"
COVER_PANEL_URL="https://kaka2.lol" COVER_TENANT_ID="ten_test" COVER_BOARD_ID="board_nopython" COVER_PLUGIN_TOKEN="ptk_test" \
  bash "$PLUGIN_ROOT/install.sh" "$SITE_NOP" >/dev/null
unlink "$SITE_NOP/cover-plugin/storage/index_original.bak"
unlink "$SITE_NOP/cover-plugin/storage/index_original.path"
unlink "$SITE_NOP/cover-plugin/storage/env_original.bak"
for cmd in stat chmod chown id dirname mv rm grep; do ln -s "$(command -v "$cmd")" "$FAKE_BIN/$cmd"; done
env_hash_before=$(shasum -a 256 "$SITE_NOP/.env" | awk '{print $1}')
set +e
PATH="$FAKE_BIN" /bin/bash "$PLUGIN_ROOT/install.sh" uninstall "$SITE_NOP" >/dev/null 2>&1
nopython_rc=$?
set -e
assert_eq "No-python uninstall exit" "1" "$nopython_rc"
assert_eq "No-python env unchanged" "$env_hash_before" "$(shasum -a 256 "$SITE_NOP/.env" | awk '{print $1}')"
assert_eq "No-python plugin retained" "1" "$([[ -d "$SITE_NOP/cover-plugin" ]] && echo 1 || echo 0)"

# 8. 即使存在 Python3，无快照也必须拒绝有损文本卸载
echo "Test 8: No-snapshot uninstall fails closed"
SITE_NO_SNAPSHOT="$TMP_BASE/site_no_snapshot"
mkdir -p "$SITE_NO_SNAPSHOT/public"
printf '%s\n' '<?php' 'echo "no snapshot";' > "$SITE_NO_SNAPSHOT/public/index.php"
printf '%s\n' 'APP_NAME=no_snapshot' > "$SITE_NO_SNAPSHOT/.env"
COVER_PANEL_URL="https://kaka2.lol" COVER_TENANT_ID="ten_test" COVER_BOARD_ID="board_no_snapshot" COVER_PLUGIN_TOKEN="ptk_test" \
  bash "$PLUGIN_ROOT/install.sh" "$SITE_NO_SNAPSHOT" >/dev/null
unlink "$SITE_NO_SNAPSHOT/cover-plugin/storage/index_original.bak"
unlink "$SITE_NO_SNAPSHOT/cover-plugin/storage/index_original.path"
unlink "$SITE_NO_SNAPSHOT/cover-plugin/storage/env_original.bak"
idx_hash_before=$(shasum -a 256 "$SITE_NO_SNAPSHOT/public/index.php" | awk '{print $1}')
env_hash_before=$(shasum -a 256 "$SITE_NO_SNAPSHOT/.env" | awk '{print $1}')
set +e
bash "$PLUGIN_ROOT/install.sh" uninstall "$SITE_NO_SNAPSHOT" >/dev/null 2>&1
no_snapshot_rc=$?
set -e
assert_eq "No-snapshot uninstall exit" "1" "$no_snapshot_rc"
assert_eq "No-snapshot index unchanged" "$idx_hash_before" "$(shasum -a 256 "$SITE_NO_SNAPSHOT/public/index.php" | awk '{print $1}')"
assert_eq "No-snapshot env unchanged" "$env_hash_before" "$(shasum -a 256 "$SITE_NO_SNAPSHOT/.env" | awk '{print $1}')"
assert_eq "No-snapshot plugin retained" "1" "$([[ -d "$SITE_NO_SNAPSHOT/cover-plugin" ]] && echo 1 || echo 0)"

# 9. 原入口被删除时必须保留插件和快照，不能报告卸载成功
echo "Test 9: Missing target keeps recovery snapshots"
SITE_MISSING="$TMP_BASE/site_missing"
mkdir -p "$SITE_MISSING/public"
printf '%s\n' '<?php' 'echo "missing";' > "$SITE_MISSING/public/index.php"
printf '%s\n' 'APP_NAME=missing' > "$SITE_MISSING/.env"
COVER_PANEL_URL="https://kaka2.lol" COVER_TENANT_ID="ten_test" COVER_BOARD_ID="board_missing" COVER_PLUGIN_TOKEN="ptk_test" \
  bash "$PLUGIN_ROOT/install.sh" "$SITE_MISSING" >/dev/null
unlink "$SITE_MISSING/public/index.php"
set +e
bash "$PLUGIN_ROOT/install.sh" uninstall "$SITE_MISSING" >/dev/null 2>&1
missing_target_rc=$?
set -e
assert_eq "Missing target uninstall exit" "1" "$missing_target_rc"
assert_eq "Missing target plugin retained" "1" "$([[ -d "$SITE_MISSING/cover-plugin" ]] && echo 1 || echo 0)"
assert_eq "Missing target snapshot retained" "1" "$([[ -f "$SITE_MISSING/cover-plugin/storage/index_original.bak" ]] && echo 1 || echo 0)"

# 10. 非 regular snapshot 必须让安装失败，不能静默降级为有损卸载
echo "Test 10: Invalid snapshot target fails installation"
SITE_BAD_SNAPSHOT="$TMP_BASE/site_bad_snapshot"
mkdir -p "$SITE_BAD_SNAPSHOT/public" "$SITE_BAD_SNAPSHOT/cover-plugin/storage/index_original.bak"
printf '%s\n' '<?php' 'echo "bad snapshot";' > "$SITE_BAD_SNAPSHOT/public/index.php"
printf '%s\n' 'APP_NAME=bad_snapshot' > "$SITE_BAD_SNAPSHOT/.env"
set +e
COVER_PANEL_URL="https://kaka2.lol" COVER_TENANT_ID="ten_test" COVER_BOARD_ID="board_bad_snapshot" COVER_PLUGIN_TOKEN="ptk_test" \
  bash "$PLUGIN_ROOT/install.sh" "$SITE_BAD_SNAPSHOT" >/dev/null 2>&1
bad_snapshot_rc=$?
set -e
assert_eq "Invalid snapshot install exit" "1" "$bad_snapshot_rc"
assert_eq "Invalid snapshot leaves entry unhooked" "0" "$(grep -c 'Cover plugin' "$SITE_BAD_SNAPSHOT/public/index.php" || true)"

# 11. 测试递归 URL 编码与安全拦截状态机
echo "Test 11: Recursive URL decoding and subscription kill switch"

test_uri() {
  local uri="$1"
  local raw
  raw=$(php -r '
    $_SERVER["REQUEST_URI"] = $argv[1];
    $_ENV["COVER_KILL_SUBSCRIBE"] = "1";
    $_ENV["COVER_PANEL_URL"] = "https://kaka2.lol";
    $_ENV["COVER_PLUGIN_TOKEN"] = "ptk_test";
    require "'"$PLUGIN_ROOT"'/src/bootstrap.php";
  ' "$uri" 2>/dev/null || true)
  if echo "$raw" | grep -q '"code":404'; then
    echo "404"
  else
    echo "200"
  fi
}

r1=$(test_uri "/api/v1/client/subscribe")
assert_eq "Normal subscribe blocked" "404" "$r1"

r2=$(test_uri "/api/v1/client/%73ubscribe")
assert_eq "Single encoded %73ubscribe blocked" "404" "$r2"

r3=$(test_uri "/api/v1/client/%25252573ubscribe")
assert_eq "Quadruple encoded subscribe blocked" "404" "$r3"

# 17 层超多重百分号编码 (测试 V10-01)
encode17="/%2525252525252525252525252525252573/abc"
r17=$(test_uri "$encode17")
assert_eq "17-layer encoded subscribe/shortlink blocked" "404" "$r17"

r4=$(test_uri "/%25252573/abc")
assert_eq "Quadruple encoded short link /s/ blocked" "404" "$r4"

r5=$(test_uri "/api/v1/passport/auth/login")
assert_eq "Normal login route passed" "200" "$r5"

echo "=========================================================="
echo " Test Summary: $PASS Passed, $FAIL Failed"
echo "=========================================================="

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
