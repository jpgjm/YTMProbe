#!/usr/bin/env python3
"""
check.py — YTMProbe.x の構造を静的に点検する。

── なぜ必要か ──────────────────────────────────────────────────
この環境では ObjC を実際にコンパイルできない (Foundation / UIKit が
無い) ため、ビルドエラーは GitHub Actions を 1 往復しないと分からない。
1 往復が長いので、機械的に見つけられるものはここで潰す。

実際に踏んだ失敗を、そのまま検査項目にしてある。

  v0.1.1  ARC 下の performSelector: (-Werror で止まる)
  v0.1.1  UIApplication.keyWindow が非推奨
  v0.2.1  静的関数を定義より前で呼んだ
  v0.2.2  ObjC クラスを @interface より前で使った

── 使い方 ──────────────────────────────────────────────────────
    python3 check.py            # YTMProbe.x を点検
    python3 check.py path.x     # ファイルを指定
終了コード 0 なら問題なし、1 なら要修正。
"""

import re
import sys

RESET = "\033[0m"
RED = "\033[31m"
GREEN = "\033[32m"


def strip_comments(src):
    """行コメントを空行に潰す。コメント内の記述を「使用」と誤判定しないため。"""
    out = []
    for line in src.split("\n"):
        s = line.lstrip()
        out.append("" if s.startswith("//") else line)
    return "\n".join(out)


def strip_strings(src):
    """
    文字列リテラルの中身を潰す。

    括弧の対応を数えるとき、ログ文言に入っている
    `-[YTIWatchEndpoint setVideoId:]` のような文字列の `]` を
    数えてしまい、誤検出になる (実際に踏んだ)。
    行の構造は保ちたいので、改行以外を空白に置き換える。
    """
    out = []
    i, n = 0, len(src)
    in_str = False
    while i < n:
        ch = src[i]
        if in_str:
            if ch == "\\" and i + 1 < n:
                out.append(" " if src[i + 1] != "\n" else "\n")
                out.append(" ")
                i += 2
                continue
            if ch == '"':
                in_str = False
                out.append(ch)
            elif ch == "\n":
                out.append("\n")
            else:
                out.append(" ")
        else:
            out.append(ch)
            if ch == '"':
                in_str = True
        i += 1
    return "".join(out)


def line_of(src, pos):
    return src[:pos].count("\n") + 1


class Report:
    def __init__(self):
        self.failed = False

    def ok(self, label, detail=""):
        print(f"  {GREEN}OK{RESET}  {label}" + (f"  {detail}" if detail else ""))

    def ng(self, label, detail=""):
        self.failed = True
        print(f"  {RED}NG{RESET}  {label}" + (f"  {detail}" if detail else ""))


def check_declaration_order(code, rep):
    """宣言より前で使っていないか。v0.2.1 と v0.2.2 で踏んだ失敗。"""
    print("\n[宣言順序]")

    # ObjC クラス
    for m in re.finditer(r"^@interface\s+(\w+)\s*:", code, re.M):
        name = m.start(), m.group(1)
        decl_pos, cls = name
        uses = [u.start() for u in re.finditer(rf"\b{cls}\b", code)]
        first = min([u for u in uses if u != decl_pos], default=None)
        if first is None or decl_pos < first:
            rep.ok(f"@interface {cls}")
        else:
            rep.ng(f"@interface {cls}",
                   f"宣言 L{line_of(code, decl_pos)} / 使用 L{line_of(code, first)}")

    # 静的関数の前方宣言
    for m in re.finditer(r"^static\s+[^;{]+?\b(\w+)\s*\([^;{]*?\)\s*;",
                         code, re.M | re.S):
        fn, decl_pos = m.group(1), m.start()
        body = re.search(rf"^static[^;{{]+?\b{fn}\s*\([^;{{]*?\)\s*{{",
                         code, re.M | re.S)
        calls = [c.start() for c in re.finditer(rf"\b{fn}\s*\(", code)]
        ignore = {decl_pos} | ({body.start()} if body else set())
        first = min([c for c in calls if c not in ignore], default=None)
        if first is None or decl_pos < first:
            rep.ok(f"static {fn}()")
        else:
            rep.ng(f"static {fn}()",
                   f"宣言 L{line_of(code, decl_pos)} / 使用 L{line_of(code, first)}")


def check_declaration_matches_definition(code, rep):
    """前方宣言と実定義のシグネチャが一致するか。"""
    print("\n[宣言と定義の一致]")

    def norm(s):
        return " ".join(s.split())

    decls, defs = {}, {}
    for m in re.finditer(r"^static\s+([^;{]+?)\b(\w+)\s*\(([^;{]*?)\)\s*;",
                         code, re.M | re.S):
        decls[m.group(2)] = (norm(m.group(1)), norm(m.group(3)))
    for m in re.finditer(r"^static\s+([^;{]+?)\b(\w+)\s*\(([^;{]*?)\)\s*\{",
                         code, re.M | re.S):
        defs[m.group(2)] = (norm(m.group(1)), norm(m.group(3)))

    for name in sorted(set(decls) | set(defs)):
        d, f = decls.get(name), defs.get(name)
        if d is None:
            rep.ok(f"{name} (前方宣言なし・定義のみ)")
        elif f is None:
            rep.ng(f"{name}", "宣言だけで定義が無い (リンクエラーになる)")
        elif d[0] != f[0] or d[1].replace(" ", "") != f[1].replace(" ", ""):
            rep.ng(f"{name}", f"宣言={d} / 定義={f}")
        else:
            rep.ok(name)


def check_duplicates(code, rep):
    """同じ @interface / @implementation を二重に書いていないか。"""
    print("\n[重複宣言]")
    for kind in ("@interface", "@implementation"):
        seen = {}
        for m in re.finditer(rf"^{kind}\s+(\w+)", code, re.M):
            seen.setdefault(m.group(1), []).append(line_of(code, m.start()))
        for name, positions in seen.items():
            # カテゴリ (@interface X (Y)) は複数あってよいので除く
            if len(positions) > 1 and "(" not in name:
                rep.ng(f"{kind} {name}", f"L{positions}")
        if not any(len(v) > 1 for k, v in seen.items() if "(" not in k):
            rep.ok(f"{kind} の重複なし")


def check_logos(code, rep):
    """Logos ディレクティブの対応。"""
    print("\n[Logos]")
    hooks = len(re.findall(r"^%hook\b", code, re.M))
    groups = len(re.findall(r"^%group\b", code, re.M))
    ends = len(re.findall(r"^%end\b", code, re.M))
    if hooks + groups == ends:
        rep.ok("%hook/%group ↔ %end", f"{hooks}+{groups}={ends}")
    else:
        rep.ng("%hook/%group ↔ %end", f"{hooks}+{groups} != {ends}")

    group_names = set(re.findall(r"^%group\s+(\w+)", code, re.M))
    init_names = set(re.findall(r"%init\((\w+)\)", code))
    if group_names == init_names:
        rep.ok("%group ↔ %init", f"{len(group_names)} 個")
    else:
        rep.ng("%group ↔ %init", f"差分 {group_names ^ init_names}")

    ctor = re.search(r"%ctor\s*\{(.*)\n\}", code, re.S)
    if ctor and "%init" in ctor.group(1):
        rep.ok("%ctor 内に %init")
    else:
        rep.ng("%ctor 内に %init", "hook が有効にならない")

    # %orig が %hook の外に無いか
    blocks, cur = [], None
    for i, line in enumerate(code.split("\n"), 1):
        if line.startswith("%hook"):
            cur = i
        elif line.startswith("%end") and cur:
            blocks.append((cur, i))
            cur = None
    stray = [i for i, l in enumerate(code.split("\n"), 1)
             if "%orig" in l and not any(a <= i <= b for a, b in blocks)]
    if stray:
        rep.ng("%hook 外の %orig", f"L{stray}")
    else:
        rep.ok("%orig の位置")


def check_werror_traps(code, rep):
    """Theos は -Werror。踏んだことのある警告を検査する。"""
    print("\n[-Werror で止まる書き方]")
    traps = [
        ("ARC の performSelector:", r"\[\s*\w+\s+performSelector"),
        ("UIApplication.keyWindow (非推奨)", r"\.keyWindow"),
        ("statusBarOrientation (非推奨)", r"statusBarOrientation"),
        ("UIAlertView (廃止)", r"\bUIAlertView\b"),
    ]
    for label, pattern in traps:
        hits = [i for i, l in enumerate(code.split("\n"), 1)
                if re.search(pattern, l)]
        if hits:
            rep.ng(label, f"L{hits}")
        else:
            rep.ok(label)


def check_balance(code, rep):
    """
    括弧の対応。

    文字列リテラルの中身は数えない。ログ文言の
    `-[YTIWatchEndpoint setVideoId:]` などで誤検出するため。
    """
    print("\n[括弧]")
    code = strip_strings(code)
    for open_ch, close_ch in (("{", "}"), ("[", "]"), ("(", ")")):
        a, b = code.count(open_ch), code.count(close_ch)
        if a == b:
            rep.ok(f"{open_ch}{close_ch}", f"{a}")
        else:
            rep.ng(f"{open_ch}{close_ch}", f"{a} != {b}")


def check_selectors(code, rep):
    """@selector で参照しているメソッドが実装されているか。"""
    print("\n[セレクタ]")
    referenced = set(re.findall(r"@selector\((\w+)\)", code))
    implemented = set(re.findall(r"^-\s*\(\w+[\s*]*\)(\w+)\s*[{:]", code, re.M))
    implemented |= set(re.findall(r"^\+\s*\(\w+[\s*]*\)(\w+)\s*[{:]", code, re.M))
    missing = referenced - implemented
    if missing:
        rep.ng("未実装のセレクタ", f"{sorted(missing)}")
    else:
        rep.ok("@selector の参照先", f"{len(referenced)} 個")


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "YTMProbe.x"
    try:
        src = open(path, encoding="utf-8").read()
    except OSError as e:
        print(f"読めません: {e}")
        return 1

    code = strip_comments(src)
    rep = Report()

    print(f"点検: {path}  ({len(src.splitlines())} 行)")
    check_declaration_order(code, rep)
    check_declaration_matches_definition(code, rep)
    check_duplicates(code, rep)
    check_logos(code, rep)
    check_werror_traps(code, rep)
    check_balance(code, rep)
    check_selectors(code, rep)

    print()
    if rep.failed:
        print(f"{RED}要修正の項目があります{RESET}")
        return 1
    print(f"{GREEN}静的な点検はすべて通過{RESET}")
    print("(実際の型エラーはビルドしないと分かりません)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
