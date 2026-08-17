#!/usr/bin/env bash
# MediaCover 插件非侵入安装 / 卸载 (具备完整原子快照与字节级无损卸载)
# 安装:
#   COVER_PANEL_URL=... COVER_TENANT_ID=... COVER_BOARD_ID=... COVER_PLUGIN_TOKEN=... \
#     bash install.sh /path/to/v2board
# 卸载:
#   bash install.sh uninstall /path/to/v2board
#   bash install.sh --uninstall /path/to/v2board
set -euo pipefail

MODE="install"
ROOT=""
ARGS=()
for a in "$@"; do
  case "$a" in
    uninstall|--uninstall|-u) MODE="uninstall" ;;
    *) ARGS+=("$a") ;;
  esac
done
ROOT="${ARGS[0]:-.}"
SRC="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -d "$ROOT" ]]; then
  echo "[fail] board root not found: $ROOT" >&2
  exit 1
fi
ROOT="$(cd "$ROOT" && pwd -P)"
DEST="$ROOT/cover-plugin"
SNAPSHOT_INDEX_TARGET=""

# ---------- 卸载 (快照优先；失败时保留插件，避免半卸载) ----------
restore_snapshot() {
  local snapshot="$1" target="$2"
  local orig_perm orig_owner target_dir tmp
  [[ -f "$snapshot" && ! -L "$snapshot" ]] || {
    echo "[fail] 可信原始快照不存在或是 symlink: $snapshot" >&2
    return 1
  }
  [[ ! -L "$target" && ! -d "$target" ]] || {
    echo "[fail] 拒绝恢复到 symlink/目录目标: $target" >&2
    return 1
  }

  if [[ -e "$target" ]]; then
    orig_perm=$(stat -c '%a' "$target" 2>/dev/null || stat -f '%Lp' "$target" 2>/dev/null || echo "0644")
    orig_owner=$(stat -c '%u:%g' "$target" 2>/dev/null || stat -f '%u:%g' "$target" 2>/dev/null || echo "")
  else
    orig_perm=$(stat -c '%a' "$snapshot" 2>/dev/null || stat -f '%Lp' "$snapshot" 2>/dev/null || echo "0644")
    orig_owner=$(stat -c '%u:%g' "$snapshot" 2>/dev/null || stat -f '%u:%g' "$snapshot" 2>/dev/null || echo "")
  fi
  target_dir="$(dirname "$target")"
  [[ -d "$target_dir" && ! -L "$target_dir" ]] || {
    echo "[fail] 拒绝恢复到 symlink/不存在的目标目录: $target_dir" >&2
    return 1
  }
  if ! tmp="$(mktemp "$target_dir/.mc.restore.XXXXXX")"; then
    echo "[fail] 无法在目标目录创建安全恢复临时文件: $target_dir" >&2
    return 1
  fi
  if ! cp -a "$snapshot" "$tmp" || ! chmod "$orig_perm" "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    echo "[fail] 无法准备原始快照恢复: $target" >&2
    return 1
  fi
  if [[ -n "$orig_owner" && "$(id -u)" -eq 0 ]]; then
    chown "$orig_owner" "$tmp" 2>/dev/null || {
      rm -f "$tmp" 2>/dev/null || true
      echo "[fail] 无法恢复文件 owner: $target" >&2
      return 1
    }
  fi
  if ! mv -f "$tmp" "$target"; then
    rm -f "$tmp" 2>/dev/null || true
    echo "[fail] 无法原子替换恢复目标: $target" >&2
    return 1
  fi
  return 0
}

unhook_index() {
  local idx="$1"
  [[ -e "$idx" || -L "$idx" || -f "$DEST/storage/index_original.bak" ]] || return 0
  [[ ! -L "$idx" ]] || {
    echo "[fail] 拒绝卸载 symlink 入口: $idx" >&2
    return 1
  }

  local snapshot="$DEST/storage/index_original.bak"
  if [[ ! -e "$idx" ]] && [[ -f "$snapshot" && ! -L "$snapshot" ]]; then
    restore_snapshot "$snapshot" "$idx" && echo "Restored missing original snapshot: $idx"
    return $?
  fi
  if ! grep -q 'cover-plugin/bootstrap\|cover-plugin/src/bootstrap\|Cover plugin (non-invasive' "$idx" 2>/dev/null; then
    echo "No Cover hook in $idx"
    return 0
  fi
  if [[ -f "$snapshot" && ! -L "$snapshot" && ( -z "$SNAPSHOT_INDEX_TARGET" || "$idx" = "$SNAPSHOT_INDEX_TARGET" ) ]]; then
    restore_snapshot "$snapshot" "$idx" && echo "Restored exact original byte-level snapshot: $idx"
    return $?
  fi
  echo "[fail] 没有可信的 index.php 原始字节快照，拒绝有损文本卸载: $idx" >&2
  return 1
}

strip_cover_env() {
  local envf="$1" snapshot="$DEST/storage/env_original.bak"
  if [[ -L "$envf" ]]; then
    echo "[fail] 拒绝卸载 symlink .env: $envf" >&2
    return 1
  fi
  if [[ -f "$snapshot" && ! -L "$snapshot" ]]; then
    restore_snapshot "$snapshot" "$envf" && echo "Restored exact original .env snapshot: $envf"
    return $?
  fi
  [[ -f "$envf" ]] || return 0
  if grep -q '^COVER_\|^# Cover Scheme A\|^# MediaCover Integration' "$envf" 2>/dev/null; then
    echo "[fail] 没有可信的 .env 原始字节快照，拒绝有损文本卸载: $envf" >&2
    return 1
  fi
  echo "No Cover settings in $envf"
  return 0
}

do_uninstall() {
  echo "==== MediaCover 插件卸载 → $ROOT ===="
  local idx failed=0 any_index=0 snapshot_file snapshot_path
  if [[ -L "$DEST" || ( -e "$DEST" && ! -d "$DEST" ) ]]; then
    echo "[fail] 拒绝卸载 symlink/非目录插件路径: $DEST" >&2
    return 1
  fi
  for snapshot_file in index_original.bak env_original.bak index_original.path; do
    snapshot_path="$DEST/storage/$snapshot_file"
    if [[ ( -e "$snapshot_path" || -L "$snapshot_path" ) && ( ! -f "$snapshot_path" || -L "$snapshot_path" ) ]]; then
      echo "[fail] 拒绝使用非 regular-file 快照: $snapshot_path" >&2
      failed=1
    fi
  done
  if [[ -f "$DEST/storage/index_original.path" && ! -L "$DEST/storage/index_original.path" ]]; then
    local snapshot_rel
    IFS= read -r snapshot_rel < "$DEST/storage/index_original.path" || true
    case "$snapshot_rel" in
      public/index.php|web/index.php|httpdocs/index.php) SNAPSHOT_INDEX_TARGET="$ROOT/$snapshot_rel" ;;
      *) echo "[fail] 原始入口快照路径非法: $snapshot_rel" >&2; failed=1 ;;
    esac
  fi
  for idx in "$ROOT/public/index.php" "$ROOT/web/index.php" "$ROOT/httpdocs/index.php"; do
    if [[ -e "$idx" || -L "$idx" ]]; then any_index=1; fi
    if [[ -L "$idx" ]]; then
      echo "[fail] 拒绝卸载 symlink 入口: $idx" >&2
      failed=1
    fi
  done
  if [[ -f "$DEST/storage/index_original.bak" && "$any_index" -eq 0 ]]; then
    echo "[fail] 原始入口文件缺失，保留插件和快照供人工恢复。" >&2
    failed=1
  fi
  if [[ -n "$SNAPSHOT_INDEX_TARGET" && ! -e "$SNAPSHOT_INDEX_TARGET" ]]; then
    echo "[fail] 原始入口文件已删除: $SNAPSHOT_INDEX_TARGET" >&2
    failed=1
  fi
  if [[ -L "$ROOT/.env" ]]; then
    echo "[fail] 拒绝卸载 symlink .env: $ROOT/.env" >&2
    failed=1
  fi
  [[ "$failed" -eq 0 ]] || return 1

  for idx in "$ROOT/public/index.php" "$ROOT/web/index.php" "$ROOT/httpdocs/index.php"; do
    if [[ -e "$idx" || -L "$idx" ]]; then
      if ! unhook_index "$idx"; then failed=1; fi
    fi
  done
  if ! strip_cover_env "$ROOT/.env"; then failed=1; fi
  if [[ "$failed" -ne 0 ]]; then
    echo "[fail] 卸载未完成，插件目录和快照已保留供重试/人工恢复。" >&2
    return 1
  fi
  if [[ -d "$DEST" ]]; then
    rm -rf "$DEST"
    echo "Removed $DEST"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload php-fpm 2>/dev/null || systemctl reload php8.2-fpm 2>/dev/null || \
    systemctl reload php8.1-fpm 2>/dev/null || systemctl reload php8.3-fpm 2>/dev/null || true
  fi
  echo "Uninstalled MediaCover plugin from $ROOT (Clean)"
}

if [[ "$MODE" == "uninstall" ]]; then
  do_uninstall
  exit 0
fi

# ---------- 安装前置强校验 (修复 V5-02 & V6-07) ----------
command -v php >/dev/null 2>&1 || { echo "[fail] 事务阻断: 系统未检测到可执行的 php 命令 (PHP CLI)，安装中止以保护站点入口安全。" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "[fail] 事务阻断: 系统未检测到 python3，安装中止以保证入口解析与修改绝对安全。" >&2; exit 1; }

# 1. 查找入口文件
TARGET_INDEX=""
for cand in "$ROOT/public/index.php" "$ROOT/web/index.php" "$ROOT/httpdocs/index.php"; do
  if [[ -f "$cand" ]]; then
    TARGET_INDEX="$cand"
    break
  fi
done

if [[ -z "$TARGET_INDEX" ]]; then
  echo "[fail] 事务阻断: 在 $ROOT 未找到任何 index.php 入口 (public/index.php)，安装中止，未做任何修改。" >&2
  exit 1
fi
if [[ -L "$TARGET_INDEX" ]]; then
  echo "[fail] 事务阻断: 入口文件是 symlink，拒绝沿链接修改站点外文件: $TARGET_INDEX" >&2
  exit 1
fi

ENVF="$ROOT/.env"
if [[ -L "$ENVF" ]]; then
  echo "[fail] 事务阻断: .env 是 symlink，拒绝沿链接修改站点外文件: $ENVF" >&2
  exit 1
fi

# cover-plugin 必须是本安装根目录下的真实目录。否则 mkdir/cp/mv 可能
# 跟随链接把插件文件、快照或恢复临时文件写到站点目录之外；普通文件也
# 不能被失败回滚逻辑当作“新建目录”误删。
if [[ -L "$DEST" || ( -e "$DEST" && ! -d "$DEST" ) ]]; then
  echo "[fail] 事务阻断: cover-plugin 必须是普通目录，拒绝 symlink/非目录路径: $DEST" >&2
  exit 1
fi

# 2. 检查安装源中的核心 bootstrap 文件
SRC_REAL="$(cd "$SRC" && pwd -P)"
BOOTSTRAP_SOURCE=""
if [[ -f "$SRC/src/bootstrap.php" ]]; then
  BOOTSTRAP_SOURCE="$SRC/src/bootstrap.php"
elif [[ -f "$SRC/../src/bootstrap.php" ]]; then
  BOOTSTRAP_SOURCE="$SRC/../src/bootstrap.php"
elif [[ -f "$SRC/bootstrap.php" ]]; then
  BOOTSTRAP_SOURCE="$SRC/bootstrap.php"
fi

if [[ -z "$BOOTSTRAP_SOURCE" ]]; then
  echo "[fail] 事务阻断: 安装包残缺，未找到 bootstrap.php，安装中止，未做任何修改。" >&2
  exit 1
fi

# 3. 准备挂载代码并预先在临时文件上进行严格语法验证
hook_code=$(cat <<'PHP'

// ---- Cover plugin (non-invasive, auto) ----
if (is_file(__DIR__ . '/../cover-plugin/src/bootstrap.php')) {
    require_once __DIR__ . '/../cover-plugin/src/bootstrap.php';
} elseif (is_file(__DIR__ . '/../cover-plugin/bootstrap.php')) {
    require_once __DIR__ . '/../cover-plugin/bootstrap.php';
}
// ---- end Cover ----
PHP
)

dir="$(dirname "$TARGET_INDEX")"
if [[ ! -d "$dir" || -L "$dir" ]]; then
  echo "[fail] 事务阻断: index.php 父目录不是可信普通目录: $dir" >&2
  exit 1
fi
tmp_idx="$(mktemp "${dir}/tmp.hook.XXXXXX")"
orig_perm=$(stat -c '%a' "$TARGET_INDEX" 2>/dev/null || stat -f '%Lp' "$TARGET_INDEX" 2>/dev/null || echo "0644")
orig_owner=$(stat -c '%u:%g' "$TARGET_INDEX" 2>/dev/null || stat -f '%u:%g' "$TARGET_INDEX" 2>/dev/null || echo "")

# 注册完整事务回滚快照 (彻底解决 V7-02 & V8-04: 全新安装失败彻底删除新插件，升级失败还原旧快照)
DEST_BACKUP=""
ENV_BACKUP=""
DEST_EXISTS_BEFORE=0
if [[ -d "$DEST" ]]; then
  DEST_EXISTS_BEFORE=1
  if [[ "$SRC_REAL" != "$DEST" ]]; then
    DEST_BACKUP="$(mktemp -d "${ROOT}/tmp.destbak.XXXXXX")"
    cp -a "$DEST/." "$DEST_BACKUP/"
  fi
fi

cleanup_on_fail() {
  rm -f "$tmp_idx" 2>/dev/null || true
  if [[ "$DEST_EXISTS_BEFORE" -eq 1 && -n "$DEST_BACKUP" && -d "$DEST_BACKUP" ]]; then
    rm -rf "$DEST" 2>/dev/null || true
    mkdir -p "$DEST"
    cp -a "$DEST_BACKUP/." "$DEST/" 2>/dev/null || true
    rm -rf "$DEST_BACKUP" 2>/dev/null || true
  elif [[ "$DEST_EXISTS_BEFORE" -eq 0 ]]; then
    # 修复 V8-04: 全新安装失败时彻底删除新复制的插件目录
    rm -rf "$DEST" 2>/dev/null || true
  fi
  if [[ -n "$ENV_BACKUP" && -f "$ENV_BACKUP" ]]; then
    cp -a "$ENV_BACKUP" "$ROOT/.env" 2>/dev/null || true
    rm -f "$ENV_BACKUP" 2>/dev/null || true
  fi
}
trap cleanup_on_fail EXIT

# 幂等处理：如果已有 hook 则先剥离，确保不重复叠加
clean_target="$TARGET_INDEX"
if grep -q 'cover-plugin/bootstrap\|cover-plugin/src/bootstrap' "$TARGET_INDEX" 2>/dev/null; then
python3 - "$TARGET_INDEX" "$tmp_idx" <<'PY' || true
import re, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, "rb") as f:
    s = f.read()
pat = re.compile(rb"(?:\r?\n)+// ---- Cover plugin \(non-invasive, auto\) ----.*?// ---- end Cover ----(?P<after>(?:\r?\n)*)", re.S)
def remove_hook(match):
    after = match.group('after')
    if not after:
        return b''
    # after 中最后一个换行属于原入口，其余通常是安装器插入的换行。
    return b'\r\n' if after.endswith(b'\r\n') else b'\n'
s2, _ = pat.subn(remove_hook, s)
with open(dst, "wb") as f:
    f.write(s2)
PY
  if [[ -s "$tmp_idx" ]]; then
    clean_target="$tmp_idx"
  fi
fi

# 修复 V7-04: 剔除 UTF-8 BOM（绝不在 opening tag 前输出 BOM，彻底解决 headers_sent 问题）
python3 - "$clean_target" "$tmp_idx" "$hook_code" <<'PY'
import sys, re
src_path, dst_path, hook = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src_path, "rb") as f:
    raw = f.read()

# 剥离 UTF-8 BOM，严禁在 PHP opening tag 之前留下任何字符输出。其余
# 内容始终按 bytes 处理，避免非 UTF-8 的旧入口在重复安装时被替换字符损坏。
if raw.startswith(b"\xef\xbb\xbf"):
    raw = raw[3:]

content = raw
hook_bytes = hook if isinstance(hook, bytes) else hook.encode("utf-8")

# 匹配 <?php (可选换行/注释) declare(strict_types=1);
pattern = re.compile(rb'^(<\?php(?:\s*(?:/\*.*?\*/|//[^\n]*\n)*\s*declare\s*\([^)]+\)\s*;)?)', re.IGNORECASE | re.DOTALL)
m = pattern.search(content)
if m and m.group(1):
    header = m.group(1)
    rest = content[len(header):]
    new_content = header + b"\n" + hook_bytes + b"\n" + rest
else:
    pattern_simple = re.compile(rb'^(<\?php\b)', re.IGNORECASE)
    m2 = pattern_simple.search(content)
    if m2:
        header = m2.group(1)
        rest = content[len(header):]
        new_content = header + b"\n" + hook_bytes + b"\n" + rest
    else:
        new_content = b"<?php\n" + hook_bytes + b"\n\n" + content

with open(dst_path, "wb") as f:
    f.write(new_content)
PY

# 强制执行 php -l 校验
if ! php -l "$tmp_idx" >/dev/null 2>&1; then
  echo "[fail] 事务阻断: 生成的挂载入口未能通过 php -l 语法检查，安装中止，未对站点进行任何修改。" >&2
  exit 1
fi

# 4. 事务化备份 .env (用于失败回滚)
if [[ -f "$ENVF" ]]; then
  ENV_BACKUP="$(mktemp "${ROOT}/tmp.envbak.XXXXXX")"
  cp -a "$ENVF" "$ENV_BACKUP"
fi

# 5. 执行文件拷贝
DEST_REAL=""
[[ -d "$DEST" ]] && DEST_REAL="$(cd "$DEST" 2>/dev/null && pwd -P || echo "")"

if [[ "$SRC_REAL" != "$DEST_REAL" ]]; then
  mkdir -p "$DEST/src"
  if [[ -d "$SRC/src" ]]; then
    rm -rf "$DEST/src"
    cp -a "$SRC/src" "$DEST/"
  elif [[ -d "$SRC/../src" ]]; then
    rm -rf "$DEST/src"
    cp -a "$SRC/../src" "$DEST/"
  else
    cp -a "$SRC/"* "$DEST/src/" 2>/dev/null || true
  fi
  cp -a "$SRC/install.sh" "$DEST/install.sh" 2>/dev/null || true
  cp -a "$SRC/README.md" "$DEST/README.md" 2>/dev/null || true
  cp -a "$SRC/LICENSE" "$DEST/LICENSE" 2>/dev/null || true
fi

# 修复 V7-03 / V8-03: storage 目录由当前部署所有者创建，权限 0700 (严格私有)
if [[ -L "$DEST/storage" ]]; then
  echo "[fail] 事务阻断: cover-plugin/storage 是 symlink，拒绝写入站点外路径。" >&2
  exit 1
fi
if ! mkdir -p "$DEST/storage" 2>/dev/null || ! chmod 0700 "$DEST/storage" 2>/dev/null; then
  echo "[fail] 事务阻断: 无法创建或锁定私有 storage 目录。" >&2
  exit 1
fi

# 保存安装前原始 index.php 与 .env 完整字节级快照 (修复 V9-02: 保证无损卸载还原)
for snapshot_file in index_original.bak env_original.bak index_original.path; do
  snapshot_path="$DEST/storage/$snapshot_file"
  if [[ ( -e "$snapshot_path" || -L "$snapshot_path" ) && ( ! -f "$snapshot_path" || -L "$snapshot_path" ) ]]; then
    echo "[fail] 事务阻断: storage 快照不是 regular file: $snapshot_path" >&2
    exit 1
  fi
done
if [[ ! -f "$DEST/storage/index_original.bak" ]]; then
  if ! cp -a "$TARGET_INDEX" "$DEST/storage/index_original.bak" 2>/dev/null || ! chmod 0600 "$DEST/storage/index_original.bak" 2>/dev/null; then
    echo "[fail] 事务阻断: 无法保存 index.php 原始字节快照。" >&2
    exit 1
  fi
fi
if [[ ! -f "$DEST/storage/index_original.path" ]]; then
  if ! printf '%s\n' "${TARGET_INDEX#"$ROOT"/}" > "$DEST/storage/index_original.path" || ! chmod 0600 "$DEST/storage/index_original.path" 2>/dev/null; then
    echo "[fail] 事务阻断: 无法保存入口快照路径。" >&2
    exit 1
  fi
else
  IFS= read -r snapshot_rel < "$DEST/storage/index_original.path" || snapshot_rel=""
  if [[ "$snapshot_rel" != "${TARGET_INDEX#"$ROOT"/}" ]]; then
    echo "[fail] 事务阻断: 入口快照路径与当前入口不一致。" >&2
    exit 1
  fi
fi
if [[ -f "$ENVF" && ! -f "$DEST/storage/env_original.bak" ]]; then
  if ! cp -a "$ENVF" "$DEST/storage/env_original.bak" 2>/dev/null || ! chmod 0600 "$DEST/storage/env_original.bak" 2>/dev/null; then
    echo "[fail] 事务阻断: 无法保存 .env 原始字节快照。" >&2
    exit 1
  fi
fi

# 6. 配置 .env
set_env() {
  local k="$1" v="$2"
  [[ -z "$v" || ! -f "$ENVF" ]] && return 0
  if grep -q "^${k}=" "$ENVF" 2>/dev/null; then
    python3 - "$ENVF" "$k" "$v" <<'PY'
import sys
path, k, v = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, 'rb') as f:
    lines = f.readlines()
prefix = k.encode('utf-8') + b'='
replacement = prefix + v.encode('utf-8') + b'\n'
with open(path, 'wb') as f:
    for line in lines:
        if line.startswith(prefix):
            f.write(replacement)
        else:
            f.write(line)
PY
  else
    echo "${k}=${v}" >> "$ENVF"
  fi
}

if [[ -f "$ENVF" ]]; then
  grep -q '# MediaCover Integration' "$ENVF" 2>/dev/null || echo -e "\n# MediaCover Integration" >> "$ENVF"
  set_env COVER_PANEL_URL "${COVER_PANEL_URL:-}"
  set_env COVER_TENANT_ID "${COVER_TENANT_ID:-}"
  set_env COVER_BOARD_ID "${COVER_BOARD_ID:-}"
  set_env COVER_PLUGIN_TOKEN "${COVER_PLUGIN_TOKEN:-}"
  set_env COVER_APP_ANDROID "${COVER_APP_ANDROID:-}"
  set_env COVER_APP_IOS "${COVER_APP_IOS:-}"
  grep -q '^COVER_KILL_SUBSCRIBE=' "$ENVF" 2>/dev/null || echo "COVER_KILL_SUBSCRIBE=1" >> "$ENVF"
  echo "Updated $ENVF COVER_*"
fi

# 7. 原子生效 index.php
chmod "$orig_perm" "$tmp_idx" 2>/dev/null || chmod 0644 "$tmp_idx" 2>/dev/null || true
if [[ -n "$orig_owner" && "$(id -u)" -eq 0 ]]; then
  chown "$orig_owner" "$tmp_idx" 2>/dev/null || true
fi
mv "$tmp_idx" "$TARGET_INDEX"

# 8. 写入说明文件 (解决 V8-04: 非关键输出即使失败也不影响整体安装)
cat > "$DEST/INSTALL_NEXT.txt" 2>/dev/null <<EOF || true
MediaCover 插件已成功无侵入挂载 → $DEST

验收:
  - 引导页: https://你的域名/cover
  - 订阅封杀验证: https://你的域名/api/v1/client/subscribe 应返回 404

卸载（一条命令）:
  bash $DEST/install.sh uninstall $ROOT
EOF

# 成功生效，清理旧快照，解除回滚 trap
[[ -n "$DEST_BACKUP" ]] && rm -rf "$DEST_BACKUP" 2>/dev/null || true
[[ -n "$ENV_BACKUP" ]] && rm -f "$ENV_BACKUP" 2>/dev/null || true
trap - EXIT

echo "Hooked (preserve permissions $orig_perm): $TARGET_INDEX"

if command -v systemctl >/dev/null 2>&1; then
  systemctl reload php-fpm 2>/dev/null || systemctl reload php8.2-fpm 2>/dev/null || \
  systemctl reload php8.1-fpm 2>/dev/null || systemctl reload php8.3-fpm 2>/dev/null || true
fi

echo "[ok] Installed plugin → $DEST (non-invasive)"
[[ -f "$DEST/INSTALL_NEXT.txt" ]] && cat "$DEST/INSTALL_NEXT.txt" || true
