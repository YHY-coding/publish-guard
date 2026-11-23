#!/bin/bash
# selftest.sh — scan.sh が働くことを、架空の混入で確かめる(一時フォルダの中だけで動く)
# 使い方: selftest.sh
# 混入は、この場で文字をつなげて作る(このファイル自体が検索に当たらないようにするため)。
# 終了コード: 0 = 全部期待どおり / 1 = 期待と違う
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCAN="$HERE/scan.sh"
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
FAIL=0
A36=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
MAIL="taro""@""sample-mail.test"
ANON="12345+sample""@""users.noreply.github.com"
TERM="架空商事ホールディングス"

mkdir -p "$T/conf" "$T/dirty" "$T/clean"
printf '# 架空の検索語\n%s\n' "$TERM" > "$T/conf/terms.txt"

# ---- 混入あり ----
cd "$T/dirty" || exit 1
git init -q .
printf 'token = %s%s\n' "gh""p_" "$A36" > a.txt                       # 1 トークンの形
printf '保存先は %s%s です\n' "/""Users/" "sample/work/" > b.md        # 2 絶対パス
printf '連絡先: %s\n' "$MAIL" > c.txt                                  # 3 メール
printf '%s\n' "-----BEGIN RSA PRIVATE"" KEY-----" > d.txt             # 4 秘密鍵のブロック
printf '取引先は%sです\n' "$TERM" > e.txt                              # 5 自分用の検索語
printf 'API_KEY="%s"\n' "abcdefghijklmnop" > .env                      # 6 ファイル名 + 7 秘密らしい代入
printf '%s%s\n' "AK""IA" "ABCDEFGHIJKLMNOP" > old.txt                  # 9 履歴だけに残す鍵
git add -A
git -c user.name=sample -c user.email="$MAIL" commit -q -m "first"     # 8 作者メール
git rm -q old.txt
git -c user.name=sample -c user.email="$MAIL" commit -q -m "remove old"
OUT=$("$SCAN" "$T/dirty" --history --config "$T/conf"); RC=$?

expect(){ # 番号 期待する種類の文字列
  if printf '%s\n' "$OUT" | grep -F -q -- "$2"; then echo "  ok   $1 $2"; else echo "  FAIL $1 $2"; FAIL=1; fi
}
echo "== 混入あり(9種類を仕込んだ)"
expect 1 "| NG | 鍵: GitHubトークンの形 | a.txt:1 |"
expect 2 "| NG | 場所: Macの絶対パス(利用者名が入る) | b.md:1 |"
expect 3 "| NG | 個人: メールアドレス(匿名用・見本用を除く) | c.txt:1 |"
expect 4 "| NG | 鍵: 秘密鍵のブロック | d.txt:1 |"
expect 5 "| NG | 自分用の検索語(設定の2行目) | e.txt:1 |"
expect 6 "| NG | ファイル名: 秘密を入れやすい名前 | .env |"
expect 7 "| NG | 鍵: 秘密らしい代入 | .env:1 |"
expect 8 "| NG | git: 匿名用でない作者・コミッターのメール(1種類。値は出さない)"
expect 9 "| NG | 履歴: 鍵: AWSアクセスキーの形 |"
[ "$RC" = 1 ] && echo "  ok   終了コード 1(公開しない)" || { echo "  FAIL 終了コード $RC"; FAIL=1; }
printf '%s\n' "$OUT" | grep -q '公開しない' && echo "  ok   「公開しない」と出た" || { echo "  FAIL 「公開しない」が出ない"; FAIL=1; }
for v in "$MAIL" "$TERM" "$A36"; do
  if printf '%s\n' "$OUT" | grep -F -q -- "$v"; then echo "  FAIL 見つかった値が出力に出ている"; FAIL=1; fi
done
echo "  ok   見つかった値(メール・検索語・鍵)は出力に出ていない"
# 読むだけの確認: 実行の前後でフォルダの中身が同じ
B1=$(cd "$T/dirty" && find . -type f -not -path './.git/*' -exec cksum {} + | sort)
"$SCAN" "$T/dirty" --history --config "$T/conf" >/dev/null
B2=$(cd "$T/dirty" && find . -type f -not -path './.git/*' -exec cksum {} + | sort)
[ "$B1" = "$B2" ] && [ -z "$(cd "$T/dirty" && git status --porcelain)" ] && echo "  ok   実行の前後でファイルは変わっていない" || { echo "  FAIL ファイルが変わった"; FAIL=1; }

# ---- 混入なし ----
cd "$T/clean" || exit 1
git init -q .
printf '# 見本\n架空のデータだけの見本です。連絡先: info@example.com\n' > README.md
printf '<!doctype html><title>見本</title><p>こんにちは</p>\n' > index.html
git add -A
git -c user.name=sample -c user.email="$ANON" commit -q -m "first"
git config user.email "$ANON"
OUT2=$("$SCAN" "$T/clean" --history --config "$T/conf"); RC2=$?
echo "== 混入なし"
printf '%s\n' "$OUT2" | grep -F -q '**結果: NG=0 / WARN=0**' && echo "  ok   NG=0 / WARN=0" || { echo "  FAIL 0件にならない"; printf '%s\n' "$OUT2"; FAIL=1; }
[ "$RC2" = 0 ] && echo "  ok   終了コード 0" || { echo "  FAIL 終了コード $RC2"; FAIL=1; }

[ "$FAIL" = 0 ] && echo "== 自己確認: 全部期待どおり" || echo "== 自己確認: 期待と違う所がある"
exit "$FAIL"
