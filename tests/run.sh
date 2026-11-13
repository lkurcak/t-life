#!/bin/sh
# Checks t-life: it type-checks with no warnings (so nothing in it can
# panic: main.t asks for `implicit_panics`), it's formatted, its tests
# pass, what it writes for the command lines below is tests/expected.txt,
# both interpreted and compiled, and it plays on a terminal
# (tests/terminal.py). Run from anywhere; `t` must be on PATH, and python3,
# for the terminal.
# BLESS=1 rewrites tests/expected.txt with what it writes now.
set -eu
cd "$(dirname "$0")/.."

t check --deny-warnings main.t
t fmt --check ./*.t
t test --deny-warnings main.t

# What it writes when its output isn't a terminal: boards from fixed
# seeds, by each engine with as many threads as fit and more, which must
# all be the same board; what the bench says, but how long each took; and
# what it says to command lines it can't use.
transcript() {
    for engine in one spawn pool; do
        for threads in 1 3 7 16; do
            args="--seed 3 --size 20x10 --gens 12 --engine $engine --threads $threads"
            echo "\$ life $args"
            # shellcheck disable=SC2086 # each word of $args is an argument
            "$@" $args < /dev/null 2>&1
        done
    done
    for args in \
        "--rule B36/S23 --seed 9 --size 12x7 --gens 30" \
        "--rule b2/s --seed 1 --size 9x4 --gens 1 --engine spawn" \
        "--rule B3678/S34678 --seed 2 --size 16x6 --gens 40 --threads 2" \
        "--seed 5 --size 1x1 --gens 3" \
        "--seed 5 --size 3x1 --gens 2 --threads 2" \
        "--size 0x4" "--threads 0" "--threads 1025" "--rule B9/S" "--engine fast" \
        "--size 4" "--gens" "--seed -1"; do
        echo "\$ life $args"
        # shellcheck disable=SC2086 # each word of $args is an argument
        "$@" $args < /dev/null 2>&1
    done
    args="--bench --seed 1 --size 48x40 --gens 25 --threads 5"
    echo "\$ life $args"
    # shellcheck disable=SC2086 # each word of $args is an argument
    "$@" $args < /dev/null 2>&1 | sed 's/ *[0-9]* ms / ... ms /'
}

# `t main.t` compiles it; `--interp` runs it in the interpreter, which
# checks as it goes what the checker proved, and runs threads one at a
# time, taking turns.
if [ "${BLESS:-}" = 1 ]; then
    transcript t --interp main.t > tests/expected.txt
    echo "wrote tests/expected.txt"
    exit 0
fi

transcript t --interp main.t > tests/actual.txt
if ! diff -u tests/expected.txt tests/actual.txt; then
    echo "FAIL: output differs from tests/expected.txt"
    exit 1
fi

# Compiled through C, as `t main.t` runs it, it must do just what the
# interpreter does; and play on a terminal.
t build -o tests/life main.t
transcript tests/life > tests/actual.txt
if ! diff -u tests/expected.txt tests/actual.txt; then
    echo "FAIL: the compiled program's output differs from tests/expected.txt"
    exit 1
fi
python3 -I tests/terminal.py tests/life
rm tests/actual.txt tests/life
echo "ok"
