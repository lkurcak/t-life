# t-life

Life-like cellular automata on a terminal, worked out by several threads,
written in T, the language at `~/repos/tooling/t-lang` (GitHub:
lkurcak/t-lang). Like tcalc, t-libs, t-nonograms, t-maze and t-metal, part
of its purpose is to find out what using T is like, here for threads
(t-lang steps 38–41: `Threads::spawn`, linear `JoinHandle`s, `Atomic`,
`Mutex`, `Send`/`Sync`), which no other program uses.

- `main.t` is the program's root: the command line, text output, and the
  bench. Modules: `rule` (`B3/S23`), `board` (the board, `next_row`, which
  every engine works each row out with, and `step`), `engine` (the
  `Engine` trait, and `Local`: the `one` and `spawn` engines on two
  boards), `spawn` (threads started each generation, over `split_at_mut`
  bands), `pool` (a thread for each band, kept; edge rows traded through
  `Mutex`es), `sync` (a barrier from atomics), `play` (the terminal).
- Nothing in it panics: `#![warn(implicit_panics)]` with
  `--deny-warnings`. Keep it so; a test may `#[allow(implicit_panics)]`.
- Tests get no `Os`, so no threads: the engines' agreeing is checked by
  `tests/run.sh`'s transcript (`tests/expected.txt`), interpreted and
  compiled, and `tests/terminal.py` (needs python3), which plays the
  compiled program on a pseudo-terminal with each engine. `BLESS=1`
  rewrites the expected transcript. The interpreted transcript takes about
  half a minute.
- For races, build with `T_LANG_CFLAGS=-fsanitize=thread t build -o x
  main.t` and run the engines: clean as of 0.88.0.
- CI pins a `t` release (`t-version` + `t-sha256` in .github/workflows/t.yml,
  which calls forge's shared t-ci.yml); forge bumps it after each t-lang
  release. t-libs is a git dependency pinned by `rev` in `t.toml`.
- `FRICTION.md` is the friction log: label entries gap / by design / unsure
  / works / bug, with the code that hit them. It's evidence for t-lang
  steps, planned in t-lang, not here. Don't change t-lang from here.
- `git` over ssh doesn't work in Claude's shell: push and fetch through
  `origin` with `-c url."https://github.com/".insteadOf=git@github.com:
  -c credential.helper='!gh auth git-credential'`.
