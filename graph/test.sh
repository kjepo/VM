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

morc() {    # morc EXPECTED PROGRAM: the same, for a MORC program
    if g=$(printf '%s\n' "$2" | python3 lam2graph.py --morc 2>&1); then
        reduce "$@"
    else
        out=$g ref=$g
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
check -3                '/ 7 (-2)'
check 1                 '% 7 (-2)'
check 1                 '= 3 3'
check 0                 '= 3 4'
check 1                 '< -1 0'
check 0                 '< 2 1'
check -16384            '+ 16383 1'
check '<function>'      '+ 3'
check 7                 '(+ 3) 4'
check 10                '(\f.f 2 5) (*)'
check 3                 '(\f x.f (f (f x))) (+ 1) 0'
check 2                 'if 0 1 2'
check 10                'if (= 1 1) 10 20'
check 10                'if (= 1 1) then 10 else 20'
check 20                'if = 1 2 then 10 else 20'
check 105               '(\x. if = x 0 then 1 else + x 100) 5'
check 6                 'if 1 then if 0 then 5 else 6 else 7'
check 4                 '+ 1 (if 0 then 2 else 3)'
check 6                 '(\f. f (if 1 2 3) 4) (\a b. + a b)'
check 9                 'ack x y = if = x 0 then + y 1 else if = y 0 then ack (- x 1) 1 else ack (- x 1) (ack x (- y 1)); ack 2 3'
check 'error: syntax error at end of input'   'if 1 then 2'
check "error: syntax error at 't'"            '(\x. then) 1'
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
check 29                "$(sed 's/nth 99 primes/nth 9 primes/' primes.lam)"
# infix operators
check 7                 '1 + 2 * 3'
check 9                 '(1 + 2) * 3'
check 5                 '10 - 3 - 2'
check 2                 '12 / 3 / 2'
check 1                 '2 * 3 == 6'
check 1                 '2 * 3 = 6'
check 3                 'x = 4; x-1'
check -1                'f x = x; f (-1)'
check -3                '-5 + 2'
check 9                 '+ 1 2 * 3'
check 1                 '3 != 4'
check 1                 '3 >= 3'
check 0                 '3 <= 2'
check 1                 '4 > 3'
check 0                 '(>) 3 4'
check 0                 '> 3 4'
check 10                'sq x = x * x; sq 3 + 1'
check 42                '(\x. x + 1) 41'
check 5040              'fac n = if n == 0 then 1 else n * fac (n-1); fac 7'
check 3                 'ack x y = if y == 0 then ack (x-1) 1 else if x == 0 then y+1 else ack (x-1) (ack x (y-1)); ack 1 1'
check 'error: an operator needs a number'     'f x = x; f -1'
check "error: syntax error at '='"            '1 == 2 == 3'
check "error: syntax error at '!'"            'x = 1; x ! 2'
# definitions
check 5040              'fac n = if (= n 0) 1 (* n (fac (- n 1))); fac 7'
check 5040              'fac n = if (= n 0) 1 (* n (fac (- n 1))); main = fac 7'
check 5040              'main = fac 7; fac n = if (= n 0) 1 (* n (fac (- n 1)));'
check 1                 'even n = if (= n 0) 1 (odd (- n 1)); odd n = if (= n 0) 0 (even (- n 1)); even 10'
check 7                 'seven = 7; same = seven; same'
check 3                 'twice f x = f (f x); twice (+ 1) 1'
check 9                 'x = 4; (\x. + x 5) 4'
check 6                 'longer_name2 = 6; longer_name2'
check 4                 'k x y = x; k 4 (/ 1 0)'
check 1                 'ones = \c n. c 1 ones; ones (\h t. h) 0'
check 2                 'equal = = 1 1; + equal 1'
check 'error: a value defined as itself'      'x = x; x'
check 'error: unbound variable y'             'f x = y; 1'
check 'error: unbound variable nope'          'f = 1; nope'
check 'error: f is defined twice'             'f = 1; f = 2; f'
check 'error: no main'                        'f = 1;'
check "error: syntax error at '2'"            '1; 2'
check "error: syntax error at '='"            'rec = 1; f'
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
# MORC: precedence, operators, lists
morc 5040               "$(cat fac.morc)"
morc 29                 "$(sed 's/nth 99 primes/nth 9 primes/' primes.morc)"
morc 7                  'fn main = 1 + 2 * 3;'
morc 9                  'fn main = (1 + 2) * 3;'
morc 5                  'fn main = 10 - 3 - 2;'
morc 2                  'fn main = 12 / 3 / 2;'
morc 1                  'fn main = 2 * 3 = 6;'
morc 1                  'fn main = 2 * 3 == 6;'
morc -3                 'fn main = -5 + 2;'
morc -10                'fn main = - 5 * 2;'
morc -4                 'fn neg x = -x; fn main = neg 4;'
morc 10                 'fn sq x = x * x; fn main = sq 3 + 1;'
morc 10                 'fn main = if 1 < 2 then 10 else 20;'
morc 3                  'fn main = 1 + if false then 1 else 2;'
morc 6                  'fn main = if true then if false then 5 else 6 else 7;'
morc 5                  'fn main = (\x y -> x - y) 7 2;'
morc 12                 'fn twice f x = f (f x); fn main = twice (\x -> x * 2) 3;'
morc 7                  'fn main = (+) 3 4;'
morc 0                  'fn main = (>) 3 4;'
morc 1                  'fn main = 4 > 3;'
morc 1                  'fn main = 3 >= 3;'
morc 0                  'fn main = 3 <= 2;'
morc 0                  'fn main = 3 != 3;'
morc 1                  'fn main = 3 != 4;'
morc 3                  'fn len l = l (\h t -> 1 + len t) 0; fn main = len (1 : 2 : 3 : nil);'
morc 2                  'fn hd l = l (\h t -> h) 0; fn main = hd (1 + 1 : nil);'
morc 6                  'fn sum l = l (\h t -> h + sum t) 0; fn main = sum ((:) 1 ((:) 2 ((:) 3 nil)));'
morc 1                  'fn main = true'
morc 'error: no main'                         'fn f = 1;'
morc 'error: unbound variable x'              'fn main = x;'
morc 'error: f is defined twice'              'fn f = 1; fn f = 2; fn main = f;'
morc "error: syntax error at ';'"             'fn main = 1 +;'
morc "error: syntax error at 'if'"            'fn if = 1;'
morc "error: syntax error at 'main'"          'main = 1;'
morc "error: syntax error at '@'"             'fn main = 1 @ 2;'
morc "error: syntax error at '='"             'fn main = 1 = 2 = 3;'
morc "error: syntax error at ';'"             'fn main = if 1 then 2;'
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
graph 4                 '%1 K 4 @ =0 $0 3 @'
graph '<function>'      '%1 $0 =0 $0'
graph 'error: bad global'                     'K 1 @ %1 $0'
graph 'error: bad global'                     '%1 $1'
graph 'error: bad global'                     '%1 5 =0 5'
graph "error: syntax error at 'x'"            '%1x'
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
code 'Y (B* (S (C'"'"' IF (C = 0) 1)) (S *) (C B (C - 1))) 7' '(rec f.\n. if (= n 0) 1 (* n (f (- n 1)))) 7'
code 'f = S (C'"'"' IF (C = 0) 1) (S * (B f (C - 1)))
f 7'                    'f n = if (= n 0) 1 (* n (f (- n 1))); unused = 1; f 7'

# prototype.py run directly on a MORC file (morc.py must share its classes)
if [ "$(python3 prototype.py fac.morc | head -n 1)" = 5040 ]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL: python3 prototype.py fac.morc"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
