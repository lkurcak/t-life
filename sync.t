//! A barrier, from atomics: T's core has `Atomic` and a `Mutex`, but
//! nothing to wait for other threads with.

use core::num::wrapping_add;
use core::sync::Atomic;

/// Where `count` threads wait for each other: each `wait`s, and none goes
/// on until all have come. It can be used again and again.
///
/// It waits by spinning: by looking again and again until the last
/// thread has come, which keeps a core busy while it waits.
#[derive(Discard, Send, Sync)]
pub struct Barrier {
    count: { n: u32 | n >= 1 },
    /// How many have come in this round.
    here: Atomic<u32>,
    /// Which round it is: the last to come starts the next.
    round: Atomic<u32>,
}

impl Barrier {
    /// A barrier for `count` threads.
    pub fn new(count: { n: u32 | n >= 1 }) -> Barrier {
        Barrier { count, here: Atomic::new(0), round: Atomic::new(0) }
    }

    /// Waits until all `count` threads have come.
    pub fn wait(&self) {
        let round = self.round.load();
        if self.here.fetch_add(1) == self.count - 1 {
            // The last one: the others wait for the round to change, so
            // `here` is back to 0 before any of them can come again.
            self.here.store(0);
            self.round.store(wrapping_add(round, 1));
        } else {
            while self.round.load() == round {}
        }
    }
}
