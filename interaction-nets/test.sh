#!/bin/sh
# Checks for inet.py: results and interaction counts used in the tutorial.
cd "$(dirname "$0")"
fail=0
check() {   # check DESCRIPTION EXPECTED COMMAND...
    desc=$1 want=$2; shift 2
    got=$("$@" 2>&1 | grep -v '^peak' | tr '\n' '|')
    if [ "$got" = "$want" ]; then echo "ok    $desc"
    else echo "FAIL  $desc"; echo "  want: $want"; echo "  got:  $got"; fail=1; fi
}
I="python3 inet.py"
check "2+2" "r ~ S(S(S(S(Z))))|interactions: 3 (Add-S 2, Add-Z 1)|" $I add.inet
check "max 1 3" "r ~ S(S(S(Z)))|interactions: 3 (Max-S 1, Max-Z 1, Max1-S 1)|" $I max.inet
check "2*3" "r ~ S(S(S(S(S(S(Z))))))|interactions: 20 (Add-S 3, Add-Z 2, Dup-S 6, Dup-Z 2, Era-S 3, Era-Z 1, Mul-S 2, Mul-Z 1)|" $I mul.inet
for s in 1 2 3 4 5; do
check "2*3, random order $s" "interactions: 20 (Add-S 3, Add-Z 2, Dup-S 6, Dup-Z 2, Era-S 3, Era-Z 1, Mul-S 2, Mul-Z 1)|" $I -q -r $s mul.inet
done
check "0*inf diverges" "stopped after 1000 interactions|interactions: 1000 (Era-S 499, Inf-Go 500, Mul-Z 1)|" $I -q -r 1 -n 1000 inf.inet
check "fib 3" "r ~ S(S(Z))|interactions: 16 (Add-S 2, Add-Z 2, Dup-S 1, Dup-Z 2, Fib-S 4, Fib-Z 1, Fib1-S 2, Fib1-Z 2)|" $I fib.inet
check "combinators" "out ~ Con(w1, w1)|interactions: 4 (Con-Con 2, Con-Dup 1, Dup-Dup 1)|" $I selfapp.inet

lam() {     # lam FILE FLAGS EXPECTED-RESULT EXPECTED-COUNT CHECK
    got=$($I -c $2 lam/$1.lam 2>&1)
    r=$(echo "$got" | head -1); n=$(echo "$got" | grep -o 'interactions: [0-9]*' | cut -d' ' -f2)
    c=$(echo "$got" | grep -o 'check: [A-Za-z]*' | cut -d' ' -f2)
    if [ "$r|$n|$c" = "$3|$4|$5" ]; then echo "ok    $1 $2"
    else echo "FAIL  $1 $2: want $3|$4|$5, got $r|$n|$c"; fail=1; fi
}
lam selfapp ""  '\x. x' 4 ok
lam succ    ""  '\x y. x (x (x y))' 3 ok
lam twotwo  ""  '\x y. x (x (x (x y)))' 14 ok
lam exp222  ""  '\x. x' 49 ok
lam exp322  ""  '\x. x' 84 ok
lam times   ""  '\x y. y' 57 ok
lam times   -l  '\x y. y' 17 ok
lam pred3   ""  '\x y. x (x y)' 186 ok
lam pred3   -l  '\x y. x (x y)' 105 ok
lam pred    ""  '\x y. y' 372 ok
lam pred    -l  '\x y. y' 146 ok
lam shared  ""  '\x y. ...' 16 WRONG
lam omega   ""  '...' 11 ''
for s in 1 2 3; do
check "pred three, random order $s" "interactions: 186 (Dup-App 24, Dup-Dup 37, Dup-Lam 31, Era-App 5, Era-Dup 15, Era-Era 19, Era-Lam 14, Lam-App 41)|" $I -q -r $s lam/pred3.lam
done
exit $fail
