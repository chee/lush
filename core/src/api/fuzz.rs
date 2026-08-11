use automerge::Automerge;

use super::*;
use crate::repo::fuzz::{Rng, Swarm};

const SEEDS: u64 = 24;
const STEPS: usize = 60;

fn empty_history() -> CachedDocHistory {
    CachedDocHistory {
        heads: Vec::new(),
        frontier: HashSet::new(),
        known_hashes: HashSet::new(),
        entries: Vec::new(),
    }
}

type Shape = (String, Vec<String>, Vec<String>, u64, u64);

fn shape(entries: &[DocHistoryEntry]) -> Vec<Shape> {
    entries
        .iter()
        .map(|entry| {
            (
                entry.hash.clone(),
                entry.heads.clone(),
                entry.deps.clone(),
                entry.additions,
                entry.deletions,
            )
        })
        .collect()
}

#[test]
fn history_built_incrementally_matches_history_built_from_the_root() {
    for seed in 0..SEEDS {
        let mut rng = Rng::new(seed ^ 0x1570);
        let mut swarm = Swarm::new(&mut rng);
        let mut incremental = empty_history();

        for _ in 0..STEPS {
            swarm.step(&mut rng);
            if rng.chance(30) {
                continue;
            }
            let heads = normalized_heads(swarm.main.get_heads());
            if heads == incremental.heads {
                continue;
            }
            let changes = swarm.main.get_changes(&incremental.heads);
            incremental.heads = heads;
            append_history_entries(&mut incremental, changes);
        }
        let heads = normalized_heads(swarm.main.get_heads());
        let changes = swarm.main.get_changes(&incremental.heads);
        incremental.heads = heads;
        append_history_entries(&mut incremental, changes);

        let mut from_root = empty_history();
        from_root.heads = normalized_heads(swarm.main.get_heads());
        append_history_entries(&mut from_root, swarm.main.get_changes(&[]));

        assert_eq!(
            shape(&incremental.entries),
            shape(&from_root.entries),
            "seed {seed}"
        );
    }
}

#[test]
fn each_history_entry_records_the_heads_of_the_document_at_that_point() {
    for seed in 0..SEEDS {
        let mut rng = Rng::new(seed ^ 0x40f);
        let mut swarm = Swarm::new(&mut rng);
        for _ in 0..STEPS {
            swarm.step(&mut rng);
        }

        let mut history = empty_history();
        let changes = swarm.main.get_changes(&[]);
        let mut replay = Automerge::new();
        for change in changes {
            replay.apply_changes([change.clone()]).unwrap();
            append_history_entries(&mut history, vec![change]);
            let mut want: Vec<String> =
                replay.get_heads().iter().map(ToString::to_string).collect();
            want.sort();
            assert_eq!(history.entries.last().unwrap().heads, want, "seed {seed}");
        }
    }
}
