#!/usr/bin/env bash
# cherry-all: 将指定 commit cherry-pick 到选定的本地分支（macOS / Linux）
# 兼容 bash 3.2+（macOS 自带）与 bash 4+/5+（多数 Linux）
#
# 用法:
#   cherry-all <commit-hash>
#   cherry-all <commit-hash> --branches master,feature/a
#   cherry-all <commit-hash> --exclude main,master
#   cherry-all <commit-hash> --include-only 'feature/*,fix/*'
#   cherry-all <commit-hash> --all
#   cherry-all <commit-hash> --stash
#   cherry-all <commit-hash> --force
#   cherry-all <commit-hash> --dry-run
#   cherry-all <commit-hash> --continue-on-conflict
#
# 安装到 PATH 示例:
#   chmod +x cherry-all.sh
#   ln -sf /path/to/cherry-all.sh /usr/local/bin/cherry-all
#   # 或: mkdir -p ~/bin && ln -sf /path/to/cherry-all.sh ~/bin/cherry-all && export PATH="$HOME/bin:$PATH"

set -e
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

COMMIT=""
BRANCHES_CSV=""
EXCLUDE_CSV=""
INCLUDE_ONLY_CSV=""
FLAG_ALL=0
FLAG_STASH=0
FLAG_FORCE=0
FLAG_DRY_RUN=0
FLAG_CONTINUE=0

info()  { printf '\033[36m[INFO]  %s\033[0m\n' "$*"; }
ok()    { printf '\033[32m[OK]    %s\033[0m\n' "$*"; }
warn()  { printf '\033[33m[WARN]  %s\033[0m\n' "$*"; }
err()   { printf '\033[31m[ERROR] %s\033[0m\n' "$*" >&2; }

usage() {
  cat <<'EOF'
用法: cherry-all [commit-hash] [选项]

选项:
  -b, --branches <list>       直接指定分支（逗号分隔，支持通配符）
  -e, --exclude <list>        排除分支（逗号分隔，支持通配符）
  -i, --include-only <list>   仅保留匹配分支（逗号分隔，支持通配符）
  -a, --all                   不交互，处理过滤后的全部本地分支
  -s, --stash                 自动 stash，结束后 stash pop
  -f, --force                 跳过工作区干净检查
  -n, --dry-run               只预览，不执行 cherry-pick
  -c, --continue-on-conflict  冲突时跳过该分支继续
  -h, --help                  显示帮助
EOF
}

# 按逗号/空白拆分，结果写入全局数组名（通过 eval，兼容 bash 3.2）
split_csv_into() {
  local __name="$1"
  local raw="${2:-}"
  eval "$__name=()"
  [ -z "$raw" ] && return 0
  local OLDIFS="$IFS"
  local item
  IFS=$',， \t\n'
  # shellcheck disable=SC2086
  for item in $raw; do
    [ -n "$item" ] || continue
    eval "$__name+=(\"\$item\")"
  done
  IFS="$OLDIFS"
}

# 通配匹配：pattern 支持 * ?
match_glob() {
  case "$1" in
    $2) return 0 ;;
    *) return 1 ;;
  esac
}

array_contains() {
  local needle="$1"
  shift
  local x
  for x in "$@"; do
    [ "$x" = "$needle" ] && return 0
  done
  return 1
}

# 解析分支选择：1,3,5-8 / a|all|* / 名称通配
# 结果写入 SELECTED
parse_selection() {
  local input="$1"
  SELECTED=()
  # trim
  input="$(printf '%s' "$input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$input" ] && return 0

  case "$input" in
    a|all|\*)
      SELECTED=("${CANDIDATES[@]}")
      return 0
      ;;
  esac

  local OLDIFS="$IFS"
  IFS=$',， \t'
  # shellcheck disable=SC2086
  set -- $input
  IFS="$OLDIFS"

  local part start end i tmp name c matched_count
  for part in "$@"; do
    [ -z "$part" ] && continue
    if printf '%s' "$part" | grep -Eq '^[0-9]+-[0-9]+$'; then
      start="${part%-*}"
      end="${part#*-}"
      if [ "$start" -gt "$end" ]; then
        tmp=$start; start=$end; end=$tmp
      fi
      i=$start
      while [ "$i" -le "$end" ]; do
        if [ "$i" -lt 1 ] || [ "$i" -gt "${#CANDIDATES[@]}" ]; then
          err "编号越界: $i（有效范围 1-${#CANDIDATES[@]}）"
          return 1
        fi
        name="${CANDIDATES[$((i-1))]}"
        if [ ${#SELECTED[@]} -eq 0 ] || ! array_contains "$name" "${SELECTED[@]}"; then
          SELECTED+=("$name")
        fi
        i=$((i + 1))
      done
    elif printf '%s' "$part" | grep -Eq '^[0-9]+$'; then
      i="$part"
      if [ "$i" -lt 1 ] || [ "$i" -gt "${#CANDIDATES[@]}" ]; then
        err "编号越界: $i（有效范围 1-${#CANDIDATES[@]}）"
        return 1
      fi
      name="${CANDIDATES[$((i-1))]}"
      if [ ${#SELECTED[@]} -eq 0 ] || ! array_contains "$name" "${SELECTED[@]}"; then
        SELECTED+=("$name")
      fi
    else
      matched_count=0
      for c in "${CANDIDATES[@]}"; do
        if match_glob "$c" "$part"; then
          matched_count=$((matched_count + 1))
          if [ ${#SELECTED[@]} -eq 0 ] || ! array_contains "$c" "${SELECTED[@]}"; then
            SELECTED+=("$c")
          fi
        fi
      done
      if [ "$matched_count" -eq 0 ]; then
        err "未匹配到分支: $part"
        return 1
      fi
    fi
  done
}

# ---- 参数解析（避免依赖 GNU getopt，兼容 macOS）----
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage; exit 0
      ;;
    -b|--branches)
      BRANCHES_CSV="${2:-}"; shift 2
      ;;
    -e|--exclude)
      EXCLUDE_CSV="${2:-}"; shift 2
      ;;
    -i|--include-only)
      INCLUDE_ONLY_CSV="${2:-}"; shift 2
      ;;
    -a|--all)
      FLAG_ALL=1; shift
      ;;
    -s|--stash)
      FLAG_STASH=1; shift
      ;;
    -f|--force)
      FLAG_FORCE=1; shift
      ;;
    -n|--dry-run)
      FLAG_DRY_RUN=1; shift
      ;;
    -c|--continue-on-conflict)
      FLAG_CONTINUE=1; shift
      ;;
    --)
      shift; break
      ;;
    -*)
      err "未知参数: $1"; usage; exit 1
      ;;
    *)
      if [ -z "$COMMIT" ]; then
        COMMIT="$1"; shift
      else
        err "多余参数: $1"; usage; exit 1
      fi
      ;;
  esac
done

if [ -z "$COMMIT" ]; then
  printf '请输入要 cherry-pick 的 commit hash: '
  read -r COMMIT
fi
COMMIT="$(printf '%s' "$COMMIT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
if [ -z "$COMMIT" ]; then
  err "未提供 commit hash，已退出。"
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  err "未找到 git 命令。"
  exit 1
fi

if ! repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  err "当前目录不是 git 仓库，请先 cd 到目标仓库再执行。"
  exit 1
fi

if ! full_hash="$(git rev-parse --verify "$COMMIT" 2>/dev/null)"; then
  err "找不到 commit: $COMMIT"
  exit 1
fi

short_hash="$(git rev-parse --short "$full_hash")"
commit_msg="$(git -c core.quotepath=false log -1 --pretty=format:'%s' "$full_hash")"
info "仓库: $repo_root"
info "Commit: $short_hash ($full_hash)"
info "说明: $commit_msg"

did_stash=0
STATUS_LINES=()
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] && STATUS_LINES+=("$line")
done < <(git status --porcelain --untracked-files=no || true)

if [ ${#STATUS_LINES[@]} -gt 0 ]; then
  if [ "$FLAG_FORCE" -eq 1 ]; then
    warn "工作区有 ${#STATUS_LINES[@]} 处未提交改动，已用 --force 跳过检查。"
  elif [ "$FLAG_STASH" -eq 1 ]; then
    info "工作区有 ${#STATUS_LINES[@]} 处未提交改动，自动 stash..."
    if ! git stash push -u -m "cherry-all auto-stash"; then
      err "自动 stash 失败。"
      exit 1
    fi
    did_stash=1
    ok "已 stash，结束后会尝试恢复。"
  else
    err "工作区有未提交改动（${#STATUS_LINES[@]} 个），请先 commit / stash，或加 --stash / --force。"
    shown=0
    for line in "${STATUS_LINES[@]}"; do
      shown=$((shown + 1))
      if [ "$shown" -gt 20 ]; then
        printf '  ... 还有 %s 个\n' "$(( ${#STATUS_LINES[@]} - 20 ))"
        break
      fi
      printf '  %s\n' "$line"
    done
    exit 1
  fi
fi

original_branch="$(git -c core.quotepath=false rev-parse --abbrev-ref HEAD)"
if [ "$original_branch" = "HEAD" ]; then
  err "当前处于 detached HEAD，请先切到某个分支再执行。"
  exit 1
fi
info "当前分支: $original_branch"

ALL_LOCAL=()
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] && ALL_LOCAL+=("$line")
done < <(git -c core.quotepath=false for-each-ref --format='%(refname:short)' refs/heads/)

CANDIDATES=("${ALL_LOCAL[@]}")

INCLUDE_ONLY=()
EXCLUDE=()
split_csv_into INCLUDE_ONLY "$INCLUDE_ONLY_CSV"
split_csv_into EXCLUDE "$EXCLUDE_CSV"

if [ ${#INCLUDE_ONLY[@]} -gt 0 ]; then
  filtered=()
  for b in "${CANDIDATES[@]}"; do
    for pat in "${INCLUDE_ONLY[@]}"; do
      if match_glob "$b" "$pat"; then
        filtered+=("$b")
        break
      fi
    done
  done
  CANDIDATES=("${filtered[@]}")
fi

if [ ${#EXCLUDE[@]} -gt 0 ]; then
  filtered=()
  for b in "${CANDIDATES[@]}"; do
    skip=0
    for pat in "${EXCLUDE[@]}"; do
      if match_glob "$b" "$pat"; then
        skip=1
        break
      fi
    done
    if [ "$skip" -eq 0 ]; then
      filtered+=("$b")
    fi
  done
  CANDIDATES=("${filtered[@]}")
fi

# 排序
if [ ${#CANDIDATES[@]} -gt 0 ]; then
  # shellcheck disable=SC2207
  IFS=$'\n'
  CANDIDATES=($(printf '%s\n' "${CANDIDATES[@]}" | sort))
  unset IFS
fi

if [ ${#CANDIDATES[@]} -eq 0 ]; then
  warn "没有匹配到任何本地分支。"
  exit 0
fi

SELECTED=()
BRANCH_PATS=()
split_csv_into BRANCH_PATS "$BRANCHES_CSV"

if [ ${#BRANCH_PATS[@]} -gt 0 ]; then
  for pat in "${BRANCH_PATS[@]}"; do
    matched=()
    for b in "${CANDIDATES[@]}"; do
      if match_glob "$b" "$pat"; then
        matched+=("$b")
      fi
    done
    if [ ${#matched[@]} -eq 0 ]; then
      exact=()
      for b in "${ALL_LOCAL[@]}"; do
        [ "$b" = "$pat" ] && exact+=("$b")
      done
      if [ ${#exact[@]} -eq 0 ]; then
        err "指定的分支不存在或已被过滤: $pat"
        exit 1
      fi
      matched=("${exact[@]}")
    fi
    for b in "${matched[@]}"; do
      if [ ${#SELECTED[@]} -eq 0 ] || ! array_contains "$b" "${SELECTED[@]}"; then
        SELECTED+=("$b")
      fi
    done
  done
elif [ "$FLAG_ALL" -eq 1 ]; then
  SELECTED=("${CANDIDATES[@]}")
else
  echo
  info "可选本地分支（共 ${#CANDIDATES[@]} 个）:"
  idx=1
  for b in "${CANDIDATES[@]}"; do
    mark=""
    [ "$b" = "$original_branch" ] && mark=" (当前)"
    printf '  [%3d] %s%s\n' "$idx" "$b" "$mark"
    idx=$((idx + 1))
  done
  echo
  printf '\033[90m选择方式:\033[0m\n'
  printf '\033[90m  编号: 1,3,5-8\033[0m\n'
  printf '\033[90m  名称/通配: master,项目-*\033[0m\n'
  printf '\033[90m  全部: a / all / *\033[0m\n'
  printf '\033[90m  取消: 直接回车\033[0m\n'
  echo
  printf '请选择要 cherry-pick 的分支: '
  read -r raw
  if ! parse_selection "$raw"; then
    exit 1
  fi
  if [ ${#SELECTED[@]} -eq 0 ]; then
    warn "未选择任何分支，已取消。"
    exit 0
  fi
fi

echo
info "将处理 ${#SELECTED[@]} 个分支:"
for b in "${SELECTED[@]}"; do
  printf '  - %s\n' "$b"
done

if [ "$FLAG_DRY_RUN" -eq 1 ]; then
  warn "DryRun 模式，不执行实际 cherry-pick。"
  exit 0
fi

printf '确认继续？(y/N): '
read -r confirm
case "$confirm" in
  y|Y|yes|YES) ;;
  *) warn "已取消。"; exit 0 ;;
esac

ok_list=()
skip_list=()
fail_list=()

for branch in "${SELECTED[@]}"; do
  echo
  info "==== 分支: $branch ===="

  if ! git -c core.quotepath=false checkout "$branch"; then
    err "checkout 失败"
    fail_list+=("$branch")
    [ "$FLAG_CONTINUE" -eq 1 ] || break
    continue
  fi

  if git merge-base --is-ancestor "$full_hash" HEAD 2>/dev/null; then
    warn "已包含该 commit，跳过。"
    skip_list+=("$branch")
    continue
  fi

  if git cherry-pick "$full_hash"; then
    ok "cherry-pick 成功 -> $branch"
    ok_list+=("$branch")
  else
    err "cherry-pick 冲突或失败。"
    git cherry-pick --abort >/dev/null 2>&1 || true
    fail_list+=("$branch")
    if [ "$FLAG_CONTINUE" -eq 0 ]; then
      err "已中止。可用 --continue-on-conflict 跳过失败分支继续。"
      break
    fi
  fi
done

echo
info "切回原分支: $original_branch"
git -c core.quotepath=false checkout "$original_branch" >/dev/null 2>&1 || true

if [ "$did_stash" -eq 1 ]; then
  info "恢复之前的 stash..."
  if git stash pop; then
    ok "stash 已恢复。"
  else
    warn "stash pop 失败，请手动处理: git stash list / git stash pop"
  fi
fi

join_by_comma() {
  local out="" first=1 x
  for x in "$@"; do
    if [ "$first" -eq 1 ]; then
      out="$x"; first=0
    else
      out="$out, $x"
    fi
  done
  printf '%s' "$out"
}

echo
printf '\033[35m========== 结果汇总 ==========\033[0m\n'
ok  "成功 (${#ok_list[@]}): $(join_by_comma "${ok_list[@]}")"
warn "跳过 (${#skip_list[@]}): $(join_by_comma "${skip_list[@]}")"
err  "失败 (${#fail_list[@]}): $(join_by_comma "${fail_list[@]}")"

if [ ${#fail_list[@]} -gt 0 ]; then
  exit 2
fi
exit 0