#!/bin/bash
# scan.sh — 公開前の検索(読むだけ。調べるフォルダも設定も書き換えない)
#
# 使い方: scan.sh <調べるフォルダ> [--history] [--app] [--config <設定フォルダ>]
#   --history : git の履歴(全ブランチ)の差分とコミットの文面も調べる
#   --app     : Webアプリ向けの追加の確認(外部URL・通信・innerHTML など。WARN)
#   --config  : 自分用の検索語を置くフォルダ(既定: $PUBLISH_GUARD_CONFIG、なければ ~/.config/publish-guard)
#               その中の terms.txt に、1行1語で書く(勤め先名・本名・アカウント名など。# で始まる行は読み飛ばす)
# 出力: 「重大度・種類・場所」の表。見つかった値(鍵・メール・検索語)は出さない。
# 終了コード: 0 = NGなし / 1 = NGあり(公開しない) / 2 = 使い方の誤り
# 例外の許可(このメールは出してよい、など)を登録する仕組みは、わざと入れていない。
set -u

usage(){ sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }

DIR=""; HIST=0; APP=0
CONF="${PUBLISH_GUARD_CONFIG:-$HOME/.config/publish-guard}"
while [ $# -gt 0 ]; do
  case "$1" in
    --history) HIST=1 ;;
    --app) APP=1 ;;
    --config) shift; CONF="${1:-}"; [ -n "$CONF" ] || { usage; exit 2; } ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "不明なオプション: $1"; usage; exit 2 ;;
    *) if [ -z "$DIR" ]; then DIR="$1"; else usage; exit 2; fi ;;
  esac
  shift
done
[ -n "$DIR" ] && [ -d "$DIR" ] || { usage; exit 2; }
case "$CONF" in /*) ;; *) CONF="$(pwd)/$CONF" ;; esac
cd "$DIR" || exit 2

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
RES="$TMP/res"; : > "$RES"
EX=(--exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.next --exclude-dir=.venv --exclude=package-lock.json '--exclude=*.lock')

# 種類|重大度|大文字小文字(i=区別しない)|検索パターン(ERE)
IFS= read -r -d '' RULES <<'RULES_EOF'
鍵: GitHubトークンの形|NG|-|(gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})
鍵: AIサービスのAPIキーの形|NG|-|(sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{40,})
鍵: AWSアクセスキーの形|NG|-|AKIA[0-9A-Z]{16}
鍵: Slack・Stripeの形|NG|-|(xox[baprs]-[A-Za-z0-9-]{10,}|sk_live_[A-Za-z0-9]{10,}|rk_live_[A-Za-z0-9]{10,})
鍵: 秘密鍵のブロック|NG|-|-----BEGIN [A-Z ]*PRIVATE KEY-----
鍵: JSONの秘密鍵・サービスアカウント|NG|-|("private_key"[[:space:]]*:|"type"[[:space:]]*:[[:space:]]*"service_account")
鍵: JWTの形|NG|-|eyJ[A-Za-z0-9_-]{15,}\.eyJ[A-Za-z0-9_-]{15,}\.
鍵: 秘密らしい代入|NG|i|(password|passwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token|client_secret)["']?[[:space:]]*[:=][[:space:]]*["'][A-Za-z0-9/+_=.-]{12,}["']
鍵: FirebaseのWebキーの形(公開前提のキー。意図を確認)|WARN|-|AIza[0-9A-Za-z_-]{30,}
場所: Macの絶対パス(利用者名が入る)|NG|-|/[U]sers/[A-Za-z0-9._-]+/
場所: Windowsの絶対パス(利用者名が入る)|NG|-|[A-Za-z]:\\[U]sers\\[A-Za-z0-9._-]+
場所: Linuxのホームらしいパス|WARN|-|(^|[^A-Za-z0-9._/-])/home/[a-z_][a-z0-9_-]*/
個人: 電話番号らしい並び|WARN|-|(^|[^0-9])0[0-9]{1,4}-[0-9]{1,4}-[0-9]{3,4}([^0-9]|$)
RULES_EOF
IFS= read -r -d '' APPRULES <<'RULES_EOF'
アプリ: 外部URLの読み込み・送信先|WARN|-|(src|href|action)=["']https?://
アプリ: 通信・解析らしい書き方|WARN|-|(gtag|googletagmanager|google-analytics|sendBeacon|XMLHttpRequest|WebSocket)
アプリ: 入力をそのまま出すおそれのある書き方|WARN|-|(eval\(|innerHTML|outerHTML|insertAdjacentHTML|document\.write|dangerouslySetInnerHTML)
RULES_EOF
EMAIL='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
# 出してよいと決めてあるメールの形(匿名用・見本用)。利用者が足す仕組みはない
export PG_ALLOW='(@users\.noreply\.github\.com$|@example\.(com|org|net)$|^(noreply|no-reply)@)'
export PG_NOTMAIL='\.(png|jpe?g|gif|svg|webp|avif|ico)$'

# 標準入力: 1行1件(末尾がメール。前に「場所:」が付いていてもよい)→ 許可外だけを通す
email_filter(){
  awk 'BEGIN{a=ENVIRON["PG_ALLOW"]; n=ENVIRON["PG_NOTMAIL"]}
       {m=$0; sub(/^.*:/,"",m); m=tolower(m); if (m !~ a && m !~ n) print}'
}
add(){ # 重大度 種類 場所
  printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$RES"
}
scan_rules(){ # $1 = ルール群
  printf '%s\n' "$1" | while IFS='|' read -r kind sev fl pat; do
    [ -z "$kind" ] && continue
    opt=-rEIn; [ "$fl" = i ] && opt=-rEIni
    grep $opt "${EX[@]}" -e "$pat" . 2>/dev/null | cut -d: -f1,2 | sed 's|^\./||' | sort -u |
      while IFS= read -r loc; do add "$sev" "$kind" "$loc"; done
  done
}
read_terms(){ # 設定の検索語を「行番号<TAB>語」で出す
  [ -f "$CONF/terms.txt" ] || return 0
  awk '{sub(/\r$/,"")} /^[[:space:]]*#/ {next} /^[[:space:]]*$/ {next} {print NR "\t" $0}' "$CONF/terms.txt"
}
list_files(){
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then git ls-files 2>/dev/null
  else find . -type f -not -path './.git/*' | sed 's|^\./||'; fi
}
SECRETNAME='(^|/)(\.env[^/]*|.*\.pem|.*\.p12|.*\.pfx|id_rsa[^/]*|id_ed25519[^/]*|.*serviceAccount.*\.json|.*credentials.*\.json|\.npmrc|\.netrc)$'

# ---- 1. いまのファイル ----
scan_rules "$RULES"
[ "$APP" = 1 ] && scan_rules "$APPRULES"

grep -rEIno "${EX[@]}" -e "$EMAIL" . 2>/dev/null | email_filter | cut -d: -f1,2 | sed 's|^\./||' | sort -u |
  while IFS= read -r loc; do add NG "個人: メールアドレス(匿名用・見本用を除く)" "$loc"; done

if [ -f "$CONF/terms.txt" ]; then
  read_terms | while IFS="$(printf '\t')" read -r n t; do
    grep -rIFin "${EX[@]}" -e "$t" . 2>/dev/null | cut -d: -f1,2 | sed 's|^\./||' | sort -u |
      while IFS= read -r loc; do add NG "自分用の検索語(設定の${n}行目)" "$loc"; done
    list_files | grep -Fi -e "$t" | while IFS= read -r f; do add NG "自分用の検索語がファイル名にある(設定の${n}行目)" "$f"; done
  done
  TERMS_NOTE="自分用の検索語: $(read_terms | wc -l | tr -d ' ') 語を検索した"
else
  add WARN "設定: 自分用の検索語がない(勤め先名・本名・アカウント名などは調べていない)" "設定フォルダに terms.txt を置く"
  TERMS_NOTE="自分用の検索語: なし(未検査)"
fi

list_files | grep -E "$SECRETNAME" | grep -v -E '\.env\.(example|sample)$' |
  while IFS= read -r f; do add NG "ファイル名: 秘密を入れやすい名前" "$f"; done
list_files | grep -E '(^|/)(\.DS_Store|node_modules/.*|.*\.(csv|xlsx?|log|sqlite3?|db|zip))$' |
  while IFS= read -r f; do add WARN "同梱物: データ・ログ・zip・OSの残りもの(中身を目で確認)" "$f"; done

# ---- 2. git の作者・履歴 ----
GITNOTE="gitリポジトリではない(作者メール・履歴は調べていない)"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  TOP=$(git rev-parse --show-toplevel 2>/dev/null); HERE=$(pwd -P)
  if [ "$TOP" = "$HERE" ]; then GITNOTE="git: リポジトリの最上位を調べた"
  else GITNOTE="git: このフォルダは上位のリポジトリの一部。このフォルダに触れたコミットだけを調べた(公開するリポジトリの最上位でも実行する)"; fi

  git log --all --format='%ae%n%ce' -- . 2>/dev/null | sed '/^$/d' | sort -u | email_filter > "$TMP/authors"
  if [ -s "$TMP/authors" ]; then
    n=$(wc -l < "$TMP/authors" | tr -d ' ')
    c=$(git log --all --format='%ae %ce' -- . 2>/dev/null | tr ' ' '\n' | email_filter | wc -l | tr -d ' ')
    add NG "git: 匿名用でない作者・コミッターのメール(${n}種類。値は出さない)" "コミットの作者欄(のべ${c}か所)"
  fi
  LOCALMAIL=$(git config user.email 2>/dev/null || true)
  if [ -n "$LOCALMAIL" ] && [ -n "$(printf '%s\n' "$LOCALMAIL" | email_filter)" ]; then
    add WARN "git: user.email の設定が匿名用でない(次のコミットに入る)" "git config user.email"
  fi

  if [ "$HIST" = 1 ]; then
    GITNOTE="$GITNOTE/履歴(差分と文面)も調べた"
    git log --all --format='%B' -- . > "$TMP/msgs" 2>/dev/null
    printf '%s\n' "$RULES" | while IFS='|' read -r kind sev fl pat; do
      [ -z "$kind" ] && continue
      iopt=""; gopt=-Ec; [ "$fl" = i ] && { iopt=-i; gopt=-Eci; }
      c=$(git log --all $iopt -G"$pat" --format=%h -- . 2>/dev/null | sort -u | wc -l | tr -d ' ')
      if [ "$c" != 0 ]; then
        ex=$(git log --all $iopt -G"$pat" --format=%h -- . 2>/dev/null | head -2 | tr '\n' ' ')
        add "$sev" "履歴: $kind" "${c}コミットの差分(例 ${ex% })"
      fi
      m=$(grep $gopt -e "$pat" "$TMP/msgs" 2>/dev/null)
      [ "${m:-0}" != 0 ] && add "$sev" "履歴の文面: $kind" "コミットの文面 ${m}行"
    done
    n=$(git log --all -p --format= -- . 2>/dev/null | grep -E '^[+-]' | grep -Eo -e "$EMAIL" | sort -u | email_filter | wc -l | tr -d ' ')
    [ "$n" != 0 ] && add NG "履歴: メールアドレス(匿名用・見本用を除く。${n}種類。値は出さない)" "過去の差分"
    n=$(grep -Eo -e "$EMAIL" "$TMP/msgs" 2>/dev/null | sort -u | email_filter | wc -l | tr -d ' ')
    [ "$n" != 0 ] && add NG "履歴の文面: メールアドレス(匿名用・見本用を除く。${n}種類)" "コミットの文面"
    read_terms | while IFS="$(printf '\t')" read -r n t; do
      c=$(git log --all -i -S"$t" --format=%h -- . 2>/dev/null | sort -u | wc -l | tr -d ' ')
      [ "$c" != 0 ] && add NG "履歴: 自分用の検索語(設定の${n}行目)" "${c}コミットの差分"
      m=$(grep -Fic -e "$t" "$TMP/msgs" 2>/dev/null)
      [ "${m:-0}" != 0 ] && add NG "履歴の文面: 自分用の検索語(設定の${n}行目)" "コミットの文面 ${m}行"
    done
    git log --all --diff-filter=A --name-only --format= -- . 2>/dev/null | grep -E "$SECRETNAME" | grep -v -E '\.env\.(example|sample)$' | sort -u |
      while IFS= read -r f; do add NG "履歴: 秘密を入れやすい名前のファイルが過去に追加された" "$f"; done
  fi
fi

# ---- 3. 結果 ----
NG=$(grep -c '^NG|' "$RES"); WARN=$(grep -c '^WARN|' "$RES")
echo "## 公開前の検索: $(basename "$(pwd -P)")($(date +%Y-%m-%d))"
echo
echo "- 範囲: いまのファイル(文字のファイルだけ。画像・PDF・Excelの中身は調べていない)"
echo "- $GITNOTE"
echo "- $TERMS_NOTE"
echo
if [ -s "$RES" ]; then
  echo "| 重大度 | 種類 | 場所(ファイル:行) |"
  echo "|---|---|---|"
  sort -t'|' -k1,1 -k2,2 "$RES" | awk -F'|' '
    { k=$1 FS $2; c[k]++; if (c[k]<=20) print "| " $1 " | " $2 " | " $3 " |"; else over[k]=c[k]-20 }
    END { for (k in over) { split(k,a,FS); print "| " a[1] " | " a[2] " | ほか " over[k] " か所(省略) |" } }'
  echo
fi
echo "**結果: NG=${NG} / WARN=${WARN}**"
if [ "$NG" != 0 ]; then
  echo "**公開しない。** NG をなくしてから、もう一度実行する。"
  exit 1
fi
if [ "$WARN" != 0 ]; then
  echo "NG は 0。WARN は1件ずつ目で確かめ、理由を記録してから進む。"
else
  echo "NG は 0、WARN も 0。"
fi
echo "この検索は、決めたパターンとの一致を見るだけ。0件でも「問題がない」ことの証明ではない。"
exit 0
