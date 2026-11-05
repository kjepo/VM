#!/bin/sh
# test.sh - check mxparse.mx and mex.py on small Mex programs.
#
#   sh test.sh
#
# check EXPECTED PROGRAM: a line of mxparse.mx's output must be EXPECTED. If it
# is an error (line:col: message), mex.py -c must report the same one;
# otherwise mex.py -c must accept the program.
# run EXPECTED PROGRAM: mex.py runs the program and must print EXPECTED.

cd "$(dirname "$0")" || exit 2
pass=0 fail=0
tmp=${TMPDIR:-/tmp}/mex-test.$$.mx
trap 'rm -f "$tmp"' EXIT

ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n%s\n' "$1" "$2"; }

check() {   # check EXPECTED PROGRAM
    printf '%s\n' "$2" > "$tmp"
    out=$(python3 mex.py mxparse.mx < "$tmp" 2>&1)
    ref=$(python3 mex.py -c "$tmp" 2>&1)
    if ! printf '%s\n' "$out" | grep -qxF -- "$1"; then
        bad "$2" "  expected: $1
  mxparse:  $(printf '%s\n' "$out" | tail -1)"
    elif printf '%s' "$1" | grep -q '^[0-9]*:[0-9]*: ' && [ "$ref" != "$1" ]; then
        bad "$2" "  expected: $1
  mex.py:   $ref"
    elif ! printf '%s' "$1" | grep -q '^[0-9]*:[0-9]*: ' && [ -n "$ref" ]; then
        bad "$2" "  mex.py rejects it: $ref"
    else
        ok
    fi
}

run() {     # run EXPECTED PROGRAM
    printf '%s\n' "$2" > "$tmp"
    out=$(python3 mex.py "$tmp" 2>&1)
    if [ "$out" = "$1" ]; then ok; else bad "$2" "  expected: $1
  got:      $out"; fi
}

# whole programs
out=$(python3 mex.py eval.mx)
[ "$out" = "42
x y " ] && ok || bad eval.mx "$out"
python3 mex.py mxparse.mx < eval.mx > /dev/null && ok || bad "mxparse.mx < eval.mx" ""
python3 mex.py mxparse.mx < mxparse.mx > /dev/null && ok || bad "mxparse.mx < mxparse.mx" ""

# code
check '    setl 0 x'              "fun main() { var x = 1 + 2 * 3; }"
check '    *'                     "fun main() { var x = 1 + 2 * 3; }"
check '    store'                 "fun main() { var d = {}; d.a = 1; }"
check '    sym "a"'               "fun main() { var d = {a: 1}; }"
check '    cons'                  "fun main() { var l = 1 : 2 : nil; }"
check '    int 7'                 "fun main() { var l = [5, 6, 7]; }"
check '    setg 15 g'             "var g; fun main() { g = 'A'; }"
check '    int 65'                "var g; fun main() { g = 'A'; }"
check '    int -1'                "fun main() { var x = 0x7FFF; }"
check '    int -1'                "fun main() { var x = 32767; }"
check '    int -16384'            "fun main() { var x = 16384; }"
check '    int 10'                "fun main() { var x = '\\n'; }"
check '    sym "a\"b\n"'          "fun main() { var s = \"a\\\"b\\n\"; }"
check '    int 255'               "fun main() { var x = '\\xff'; }"
check '    getg 15 x'             "var x = 1; fun main() { var x = x; }"
check '    getl 0 a'              "fun f(a, b) { return a; } fun main() {}"
check 'fun f params 2 locals 3'   "fun f(a, b) { var c; } fun main() {}"
check 'fun main params 0 locals 1' "fun main() { { var a; } { var b; } }"
check '    call 2'                "fun f(a, b) {} fun main() { f(1, 2); }"
check '    tcall 1'               "fun f(a) { return f(a); } fun main() {}"
check '    call 1'                "fun f(a) { return f(a) + 1; } fun main() {}"
check '    pop'                   "fun main() { getc(); }"
check '    func g'                "var t = g(); fun g() { return 1; } fun main() {}"
check '    or L1'                 "fun main() { var b = 1 || 0; }"
check '    and L1'                "fun main() { var b = 1 && 0; }"
check '    jmp L1'                "fun main() { while (true) { break; } }"
check '    index'                 "fun main() { var t = {}; var c = t[0]; }"
check '    not'                   "fun main() { var b = !1; }"
check '    neg'                   "fun main() { var n = -5; }"
check '    sym "true"'            "fun main() { var t = true; }"
check '    closure lambda1 0'     "fun main() { var f = fun (x) { return x; }; }"
check 'fun lambda1 params 1 locals 1 captures n' "fun add(n) { return fun (x) { return x + n; }; } fun main() {}"
check '    getv 0 n'              "fun add(n) { return fun (x) { return x + n; }; } fun main() {}"
check '    closure lambda1 1'     "fun add(n) { return fun (x) { return x + n; }; } fun main() {}"
check 'fun lambda1 params 0 locals 0 captures a' "fun f(a) { return fun () { return fun () { return a; }; }; } fun main() {}"
check '    getv 0 a'              "fun f(a) { return fun () { return fun () { return a; }; }; } fun main() {}"
check '    getg 0 hd'             "fun main() { var hd2 = fun (l) { return hd(l); }; }"

# errors
check '1:28: comparisons do not chain'          "fun main() { var b = 1 < 2 < 3; }"
check '1:18: cannot assign to this expression'  "fun main() { f() = 1; } fun f() {}"
check '1:18: cannot assign to this expression'  "fun main() { (x) = 1; } var x;"
check '1:16: cannot assign to this expression'  "fun main() { 1 = 2; }"
check '1:14: cannot assign to the built-in function hd' "fun main() { hd = 1; }"
check '1:14: x is not declared'                 "fun main() { x = 1; }"
check '1:25: x is already declared in this scope' "fun main() { var x; var x; }"
check '1:31: x is already declared in this scope' "fun main() { var x = t.y; var x; } var t;"
check '1:10: a is already declared in this scope' "fun f(a, a) {} fun main() {}"
check '1:5: keys is a built-in function'        "var keys; fun main() {}"
check '1:16: f is already declared'             "fun f() {} var f; fun main() {}"
check '1:14: break outside a loop'              "fun main() { break; }"
check '1:43: continue outside a loop'           "fun main() { while (1) { var f = fun () { continue; }; } }"
check "1:18: expected an expression, found ';'" "fun main() { x = ; }"
check "1:24: expected ';', found '}'"           "fun main() { var x = 1 }"
check "1:1: expected 'fun' or 'var', found name x" "x = 1;"
check "2:1: there is no function main"          "fun f() {}"
check "1:5: main must have no parameters"       "fun main(a) {}"
check "1:22: number too large"                  "fun main() { var x = 32768; }"
check "1:22: number too large"                  "fun main() { var x = 0x8000; }"
check '1:22: unterminated symbol'               "fun main() { var s = \"abc"
check '1:22: empty character'                   "fun main() { var c = ''; }"
check '1:22: a character literal holds one character' "fun main() { var c = 'ab'; }"
check '1:24: unknown escape'                    "fun main() { var c = '\\q'; }"
check "1:22: unexpected character '&'"          "fun main() { var c = & 1; }"
check "1:29: expected '{' or 'if' after else, found name x" "fun main() { if (1) {} else x; }"
check "1:23: expected a key, found '('"         "fun main() { var t = {(1): 2}; }"
check "1:24: bad number"                        "fun main() { var x = 12ab; }"
check "2:1: expected '}', found end of input"   "fun main() {"
check "1:42: x is captured, so it cannot be assigned" "fun main() { var x = 1; var f = fun () { x = 2; }; }"
check "1:55: x is captured, so it cannot be assigned" "fun main() { var x = 1; var f = fun () { return x; }; x = 2; }"
check "1:56: x is assigned, so it cannot be captured" "fun main() { var x = 1; x = 2; var f = fun () { return x; }; }"
check "1:42: n is assigned, so it cannot be captured" "fun f(n) { n = 1; return fun () { return n; }; } fun main() {}"

# running
run '7'        "fun main() { print(1 + 2 * 3); }"
run '-1'       "fun main() { print(0x7FFF); }"
run '-3 -1'    "fun main() { print(-7 / 2); putc(' '); print(-7 % 2); }"
run 'true'     "fun main() { print(nil || 5 && true); }"
run '0'        "fun main() { print(0 || 5); }"
run '5'        "fun main() { print(nil || 5); }"
run 'nil'      "fun main() { print(type(1 && nil)); }"
run '15'       "fun add(n) { return fun (x) { return x + n; }; } fun main() { print(add(5)(10)); }"
run '3'        "fun counter() { var n = 0 : nil; return fun () { sethd(n, hd(n) + 1); return hd(n); }; }
                fun main() { var c = counter(); c(); c(); print(c()); }"
run '10000'    "fun loop(n, acc) { if (n == 0) { return acc; } return loop(n - 1, acc + 1); }
                fun main() { print(loop(10000, 0)); }"
run 'b c a '    "fun main() { var t = {a: 1, b: 2}; t.a = nil; t.c = 3; t.a = 4;
                var k = keys(t); while (k != nil) { print(hd(k)); putc(' '); k = tl(k); } }"
run '2 1'      "fun main() { var t = {}; t[1] = 1; t[1 : nil] = 2; print(size(t)); putc(' '); print(t[1]); }"
run 'hello'    "fun main() { print(intern(name(\"hello\"))); }"
run 'pair sym table fun int nil' "fun main() { var l = [1 : 2, \"s\", {}, main, 3, nil];
                while (l != nil) { print(type(hd(l))); if (tl(l) != nil) { putc(' '); } l = tl(l); } }"
run 'mex: run-time error: + needs two integers, not sym and int' "fun main() { print(\"a\" + 1); }"
run 'mex: run-time error: hd needs a pair, not nil' "fun main() { hd(nil); }"
run 'oops'     "fun main() { error(\"oops\"); }"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
