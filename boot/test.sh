#!/bin/sh
# test.sh - check btparse.py on small Boot programs.
#
#   sh test.sh
#
# Each check gives a program and a line that must appear in the output (or,
# for an error, the message without the file name).

cd "$(dirname "$0")" || exit 2
pass=0 fail=0
tmp=${TMPDIR:-/tmp}/boot-test.$$.bt
trap 'rm -f "$tmp"' EXIT

check() {   # check EXPECTED PROGRAM
    printf '%s\n' "$2" > "$tmp"
    out=$(python3 btparse.py "$tmp" 2>&1 | sed "s|^$tmp:||")
    if printf '%s\n' "$out" | grep -qxF -- "$1"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL: %s\n  expected: %s\n  got:\n%s\n' "$2" "$1" "$out"
    fi
}

M='fun main() {}'

# programs that parse
python3 btparse.py -q wc.bt && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: wc.bt"; }
check '    setl 0 x'           "fun main() { var x = 1 + 2 * 3; }"
check '    *'                  "fun main() { var x = 1 + 2 * 3; }"
check '    store'              "fun main() { var d = {}; d.a = 1; }"
check '    str "a"'            "fun main() { var d = {a: 1}; }"
check '    int 2'              "fun main() { var d = [5, 6, 7]; }"
check '    setg 10 g'          "var g; fun main() { g = 'A'; }"
check '    int 65'             "var g; fun main() { g = 'A'; }"
check '    int -1'             "fun main() { var x = 0x7FFF; }"
check '    int 10'             "fun main() { var x = '\\n'; }"
check '    str "a\"b\n"'       "fun main() { var s = \"a\\\"b\\n\"; }"
check '    int 255'            "fun main() { var x = '\\xff'; }"
check '    setl 0 x'           "var x = 1; fun main() { var x = x; }"
check '    getg 10 x'          "var x = 1; fun main() { var x = x; }"
check '    getl 0 a'           "fun f(a, b) { return a; } $M"
check 'fun f params 2 locals 3' "fun f(a, b) { var c; } $M"
check 'fun main params 0 locals 1' "fun main() { { var a; } { var b; } }"
check '    call 2'             "fun f(a, b) {} fun main() { f(1, 2); }"
check '    pop'                "fun main() { getc(); }"
check '    func g'             "var t = g(); fun g() { return 1; } $M"
check '    next 0 L2'          "fun main() { for (k in {}) { break; } }"
check '    jt L1'              "fun main() { var b = 1 || 0; }"
check '    jf L1'              "fun main() { if (1) {} else if (2) {} else {} }"
check '    index'              "fun main() { var s = \"ab\"; var c = s[0]; }"
check '    not'                "fun main() { var b = !1; }"
check '    neg'                "fun main() { var n = -5; }"
check '    nil'                "fun main() { return; }"
check '    int 1'              "fun main() { var t = true; }"

# errors
check '1:28: comparisons do not chain'          "fun main() { var b = 1 < 2 < 3; }"
check '1:18: cannot assign to this expression'  "fun main() { f() = 1; } fun f() {}"
check '1:18: cannot assign to this expression'  "fun main() { (x) = 1; } var x;"
check '1:16: cannot assign to this expression'  "fun main() { 1 = 2; }"
check '1:14: cannot assign to the built-in function len' "fun main() { len = 1; }"
check '1:14: x is not declared'                 "fun main() { x = 1; }"
check '1:25: x is already declared in this scope' "fun main() { var x; var x; }"
check '1:10: a is already declared in this scope' "fun f(a, a) {} $M"
check '1:5: len is a built-in function'         "var len; $M"
check '1:16: f is already declared'             "fun f() {} var f; $M"
check '1:14: break outside a loop'              "fun main() { break; }"
check '1:18: expected an expression, found '"';'" "fun main() { x = ; }"
check "1:24: expected ';', found '}'"           "fun main() { var x = 1 }"
check "1:1: expected 'fun' or 'var', found name x" "x = 1;"
check "2:1: there is no function main"          "fun f() {}"
check "1:5: main must have no parameters"      "fun main(a) {}"
check "1:22: number too large"                  "fun main() { var x = 32768; }"
check '1:22: unterminated string'               "fun main() { var s = \"abc"
check '1:22: empty character'                   "fun main() { var c = ''; }"
check '1:22: a character literal holds one character' "fun main() { var c = 'ab'; }"
check '1:24: unknown escape'                    "fun main() { var c = '\\q'; }"
check '1:22: unexpected character "&"'          "fun main() { var c = & 1; }"
check "1:29: expected '{' or 'if' after else, found name x" "fun main() { if (1) {} else x; }"
check "1:23: expected a key, found '('"         "fun main() { var d = {(1): 2}; }"
check "1:24: bad number"                        "fun main() { var x = 12ab; }"
check "2:1: expected '}', found end of input"  "fun main() {"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
