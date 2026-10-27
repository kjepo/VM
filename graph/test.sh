#!/bin/sh
# test.sh - run the graph reducer on small programs and check the results.
#
#   sh test.sh [VM]          VM defaults to ../vm16, run in checking mode
#
# Every program is compiled with lam2graph.py, and the graph is reduced both by
# graph.v16 and by prototype.py, which must print the same result and the same
# number of reductions. Its stack is not the same size, so the stack overflow
# test gives it a limit with --depth.

VM=${1:-../vm16}
cd "$(dirname "$0")" || exit 2
python3 ../vm16asm.py graph.asm >/dev/null || exit 2
pass=0 fail=0

check() {   # check EXPECTED PROGRAM: the first line of output must be EXPECTED
    if g=$(printf '%s\n' "$2" | python3 lam2graph.py 2>&1); then
        reduce "$@"
    else
        out=$g ref=$g           # a compile error
    fi
    compare "$@"
}

graph() {   # graph EXPECTED GRAPH: the same, for a graph written by hand
    g=$2
    reduce "$@"
    compare "$@"
}

reduce() {  # out, ref = the outputs of graph.v16 and prototype.py for $g
    out=$(printf '%s\n' "$g" | "$VM" -c graph.v16)
    ref=$(printf '%s\n' "$g" | python3 prototype.py --graph ${3:-})
}

compare() {
    got=$(printf '%s\n' "$out" | head -n 1)
    steps=$(printf '%s\n' "$out" | sed -n 's/^\[\([0-9]*\) reductions.*/\1/p')
    rsteps=$(printf '%s\n' "$ref" | sed -n 's/^\[\([0-9]*\) reductions.*/\1/p')
    if [ "$got" = "$1" ] && [ "$(printf '%s\n' "$ref" | head -n 1)" = "$1" ] \
            && [ "$steps" = "$rsteps" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $2"
        echo "  expected: $1"
        echo "  got:      $got [$steps reductions]"
        echo "  python:   $(printf '%s\n' "$ref" | head -n 1) [$rsteps reductions]"
    fi
}

code() {    # code EXPECTED PROGRAM: the compiled term must be EXPECTED
    got=$(printf '%s\n' "$2" | python3 lam2graph.py -t 2>&1)
    if [ "$got" = "$1" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: -t $2"
        echo "  expected: $1"
        echo "  got:      $got"
    fi
}

check 42                '42'
check -5                '-5'
check 4                 '(\a b.a) 4 3'
check 3                 '(\a b.b) 4 3'
check '<function>'      '\x.x'
check 7                 '+ 3 4'
check -7                '- 3 10'
check -42               '* -7 6'
check 3                 '/ 7 2'
check -3                '/ -7 2'
check -1                '% -7 2'
check -3                '/ 7 -2'
check 1                 '% 7 -2'
check 1                 '= 3 3'
check 0                 '= 3 4'
check 1                 '< -1 0'
check 0                 '< 2 1'
check -16384            '+ 16383 1'
check '<function>'      '+ 3'
check 7                 '(+ 3) 4'
check 10                '(\f.f 2 5) *'
check 3                 '(\f x.f (f (f x))) (+ 1) 0'
check 2                 'if 0 1 2'
check 10                'if (= 1 1) 10 20'
check -1                'if (< 2 1) 10 (% -7 2)'
check 7                 '(\i f. i f) (\x.x) 7'
check 8                 '(\r e.r e) (\x.x) 8'
check 5                 '(\K.K) 5'
check 1                 '(\S B. B S) 1 (\x.x)'
check 5040              "$(cat fac.lam)"
check 2584              '(rec f.\n.if (< n 2) n (+ (f (- n 1)) (f (- n 2)))) 18'
check 120               "$(cat church.lam)"
check 120               "$(cat ../fac.lam)"
check 5040              "$(cat ../fac-int.lam)"
check 29                "$(sed 's/T 99/T 9/' primes.lam)"
# laziness: arguments that are never used are never reduced
check 5                 '(\x y.y) (/ 1 0) 5'
check 5                 '(\x y.y) ((\x.x x) (\x.x x)) 5'
check 1                 '(rec l.\c n.c 1 l) (\h t.h) 0'
check 3000              '(rec f.\n a.if (= n 0) a (if (< a 0) 0 (f (- n 1) (+ a 1)))) 3000 0'
check 'error: out of stack'                   '(rec f.\n a.if (= n 0) a (f (- n 1) (+ a 1))) 3000 0' --depth=500
check 'error: a value defined as itself'      'rec x.x'
check 'error: division by zero'               '/ 1 0'
check 'error: unbound variable x'             'x'
check 'error: unbound variable y'             '\x.y'
check 'error: only a function can be applied' '3 4'
check 'error: an operator needs a number'     '+ (\x.x) 1'
check 'error: if needs a number'              'if (\x.x) 1 2'
check 'error: syntax error at end of input'   'if 1 2'
check "error: syntax error at ')'"            '(\x.x))'
# the graph format
graph 4                 'K 4 @ 3 @'
graph '<function>'      'K 4 3 @ @'
graph 13                '- 3 @ -10 @   # comment'
graph 120               "$(python3 lam2graph.py ../fac.lam -o -)"
graph 'error: syntax error at end of input'   '1 2'
graph 'error: syntax error at end of input'   ''
graph "error: syntax error at '@'"            'I @'
graph "error: syntax error at 'x'"            '12x'
graph 'error: unknown combinator'             'Q'
graph "error: syntax error at 'X'"            'IFX 1 @ 2 @ 3 @'
# bracket abstraction and Turner's rules
code 'I'                '\x.x'
code 'K'                '\x y.x'
code 'K I'              '\x y.y'
code 'C I'              '\x f.f x'
code 'S I I'            '\x.x x'
code '+'                '\x.+ x'
code 'C - 1'            '\n.- n 1'
code 'B (+ 1) (* 2)'    '\x.+ 1 (* 2 x)'
code 'Y (B* (S (C'"'"' IF (C = 0) 1)) (S *) (C B (C - 1))) 7' "$(cat fac.lam)"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
