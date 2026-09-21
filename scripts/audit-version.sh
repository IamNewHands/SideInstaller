#!/usr/bin/env bash
# 整版本审计：审计「上一个上游 release tag → 新 release tag」的全部改动，并判定能否自动合并。
#
# 用法：bash scripts/audit-version.sh <旧ref> <新ref> [检查退役路径的 ref，默认 HEAD]
# 退出码：0 = 门禁通过（可自动合并）；2 = 需要人工审阅；1 = 用法/环境错误
#
# 门禁只覆盖"可确定判定"的东西：新增的 URL/域名/IP、危险 API、凭据、依赖面、
# workflow 权限与触发面、新增二进制、退役路径回流、变更规模。它**不**判断语义
# （比如一个正常域名的服务端是不是恶意、一段纯逻辑改动有没有偷传数据），
# 所以门禁通过 ≠ 审计通过，报告最后一节固定列出"门禁没查什么"。
set -uo pipefail

PREV="${1:-}"
NEW="${2:-}"
TREE_REF="${3:-HEAD}"

if [ -z "$PREV" ] || [ -z "$NEW" ]; then
  echo "用法: bash scripts/audit-version.sh <旧ref> <新ref> [tree-ref]" >&2
  exit 1
fi

# 已退役路径（与 scripts/audit-delta.sh 保持一致）：证书池目录、重签 workflow、
# 重签脚本、Pages 页面、证书池输入
RETIRED_RE='^(output|output-beta|build-dd|certs)/|^\.github/workflows/(sign-sideinstaller|plist-and-index)\.yml$|^(index|beta|terms)\.html(\.orig)?$|^scripts/(sign_with_all_certs|check_for_changes|generate_index|generate_plist)\.sh$|^scripts/template\.html(\.orig)?$|^(cert-url|ipa-url)\.txt$|^SideInstallerDNS\.mobileconfig$'

# 上游自己在跟踪的大目录：它们永远不进 main，也不参与版本审计（否则 diff 会去
# 拉几百 MB 的 ipa，还会把"上游又重签了一批证书"误报成危险信号）
EXC=(':(exclude)output/**' ':(exclude)output-beta/**' ':(exclude)build-dd/**' ':(exclude)certs/**')

KEYWORDS='https?://|posix_spawn|dlopen|dlsym|NSTask|Process\(|system\(|popen|URLSession|URLRequest|CFNetwork|SecItem|Keychain|altIRK|atob\(|eval\(|-----BEGIN|password|passwd|secret|token|AKIA|ghp_|eyJ'
MAX_FILES=300

FAILS=0
fail() { FAILS=$((FAILS + 1)); printf -- '- ❌ %s\n' "$1"; }
pass() { printf -- '- ✅ %s\n' "$1"; }

git rev-parse --verify --quiet "${PREV}^{commit}" >/dev/null || { echo "未知 ref: $PREV" >&2; exit 1; }
git rev-parse --verify --quiet "${NEW}^{commit}" >/dev/null || { echo "未知 ref: $NEW" >&2; exit 1; }

COMMITS=$(git rev-list --count "$PREV..$NEW" 2>/dev/null || echo 0)
CHANGED=$(git diff --name-only "$PREV..$NEW" -- . "${EXC[@]}" 2>/dev/null | wc -l | tr -d ' ')

echo "# 上游版本审计：\`$PREV\` → \`$NEW\`"
echo
echo "- 提交数：$COMMITS"
echo "- 变更文件数：$CHANGED（已排除退役路径 \`output/\`、\`output-beta/\`、\`build-dd/\`、\`certs/\`）"
echo "- 新版本 commit：\`$(git rev-parse --short "${NEW}^{commit}")\`"
echo

echo "## 这一版改了什么（提交标题）"
echo
echo '```'
git log --no-merges --pretty='%h %s' "$PREV..$NEW" 2>/dev/null | head -40 || true
echo '```'
echo

echo "## 变更分布（按顶层目录）"
echo
echo '```'
git diff --name-only "$PREV..$NEW" -- . "${EXC[@]}" 2>/dev/null | sed 's|/.*||' | sort | uniq -c | sort -rn | head -25 || true
echo '```'
echo

echo "## 门禁判定"
echo

# 0) 范围不能为空
if [ "$COMMITS" -eq 0 ]; then
  fail "审计范围为空（$PREV..$NEW 没有提交），拒绝自动合并"
fi

# 1) 关键词（只看新增行）
HITS=$(git diff -U0 "$PREV..$NEW" -- . "${EXC[@]}" 2>/dev/null \
  | awk '/^\+\+\+ b\//{f=substr($0,7)} /^\+[^+]/{print f": "substr($0,2)}' \
  | grep -Ei "$KEYWORDS" || true)
if [ -n "$HITS" ]; then
  fail "新增行命中高危关键词（$(printf '%s\n' "$HITS" | wc -l | tr -d ' ') 行，见下节）"
else
  pass "新增行没有命中高危关键词"
fi

# 2) vendor 目录
VENDOR=$(git diff --name-only "$PREV..$NEW" -- 'rust-core/vendor' 2>/dev/null || true)
if [ -n "$VENDOR" ]; then
  fail "rust-core/vendor/** 有改动（必须逐行看）：$(printf '%s\n' "$VENDOR" | tr '\n' ' ')"
else
  pass "rust-core/vendor/** 无改动"
fi

# 3) 依赖面
DEP_FILES=$(git diff --name-only "$PREV..$NEW" -- '*/Cargo.toml' '*/Cargo.lock' '*Package.resolved' 'project.yml' 2>/dev/null || true)
DEP_NEW=$(git diff "$PREV..$NEW" -- '*/Cargo.toml' '*/Cargo.lock' '*Package.resolved' 'project.yml' 2>/dev/null \
  | grep -E '^\+' | grep -E 'name = |git = |branch = |rev = |url = |packages:|^\+\[patch' || true)
if [ -n "$DEP_NEW" ]; then
  fail "依赖面出现新增项（新包 / git 源 / url / patch 段）"
elif [ -n "$DEP_FILES" ]; then
  pass "依赖文件有改动但只是版本号（$(printf '%s\n' "$DEP_FILES" | tr '\n' ' ')）"
else
  pass "依赖面无改动"
fi

# 4) workflow 面
WF_DIFF=$(git diff "$PREV..$NEW" -- '.github/workflows' 2>/dev/null | grep -E '^\+' \
  | grep -E 'permissions:|secrets\.|pull_request_target|schedule:|curl|repository_dispatch|workflow_run' || true)
WF_NEW=$(git diff --name-status --diff-filter=A "$PREV..$NEW" -- '.github/workflows' 2>/dev/null || true)
if [ -n "$WF_DIFF" ]; then
  fail "workflow 新增了权限/secret/触发面（见下节）"
elif [ -n "$WF_NEW" ]; then
  fail "新增了 workflow 文件：$(printf '%s\n' "$WF_NEW" | tr '\n' ' ')"
else
  pass "workflow 权限、secret、触发面无新增"
fi

# 5) 新增文件 / 二进制 / 可执行位
ADDED=$(git diff --name-status --diff-filter=A "$PREV..$NEW" -- . "${EXC[@]}" 2>/dev/null || true)
BIN=$(git diff --numstat "$PREV..$NEW" -- . "${EXC[@]}" 2>/dev/null | awk '$1=="-" && $2=="-" {print $3}' || true)
EXEC=$(git diff --summary "$PREV..$NEW" -- . "${EXC[@]}" 2>/dev/null | grep 'mode 100755' | head -10 || true)
if [ -n "$BIN" ]; then
  fail "新增/改动了二进制文件：$(printf '%s\n' "$BIN" | tr '\n' ' ')"
else
  pass "无二进制文件改动"
fi
if [ -n "$EXEC" ]; then
  fail "出现可执行位：$(printf '%s\n' "$EXEC" | tr '\n' ' ')"
fi

# 6) 退役路径回流（在目标 tree 上检查，不是在上游 ref 上）
BACK=$(git ls-tree -r --name-only "$TREE_REF" 2>/dev/null | grep -E "$RETIRED_RE" | head -20 || true)
if [ -n "$BACK" ]; then
  fail "已退役路径回流到 $TREE_REF：$(printf '%s\n' "$BACK" | tr '\n' ' ')"
else
  pass "已退役路径未回流（$TREE_REF 干净）"
fi

# 7) 规模
if [ "$CHANGED" -gt "$MAX_FILES" ]; then
  fail "变更文件数 $CHANGED 超过阈值 $MAX_FILES，规模异常"
else
  pass "变更规模正常（$CHANGED ≤ $MAX_FILES）"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  echo "**结论：门禁通过 → 可以自动合并、自动构建。**"
else
  echo "**结论：$FAILS 项需要人工确认 → 不自动合并。**"
fi
echo

echo "## 高危关键词命中（仅新增行，最多 40 行）"
echo
echo '```'
if [ -n "$HITS" ]; then printf '%s\n' "$HITS" | head -40; else echo "（无）"; fi
echo '```'
echo

echo "## 依赖面 diff（最多 60 行）"
echo
echo '```'
git diff "$PREV..$NEW" -- '*/Cargo.toml' '*/Cargo.lock' '*Package.resolved' 'project.yml' 2>/dev/null | head -60 || true
echo '```'
echo

echo "## workflow diff（最多 60 行）"
echo
echo '```'
git diff "$PREV..$NEW" -- '.github/workflows' 2>/dev/null | head -60 || true
echo '```'
echo

echo "## 新增文件（最多 40 行）"
echo
echo '```'
if [ -n "$ADDED" ]; then printf '%s\n' "$ADDED" | head -40; else echo "（无）"; fi
echo '```'
echo

echo "## 变更最大的 20 个文件"
echo
echo '```'
git diff --stat "$PREV..$NEW" -- . "${EXC[@]}" 2>/dev/null | tail -21 || true
echo '```'
echo

echo "## 门禁没有查什么（必须人看的部分）"
echo
echo '- 新增/变更的域名是不是恶意、服务端是谁 —— 只看得到"多了个 URL"，看不到"这个 URL 是谁的"'
echo '- 纯逻辑改动（不引入新 API、新域名、新依赖）里有没有藏后门、有没有把 Apple ID 写到别处'
echo '- 已有代码的行为被改写（比如签名结果被复制到另一个位置）'
echo '- 所以：门禁通过只代表"没有出现可确定判定的危险信号"，不代表这一版代码已被人读懂'

if [ "$FAILS" -eq 0 ]; then exit 0; else exit 2; fi
