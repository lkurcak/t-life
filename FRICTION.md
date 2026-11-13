# Friction log

What got in the way of writing a multithreaded program in T, with the code
that hit it. Each entry is labelled:

- **gap**: T should have it;
- **by design**: T leaves it out on purpose, and the entry says what that
  costs here;
- **unsure**: not clear which;
- **works**: something that went better than expected;
- **bug**: the checker is wrong.

The log is evidence for t-lang's plans, not a design for them.

Written against `t` 0.88.0. t-life is the first program to use threads
(t-lang steps 38–41: `Threads::spawn`, linear `JoinHandle`s, `Atomic`,
`Mutex`, `Send`/`Sync`), which until now only t-lang's own tests did.

## Threads: what worked — works

Most of it went through the checker the first time:

- `pool::run` starts a thread for each band of rows, borrowing `&Shared`
  and the board, and moving each its `Band`; the handles go in a
  `List<JoinHandle<'_, ()>>`, and `handles.free_with(|h| h.join())` joins
  them all. A list of linear handles is linear itself, and `free_with` is
  the one way to use it up: easy once found (`spawn.t`, `pool.t`).
- `spawn::step` hands each thread a disjoint `&mut [bool]` of the next
  generation, cut off the front with `split_at_mut` in a loop
  (`rest = tail`), while all of them read the whole board: scoped threads
  borrowing for exactly as long as the handles live.
- A barrier from two atomics (`sync.t`), and the halo exchange of
  `pool.t`: each thread owns its band, and the only shared state is each
  band's edge rows, in `Mutex`es, and the counters. `#[derive(Send,
  Sync)]` on `Shared`, `Edges` and `Band` said what was needed.
- The three engines (`one`, `spawn`, `pool`) agree with each other at
  every thread count (`tests/expected.txt`: 1, 3, 7 and 16 threads on a
  board 10 rows high), and with an independent Python implementation on
  four rules. ThreadSanitizer and ASan/UBSan builds (`T_LANG_CFLAGS`) run
  clean.
- The interpreter runs all three, threads taking turns, and writes just
  what the compiled program does.

## `core::mem::swap` of two refined places forgets their refinements — gap

The obvious double buffer doesn't check:

```rust
let mut now: { g: Board | g.width() == w && g.height() == h } = start.copy();
let mut next: { g: Board | g.width() == w && g.height() == h } = start.copy();
...
board::step(&now, rule, &mut next);
core::mem::swap(&mut now, &mut next);
// error: can't prove `g.width() == w && g.height() == h` for `now` after
// the call to `swap` (and for `next`)
```

Nor does it for two fields, `self.now` and `self.next` of `Band`, whose
refinements name the band's `rows` and `width`. Smaller:

```rust
let mut a: { v: u32 | v > 0 } = 1;
let mut b: { v: u32 | v > 0 } = 2;
core::mem::swap(&mut a, &mut b); // can't prove `v > 0` for `a` after the call
```

It's every generic `&mut T` parameter, not `swap` alone:
`core::mem::replace(&mut a, b)` and a `fn set<T: Discard>(a: &mut T, v: T)`
of our own fail the same way. A refinement inside a type argument
(`List<{ v: u8 | v < 9 }>`) is carried since step 60; the lent place's own,
at the top, isn't. By parametricity, `swap` at `T := { v: u32 | v > 0 }`
is fine: everything it can write through `a` is a `T` it was given. docs/60
says as much (the instantiation behind a `&mut` has exactly what's
declared of the place lent).

Workarounds, each in the code: three moves (`let done = next; next = now;
now = done;`, `main.t`'s `by` and `board.t`'s tests); taking the band by
value and building it again with the two swapped (`Band::step`); and two
buffers with a flag saying which is now, so nothing's swapped
(`engine.t`'s `Local`). Repro: `swap2.t` below.

## A closure's refined result doesn't come back through a generic `R` — gap

```rust
fn call<R, F: FnOnce() -> R>(f: F) -> R { f() }
fn five() -> { v: u32 | v > 0 } { 5 }

let a: { v: u32 | v > 0 } = call(|| five()); // can't prove `v > 0` for `a`
```

Same with `Option<{ v: u32 | v > 0 }>`. Threaded code is full of these:
`Mutex::lock(|b| ..)`, `spawn(|| ..).join()`, and a scoped API like this
program's `pool::run(.., |p| ..)` all give back what a closure did, and
lose what's known of it. `main.t`'s `by` checks the board's size again
after `pool::run`. docs/55 lists it ("nothing goes through a closure"); a
closure called once, whose result is the call's, seems the easy case.

## Waiting means spinning, with no hint — gap

There's no way to wait for another thread but to look again and again:
no `Condvar`, no parking, no barrier, and `core::sync::spin`, the hint
`Mutex::lock` gives the machine while it waits, is private. So
`sync::Barrier::wait` is `while self.round.load() == round {}`, a loop
that keeps a core busy. It costs:

- the pool's owner spins at the barrier while its threads work: one more
  busy core;
- a thread that finishes its band first spins beside one still working,
  on the same core's other hardware thread, slowing it;
- with more threads than cores, a spinning thread can hold a core the one
  it waits for needs.

On a 2048 × 2048 board, 50 generations (16 cores, 32 hardware threads):
the pool takes 191 ms with 16 threads, 242 ms with 32. `spin` made public
(as `core::sync::spin_loop` or `std::thread::yield_now`) would be the
smallest step; a sleeping `Barrier` or `Condvar` in std after.

## No count of the machine's cores — gap

There's nothing like Rust's `available_parallelism`, so `--threads`
defaults to 4 (`main.t`'s `THREADS`). It'd be something `Threads` knows:
`os.threads.available()`.

## Tests get no `Os`, so no threads — by design

`t test` gives a test nothing (docs/31: a test takes what `main` can, but
the `Os`), so nothing that starts a thread can be a `#[test]`: the engines'
agreeing is tested by running the program, in `tests/run.sh`, and its
transcript. The unit tests are of what one thread does. A test that's
given `Threads` alone, not the rest of the `Os`, would still be
repeatable, if what it tests is: these are.

## Refinements can't be in a trait's methods — by design (for now)

`Engine::board` would say it gives a `Board`, a grid at least a cell each
way, but a trait's method can't be refined yet ("an impl's would have to
ask no more than the trait's, and promise no less"). So it gives a
`Grid<bool>`, and `play` and `by` check its size again.

## What's in a `Mutex` is out of sight — by design

The checker never looks inside a `Mutex` (lemma Z3 of docs/41), so the
edge rows, `Mutex<List<bool>>`, can't say they're a row long, nor the
shared board how big it is. `pool.t`'s `copy` copies as much as both have,
and the board read back from the pool is checked again. A refinement on
what a `Mutex` holds, proved at `new` and in each `lock`'s closure, would
do it; this is the price of opacity, and small here.

## A closure takes all of a variable, not the field it names — gap

```rust
let mut input = os.stdin;
...
pool::run(&os.threads, .., |p| play::play(p, .., os.clock, ..))
// error: use of partly moved value `os`: `os.stdin` was moved out of it
```

The closure names only `os.clock`, a `Copy` field, but takes `os`, which
`os.stdin` has left. Rust (2021) takes only the fields a closure names.
Fixed by `let clock = os.clock;` before it (`main.t`).

## No widths in format strings — gap

`f"{name:<6}{ms:>8} ms"` isn't allowed: a hole can say `:?`, `:x` or
`:08x` and nothing else yet. The bench's table pads by hand (`main.t`'s
`pad`).

## No bulk copies of slices — gap

There's no `copy_from_slice`, nor `List::extend_from_slice`, nor a quick
copy of a `List` of `Copy` values: `pool.t` has its own `copy`, a loop, and
puts each edge row in its `Mutex` a `push` at a time. t-libs' `Grid::copy`
is one `List::replace` a cell, about 7 ns each: when the `one` and `spawn`
engines copied the board each generation, the copy took three times as
long as working out the generation (267 ms against 64 ms for 100
generations of 512 × 512). They have two boards now.

## `|_, _|` is a parameter declared twice — bug

```rust
Grid::from_fn(width, height, |_, _| rng.chance(percent))
// error: parameter `_` is declared twice
```

`_` binds nothing, so there's nothing to declare twice; `|_x, _y|` works
(`board.t`'s `soup`). A function's parameters too: `fn k(_: u8, _: u8)`
is refused the same way (t-lang `src/check.rs`, where a function's
parameters are checked, compares names without skipping `_`).

## Small things — unsure

- Counting in a `for` (`n = n + 1` for each live cell) can't be proved not
  to overflow: `population` is a `while` with `invariant n <= i`. Known
  (t-lang's F5 counting).
- `rows.first()?` doesn't tell the checker that `rows.len() >= 1`
  (`board.t`'s `drawn` checks again).
- `let Band { rows, mut next } = band` is refused, with a good message:
  `next: mut next`. Rust has the shorthand.
- `with` is a keyword, so the scoped API is `pool::run(.., |p| ..)`, not
  `pool::with`.
- t-libs' `Grid` had no mutable rows (`row_mut`, `cells_mut`), nor a way
  to make one from a `List` (`from_cells`): added there for this.

## Repros

`swap2.t`, the swaps:

```rust
use alloc::list::List;

fn ints() {
    let mut a: { v: u32 | v > 0 } = 1;
    let mut b: { v: u32 | v > 0 } = 2;
    core::mem::swap(&mut a, &mut b); // error: can't prove `v > 0` for `a`
    let _ = a + b;
}

fn lists_var(n: usize) with alloc {
    let mut a: { l: List<u8> | l.len() == n } = List::filled(n, 0);
    let mut b: { l: List<u8> | l.len() == n } = List::filled(n, 1);
    core::mem::swap(&mut a, &mut b); // error: can't prove `l.len() == n`
    let _ = a;
}
```

`closure_result.t`:

```rust
fn call<R, F: FnOnce() -> R>(f: F) -> R { f() }

fn five() -> { v: u32 | v > 0 } { 5 }

fn main() {
    let a: { v: u32 | v > 0 } = call(|| five()); // error: can't prove `v > 0`
    let _ = a;
}
```

## Speed

`life --bench --size 2048x2048 --gens 300 --seed 1` on a Ryzen 9 7950X
(16 cores, 32 hardware threads), `t build` (C at `-O2`), milliseconds:

| threads | one | spawn | pool |
|---:|---:|---:|---:|
| 1 | 2613 | 2672 | 2638 |
| 4 | 2548 | 826 | 1027 |
| 8 | 2611 | 531 | 529 |
| 16 | 2505 | 380 | 404 |

About 2 ns a cell for one thread, and 6.5 times quicker with 16. Starting
16 threads a generation (`spawn`) costs about what the pool's barriers
do, at this size; on 512 × 512 the pool is quicker (18 ms against 28 ms
for 100 generations, 8 threads).
