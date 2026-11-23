#!/bin/bash
# publish-verify.sh — 公開の前の関門(pre)と、公開のあとの突き合わせ(post)
#
# 使い方:
#   publish-verify.sh pre  <手元のフォルダ> [--config <設定フォルダ>]
#   publish-verify.sh post <手元のフォルダ> <公開したリポジトリのURL> [--pages <PagesのURL>] [--record <記録ファイル>]
#
# pre : 公開してよい状態かを確かめる(読むだけ)。1つでも外れたら止める(終了コード 1)。
#       ・リポジトリの最上位である ・コミットがある ・未コミットの変更がない
#       ・リモートが未設定(=新しいリポジトリとして出す。既存のリポジトリには使わない)
#       ・user.email が匿名用(…@users.noreply.github.com) ・全コミットの作者とコミッターが匿名用
#       ・公開前の検索(prepublish-scan の scan.sh --history)で NG=0
# post: 公開したものを一時フォルダに clone し、手元と1ファイルずつ cmp で比べる。作者メールも clone 側で確かめる。
#       --pages を付けると、Pages の各ファイルも取りに行って cmp で比べる。
#       --record を付けると、結果を記録ファイル(Markdown)に書く。差分 0・作者が全部匿名用のときだけ終了コード 0。
# このスクリプトは、リポジトリの作成・push・Pages の設定・履歴の書き換えをしない。
set -u
ANON='^[^@[:space:]]+@users\.noreply\.github\.com$'
usage(){ sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }
HERE=$(cd "$(dirname "$0")" && pwd)
SCAN="$HERE/../../prepublish-scan/scripts/scan.sh"

MODE="${1:-}"; [ $# -gt 0 ] && shift
case "$MODE" in pre|post) ;; -h|--help) usage; exit 0 ;; *) usage; exit 2 ;; esac
DIR="${1:-}"; [ $# -gt 0 ] && shift
[ -n "$DIR" ] && [ -d "$DIR" ] || { usage; exit 2; }
DIR=$(cd "$DIR" && pwd -P)
START=$(pwd)
abspath(){ case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$START" "$1" ;; esac; }

FAIL=0
row(){ # 項目 結果(OK/NG/—) 補足
  printf '| %s | %s | %s |\n' "$1" "$2" "$3"
  [ "$2" = NG ] && FAIL=1
  return 0
}
bad_emails(){ # 標準入力のメールのうち、匿名用でないものの種類の数
  sed '/^$/d' | sort -u | grep -Evc "$ANON"
}

if [ "$MODE" = pre ]; then
  CONFOPT=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --config) shift; [ -n "${1:-}" ] || { usage; exit 2; }; CONFOPT=(--config "$(abspath "$1")") ;;
      *) usage; exit 2 ;;
    esac; shift
  done
  cd "$DIR" || exit 2
  echo "## 公開の前の関門: $(basename "$DIR")($(date +%Y-%m-%d))"
  echo
  echo "| 項目 | 結果 | 補足 |"
  echo "|---|---|---|"
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    row "gitリポジトリである" NG "git init して、匿名用のメールでコミットしてから"
    echo; echo "**結果: 公開しない。**"; exit 1
  fi
  TOP=$(git rev-parse --show-toplevel)
  if [ "$TOP" = "$DIR" ]; then row "リポジトリの最上位である" OK ""; else row "リポジトリの最上位である" NG "上位のリポジトリの一部。出すものだけを新しいフォルダに分ける"; fi
  N=$(git rev-list --all --count 2>/dev/null || echo 0)
  if [ "$N" -gt 0 ]; then row "コミットがある" OK "${N}件"; else row "コミットがある" NG "0件"; fi
  if [ -z "$(git status --porcelain 2>/dev/null)" ]; then row "未コミットの変更がない" OK ""; else row "未コミットの変更がない" NG "コミットしたものだけが公開される。手元と食い違う"; fi
  if [ -z "$(git remote 2>/dev/null)" ]; then row "リモートが未設定(新しいリポジトリとして出す)" OK ""; else row "リモートが未設定(新しいリポジトリとして出す)" NG "すでにリモートがある。既存のリポジトリには使わない"; fi
  UE=$(git config user.email 2>/dev/null || true)
  if printf '%s\n' "$UE" | grep -Eq "$ANON"; then row "user.email が匿名用" OK ""; else row "user.email が匿名用" NG "…@users.noreply.github.com の形にする(値は表示しない)"; fi
  B=$(git log --all --format='%ae%n%ce' 2>/dev/null | bad_emails)
  if [ "$B" = 0 ] && [ "$N" -gt 0 ]; then row "全コミットの作者・コミッターが匿名用" OK ""; else row "全コミットの作者・コミッターが匿名用" NG "匿名用でないメールが${B}種類。履歴は書き換えない。新しいフォルダで作り直す"; fi
  if [ -x "$SCAN" ] || [ -f "$SCAN" ]; then
    SOUT=$(bash "$SCAN" "$DIR" --history ${CONFOPT[@]+"${CONFOPT[@]}"}); SRC=$?
    SUM=$(printf '%s\n' "$SOUT" | grep -F '**結果:' | tr -d '*')
    if [ "$SRC" = 0 ]; then row "公開前の検索(履歴も)" OK "$SUM"; else row "公開前の検索(履歴も)" NG "$SUM"; fi
  else
    row "公開前の検索(履歴も)" NG "scan.sh が見つからない。検索せずに公開しない"
  fi
  echo
  if [ "$FAIL" = 0 ]; then
    echo "**結果: 関門は全部 OK。** 公開するかどうかは、人がその都度決める。"
    [ -n "${SOUT:-}" ] && printf '%s\n' "$SOUT" | grep -q 'WARN=[1-9]' && { echo; echo "検索の WARN(目で確かめる):"; printf '%s\n' "$SOUT" | grep -F '| WARN |'; }
    exit 0
  fi
  echo "**結果: 公開しない。** NG をなくしてから、もう一度実行する。"
  exit 1
fi

# ---- post ----
URL="${1:-}"; [ $# -gt 0 ] && shift
[ -n "$URL" ] || { usage; exit 2; }
PAGES=""; RECORD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pages) shift; PAGES="${1:-}"; [ -n "$PAGES" ] || { usage; exit 2; } ;;
    --record) shift; [ -n "${1:-}" ] || { usage; exit 2; }; RECORD=$(abspath "$1") ;;
    *) usage; exit 2 ;;
  esac; shift
done
TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/out.md"
{
  echo "## 公開のあとの突き合わせ: $(basename "$DIR")($(date '+%Y-%m-%d %H:%M'))"
  echo
  echo "- 公開先: $URL"
  [ -n "$PAGES" ] && echo "- Pages: $PAGES"
  echo
  echo "| 項目 | 結果 | 補足 |"
  echo "|---|---|---|"
  if ! git clone --quiet "$URL" "$TMP/clone" 2>"$TMP/clone.err"; then
    row "clone できる" NG "取得できなかった"
  else
    row "clone できる" OK ""
    LH=$(git -C "$DIR" rev-parse HEAD 2>/dev/null); CH=$(git -C "$TMP/clone" rev-parse HEAD 2>/dev/null)
    if [ -n "$LH" ] && [ "$LH" = "$CH" ]; then row "最新のコミットが同じ" OK "$(printf '%s' "$LH" | cut -c1-7)"; else row "最新のコミットが同じ" NG "手元 $(printf '%s' "$LH" | cut -c1-7) / 公開先 $(printf '%s' "$CH" | cut -c1-7)"; fi
    git -C "$DIR" ls-files > "$TMP/local.lst"; git -C "$TMP/clone" ls-files > "$TMP/remote.lst"
    TOTAL=$(wc -l < "$TMP/local.lst" | tr -d ' '); DIFF=0; : > "$TMP/diff.lst"
    while IFS= read -r f; do
      if [ ! -f "$TMP/clone/$f" ]; then DIFF=$((DIFF+1)); echo "公開先にない: $f" >> "$TMP/diff.lst"
      elif ! cmp -s "$DIR/$f" "$TMP/clone/$f"; then DIFF=$((DIFF+1)); echo "中身が違う: $f" >> "$TMP/diff.lst"; fi
    done < "$TMP/local.lst"
    EXTRA=$(sort "$TMP/local.lst" > "$TMP/l.s"; sort "$TMP/remote.lst" > "$TMP/r.s"; comm -13 "$TMP/l.s" "$TMP/r.s" | tee -a "$TMP/extra.lst" | wc -l | tr -d ' ')
    [ "$EXTRA" != 0 ] && sed 's/^/手元にない: /' "$TMP/extra.lst" >> "$TMP/diff.lst"
    DIFF=$((DIFF+EXTRA))
    if [ "$DIFF" = 0 ]; then row "cmp: 手元と公開先(clone)が一致" OK "${TOTAL}ファイル、差分 0"; else row "cmp: 手元と公開先(clone)が一致" NG "${TOTAL}ファイル中、差分 ${DIFF}"; fi
    B=$(git -C "$TMP/clone" log --all --format='%ae%n%ce' 2>/dev/null | bad_emails)
    if [ "$B" = 0 ]; then row "公開先の全コミットの作者・コミッターが匿名用" OK ""; else row "公開先の全コミットの作者・コミッターが匿名用" NG "匿名用でないメールが${B}種類(値は表示しない)"; fi
  fi
  if [ -n "$PAGES" ]; then
    BASE="${PAGES%/}"; PT=0; PD=0; PM=0
    while IFS= read -r f; do
      case "$f" in .*|*/.*|_*|*/_*|*' '*) continue ;; esac   # Pages が配らない名前・空白入りは対象外
      PT=$((PT+1))
      if curl -fsSL --max-time 30 -o "$TMP/page.bin" "$BASE/$f" 2>/dev/null; then
        cmp -s "$DIR/$f" "$TMP/page.bin" || { PD=$((PD+1)); echo "Pagesの中身が違う: $f" >> "$TMP/diff.lst"; }
      else PM=$((PM+1)); echo "Pagesから取れない: $f" >> "$TMP/diff.lst"; fi
    done < "$TMP/local.lst"
    if [ "$PT" -gt 0 ] && [ "$PD" = 0 ] && [ "$PM" = 0 ]; then row "cmp: 手元とPagesが一致" OK "${PT}ファイル、差分 0"
    else row "cmp: 手元とPagesが一致" NG "${PT}ファイル中、違う ${PD}・取れない ${PM}(反映待ちなら数分後にもう一度)"; fi
  fi
  if [ -s "$TMP/diff.lst" ]; then echo; echo "食い違い:"; sed 's/^/- /' "$TMP/diff.lst"; fi
  echo
  if [ "$FAIL" = 0 ]; then echo "**結果: 一致(差分 0)。作者は全部匿名用。**"; else echo "**結果: 未完了。** 食い違いの原因が分かるまで「公開できた」としない。"; fi
  echo "$FAIL" > "$TMP/fail"
} > "$OUT"
FAIL=$(cat "$TMP/fail" 2>/dev/null || echo 1)
cat "$OUT"
if [ -n "$RECORD" ]; then
  mkdir -p "$(dirname "$RECORD")" && cat "$OUT" >> "$RECORD" && echo && echo "記録: $(basename "$RECORD") に書いた"
fi
exit "$FAIL"
