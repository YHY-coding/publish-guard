#!/usr/bin/env python3
"""claim_check.py — 文書の「数字に日付と出典があるか」「保証表現がないか」を検出する(読むだけ。文は直さない)

使い方:
  claim_check.py <ファイル>... [--words <語のファイル>]... [--no-default-words] [--no-numbers] [--config <設定フォルダ>]

  --words            足したい語のファイル(何回でも)。1行1件「語<TAB>理由」。理由は省ける。# の行は読み飛ばす。
                     「re:」で始めると正規表現として扱う。
  --no-default-words 同梱の語(references/guarantee-words.txt)を使わない
  --no-numbers       数字の確認をしない(語だけ調べる)
  --config           設定フォルダ(既定: 環境変数 PUBLISH_GUARD_CONFIG、なければ ~/.config/publish-guard)。
                     その中に claim-words.txt があれば、足す語として読む。

出力: 「行・語・理由」の表(Markdown)。終了コード: 0 = 検出なし / 1 = 検出あり / 2 = 使い方の誤り
"""
import argparse
import os
import re
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_WORDS = os.path.join(HERE, "..", "references", "guarantee-words.txt")

DATE = re.compile(
    r"(\d{4}\s*年(\s*\d{1,2}\s*月)?(\s*\d{1,2}\s*日)?|\d{4}年度|\d{4}[-/.]\d{1,2}([-/.]\d{1,2})?"
    r"|(令和|平成|昭和)\s*(\d{1,2}|元)\s*年|\d{1,2}\s*月\s*\d{1,2}\s*日)"
)
SOURCE = re.compile(
    r"(出典|出所|参照|引用元|参考[::]|資料[::]|調べ|による(と|。|、|$|\))|公表|発表|公式|白書|統計|https?://|\[\^?\d+\]|※\s*\d+|source|according to)",
    re.I,
)
UNITS = (
    "パーセント|ポイント|フォロワー|万円|億円|兆円|ドル|時間|日間|週間|か月|ヶ月|カ月|ケ月|年間|"
    "%|割|倍|円|万|億|兆|人|名|件|社|個|本|回|位|点|分|秒|歳|kg|km|cm|mm|GB|MB|PV|pt"
)
NUM = re.compile(r"(?<![A-Za-z0-9_.#/-])(\d[\d,]*(?:\.\d+)?)\s*(" + UNITS + r")(?![A-Za-z])")
NEG = re.compile(r"(とは限ら|わけではな|ではな[いく]|ではありません|しません|できません|ません|しない|できない|はない|もない|ないこと|保証しない|保証はな)")
FENCE = re.compile(r"^\s*(```|~~~)")
URL = re.compile(r"https?://\S+")
INLINE_CODE = re.compile(r"`[^`]*`")
SENT_END = re.compile(r"[。!?!?\n]")


def nfkc(s):
    return unicodedata.normalize("NFKC", s)


def load_words(path):
    items = []
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n").rstrip("\r")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            word, _, reason = line.partition("\t")
            word = word.strip()
            reason = reason.strip() or "利用者が足した語"
            if word.startswith("re:"):
                pat = re.compile(word[3:], re.I)
            else:
                pat = re.compile(re.escape(nfkc(word)), re.I)
            items.append((pat, reason))
    return items


def sentence_around(text, start, end):
    left = 0
    for m in SENT_END.finditer(text, 0, start):
        left = m.end()
    m = SENT_END.search(text, end)
    right = m.start() if m else len(text)
    return text[left:right]


def check_file(path, words, do_numbers):
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = [nfkc(l.rstrip("\n")) for l in f]
    rows = []
    in_fence = False
    # 段落(空行で区切る)ごとに、日付と出典の有無を見る
    paras = []  # (開始行, 終了行)
    start = None
    usable = []
    for i, line in enumerate(lines):
        if FENCE.match(line):
            in_fence = not in_fence
            usable.append(False)
            if start is not None:
                paras.append((start, i))
                start = None
            continue
        usable.append(not in_fence)
        if in_fence or not line.strip():
            if start is not None:
                paras.append((start, i))
                start = None
        elif start is None:
            start = i
    if start is not None:
        paras.append((start, len(lines)))

    for s, e in paras:
        block = "\n".join(lines[s:e])
        has_date = bool(DATE.search(block))
        has_source = bool(SOURCE.search(block))
        for i in range(s, e):
            if not usable[i]:
                continue
            line = lines[i]
            plain = INLINE_CODE.sub(" ", URL.sub(" ", line))
            for pat, reason in words:
                for m in pat.finditer(plain):
                    r = "保証表現: " + reason
                    if NEG.search(sentence_around(plain, m.start(), m.end())):
                        r += "(否定の文の中かもしれない。目で確かめる)"
                    rows.append((i + 1, m.group(0), r))
            if do_numbers and not (has_date and has_source):
                nodate = DATE.sub(" ", plain)
                for m in NUM.finditer(nodate):
                    lack = []
                    if not has_date:
                        lack.append("日付")
                    if not has_source:
                        lack.append("出典")
                    rows.append((i + 1, m.group(1) + m.group(2), "数字: 同じ段落に" + "と".join(lack) + "がない"))
    rows.sort(key=lambda r: r[0])
    return rows


def main():
    ap = argparse.ArgumentParser(add_help=True, description="数字の日付・出典と保証表現の検出(読むだけ)")
    ap.add_argument("files", nargs="+")
    ap.add_argument("--words", action="append", default=[])
    ap.add_argument("--no-default-words", action="store_true")
    ap.add_argument("--no-numbers", action="store_true")
    ap.add_argument("--config", default=os.environ.get("PUBLISH_GUARD_CONFIG") or os.path.join(os.path.expanduser("~"), ".config", "publish-guard"))
    try:
        a = ap.parse_args()
    except SystemExit as ex:
        sys.exit(0 if ex.code == 0 else 2)

    words = []
    sources = []
    try:
        if not a.no_default_words:
            words += load_words(DEFAULT_WORDS)
            sources.append("同梱の語")
        user = os.path.join(a.config, "claim-words.txt")
        if os.path.isfile(user):
            words += load_words(user)
            sources.append("設定フォルダの claim-words.txt")
        for w in a.words:
            words += load_words(w)
            sources.append(os.path.basename(w))
    except (OSError, re.error) as ex:
        print("語のファイルを読めない: %s" % ex, file=sys.stderr)
        sys.exit(2)

    total = 0
    for path in a.files:
        if not os.path.isfile(path):
            print("ファイルがない: %s" % path, file=sys.stderr)
            sys.exit(2)
        rows = check_file(path, words, not a.no_numbers)
        total += len(rows)
        print("## 検出: %s" % path)
        print()
        if rows:
            print("| 行 | 語 | 理由 |")
            print("|---|---|---|")
            for ln, word, reason in rows:
                print("| %d | %s | %s |" % (ln, word.replace("|", "\\|"), reason))
        else:
            print("検出なし。")
        print()
    print("**検出 %d 件**(使った語: %s / 数字の確認: %s)" % (total, "・".join(sources) or "なし", "しない" if a.no_numbers else "する"))
    print("決めた語と形に当たるものを並べただけ。0件でも、内容が正しいことの確認にはならない。文は直していない。")
    sys.exit(1 if total else 0)


if __name__ == "__main__":
    main()
