#!/usr/bin/env bash
# 审计增量报告：只报告 AUDIT-BASELINE.md 水位线之后的变更。只读，不改任何东西。
# 用法：bash scripts/audit-delta.sh [基线commit] [目标ref]
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

BASE="${1:-$(sed -n 's/^audited_commit:[[:space:]]*//p' AUDIT-BASELINE.md | head -1)}"
if [ -z "$BASE" ]; then
  echo "找不到水位线：AUDIT-BASELINE.md 里的 audited_commit" >&2
  exit 1
fi
TARGET="${2:-HEAD}"

echo "水位线 $BASE  ->  $TARGET"
echo

echo "== 1. 新 commit =="
git log --oneline "$BASE..$TARGET" || true
echo

echo "== 2. 变更文件统计 =="
git diff --stat "$BASE..$TARGET" || true
echo

echo "== 3. 高危关键词（仅新增行）=="
git diff -U0 "$BASE..$TARGET" \
  | awk '/^\+\+\+ b\//{f=substr($0,7)} /^\+[^+]/{print f": "substr($0,2)}' \
  | grep -Ei 'https?://|posix_spawn|dlopen|dlsym|NSTask|Process\(|system\(|popen|URLSession|URLRequest|CFNetwork|SecItem|Keychain|altIRK|atob\(|eval\(|-----BEGIN|password|passwd|secret|token|AKIA|ghp_|eyJ' \
  || echo "（无）"
echo

echo "== 4. 依赖面 =="
git diff "$BASE..$TARGET" -- '*Cargo.toml' '*Cargo.lock' '*Package.resolved' 'project.yml' 'rust-core/vendor' | head -300 || true
echo

echo "== 5. workflow 权限 / secret / 触发面 =="
git diff "$BASE..$TARGET" -- .github/workflows \
  | grep -E '^[+-].*(permissions|secrets\.|pull_request_target|schedule|curl|upload-artifact|runs-on|uses:)' || echo "（无）"
echo

echo "== 6. 新增文件（最容易藏东西）=="
git diff --name-status --diff-filter=A "$BASE..$TARGET" || true
echo

echo "== 7. 退役路径是否被带回来 =="
git ls-tree -r --name-only "$TARGET" \
  | grep -E '^(output|output-beta|build-dd|certs)/|^\.github/workflows/(sign-sideinstaller|plist-and-index)\.yml$' \
  | head -20 || echo "（干净）"
