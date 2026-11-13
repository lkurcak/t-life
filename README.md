# t-life

Life-like cellular automata on a terminal, worked out by several threads.
A program written in [T](https://github.com/lkurcak/t-lang), partly to find
out what writing a multithreaded program in T is like: it's the first to
start threads. What got in the way is in [FRICTION.md](FRICTION.md).

```text
$ life --rule B36/S23 --seed 9 --size 12x7 --gens 30
B36/S23, 12 by 7, seed 9, after 30 generations:
#........#..
#....###...#
#........##.
##........##
.........#..
.........#..
##..........
population 18, hash 910b05fb6c3302dc
```

The board is a torus: the row above the top one is the bottom one, and the
cell left of the first in a row is the last. A rule says when a dead cell
is born and when a live one survives, by how many of its eight neighbours
are alive: `B3/S23` is Conway's Game of Life, `B36/S23` HighLife, `B2/S`
Seeds, `B3678/S34678` Day & Night.

On a terminal, the board fills it, two cells to a character, and runs:

- space pauses, and goes on;
- `n`, while paused, works out one generation;
- `+` and `-` work out twice or half as many generations a frame;
- `r` starts again from a new random board, and `q`, Escape or Ctrl-C
  stops.

`life [--rule B3/S23] [--size WxH] [--seed N] [--threads N]
[--engine pool|spawn|one] [--gens N] [--bench]`: a random board from that
seed (the same each time; with none, a new one each run), as big as that
(on a terminal, as big as it); when its output isn't a terminal, or with
`--gens`, it writes the board after that many generations, as text.

## Engines

Each generation is worked out one of three ways, which give the same
boards:

- `pool` (the default): a thread for each band of rows, kept for the whole
  run. Each has its band to itself, and each generation trades its top and
  bottom rows with its neighbours', then works out its band; the threads
  wait for each other at a barrier made of two atomics.
- `spawn`: threads started for each generation, each writing a band of the
  next one through a `&mut` of its own, all reading this one.
- `one`: no threads.

`--threads N` says how many (4 by default; no more than the board has
rows). `--bench` times each at a board 512 by 512 for 100 generations (or
as `--size` and `--gens` say), and checks that they agree:

```text
$ life --bench --size 2048x2048 --gens 300 --threads 16 --seed 1
B3/S23, 2048 by 2048, seed 1, 300 generations, up to 16 threads
one       2505 ms   hash ...
spawn      380 ms   hash ...
pool       404 ms   hash ...
They agree.
```

## Building

```sh
t main.t                      # compile through C, and run
t main.t --rule B36/S23       # HighLife
t build -o life main.t
```

`t` 0.88.0 or later; it fetches the t-libs packages `t.toml` names.
`tests/run.sh` runs what CI runs: `t check --deny-warnings`, `t fmt
--check`, `t test`, the text output for a few command lines against
`tests/expected.txt` (interpreted and compiled, each engine at several
thread counts, which must all give the same board), and
`tests/terminal.py`, which plays the compiled program on a pseudo-terminal
with each engine and checks the terminal's put back as it was.
`BLESS=1 tests/run.sh` rewrites the expected output.
