#!/bin/sh
# test.sh - run the CAM on small programs and check the printed results.
#
#   sh test.sh [VM]          VM defaults to ../vm16, run in checking mode

VM=${1:-../vm16}
cd "$(dirname "$0")" || exit 2
python3 ../vm16asm.py cam.asm >/dev/null || exit 2
Z='(\f.(\x.f (\y.x x y)) (\x.f (\y.x x y)))'
pass=0 fail=0

check() {   # check EXPECTED PROGRAM: the first line of output must be EXPECTED
    got=$(printf '%s\n' "$2" | "$VM" -c cam.v16 | head -n 1)
    if [ "$got" = "$1" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $2"
        echo "  expected: $1"
        echo "  got:      $got"
    fi
}

check 42                '42'
check -5                '-5'
check 4                 '(\a b.a) 4 3'
check 3                 '(\a b.b) 4 3'
check '<closure>'       '\x.x'
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
check '<closure>'       '+ 3'
check 7                 '(+ 3) 4'
check 10                '(\f.f 2 5) *'
check 3                 '(\f x.f (f (f x))) (+ 1) 0'
check 2                 'if 0 1 2'
check 10                'if (= 1 1) 10 20'
check -1                'if (< 2 1) 10 (% -7 2)'
check 7                 '(\i f. i f) (\x.x) 7'
check 8                 '(\r e.r e) (\x.x) 8'
check 5040              "$(cat fac.lam)"
check 5040              "(\Z.Z (\f n.if (= n 0) 1 (* n (f (- n 1)))) 7) $Z"
check 120               "$(cat ../fac.lam)"
check 2584              '(rec f.\n.if (< n 2) n (+ (f (- n 1)) (f (- n 2)))) 18'
check 3000              '(rec f.\n a.if (= n 0) a (f (- n 1) (+ a 1))) 3000 0'
check 1000              '(rec f.\n.if (= n 0) 0 (+ 1 (f (- n 1)))) 1000'
check 'error: out of stack'                   '(rec f.\n.if (= n 0) 0 (+ 1 (f (- n 1)))) 3000'
check 'error: out of stack'                   '(\x.x x) (\x.x x)'
check 'error: division by zero'               '/ 1 0'
check 'error: unbound variable x'             'x'
check 'error: only a function can be applied' '3 4'
check 'error: an operator needs a number'     '+ (\x.x) 1'
check 'error: if needs a number'              'if (\x.x) 1 2'
check 'error: rec needs a lambda: rec f.\x.M' 'rec f.3'
check 'error: syntax error at end of input'   'if 1 2'
check "error: syntax error at ')'"            '(\x.x))'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
