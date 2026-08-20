use std::collections::{HashMap, HashSet};

use automerge::{
    hydrate, transaction::Transactable, ActorId, Automerge, ObjType, ReadDoc, ScalarValue, ROOT,
};

use super::*;

const SEEDS: u64 = 24;
const STEPS: usize = 300;
const SAVE_CHANCE: u64 = 4;
const PEERS: usize = 3;

pub(crate) struct Rng(pub(crate) u64);

impl Rng {
    pub(crate) fn new(seed: u64) -> Self {
        Rng(seed.wrapping_mul(0x9e3779b97f4a7c15) | 1)
    }

    pub(crate) fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545f4914f6cdd1d)
    }

    pub(crate) fn below(&mut self, n: usize) -> usize {
        if n == 0 {
            0
        } else {
            (self.next() % n as u64) as usize
        }
    }

    pub(crate) fn chance(&mut self, percent: u64) -> bool {
        self.next() % 100 < percent
    }
}

const WORDS: [&str; 8] = [
    "ash", "birch", "cedar", "dill", "elm", "fern", "gorse", "holly",
];

fn word(rng: &mut Rng) -> &'static str {
    WORDS[rng.below(WORDS.len())]
}

fn text_obj<T: Transactable>(t: &mut T, key: &str) -> automerge::ObjId {
    match t.get(ROOT, key) {
        Ok(Some((automerge::Value::Object(ObjType::Text), id))) => id,
        _ => t.put_object(ROOT, key, ObjType::Text).unwrap(),
    }
}

fn list_obj<T: Transactable>(t: &mut T, key: &str) -> automerge::ObjId {
    match t.get(ROOT, key) {
        Ok(Some((automerge::Value::Object(ObjType::List), id))) => id,
        _ => t.put_object(ROOT, key, ObjType::List).unwrap(),
    }
}

pub(crate) fn edit(doc: &mut Automerge, rng: &mut Rng) {
    let mut t = doc.transaction();
    match rng.below(7) {
        0 => {
            t.put(ROOT, word(rng), rng.next() as i64).unwrap();
        }
        1 => {
            t.put(ROOT, word(rng), word(rng)).unwrap();
        }
        2 => {
            t.delete(ROOT, word(rng)).ok();
        }
        3 => {
            let id = text_obj(&mut t, "body");
            let len = t.length(&id);
            let at = rng.below(len + 1);
            t.splice_text(&id, at, 0, word(rng)).unwrap();
        }
        4 => {
            let id = text_obj(&mut t, "body");
            let len = t.length(&id);
            if len > 0 {
                let at = rng.below(len);
                let del = 1 + rng.below((len - at).min(4));
                t.splice_text(&id, at, del as isize, "").unwrap();
            }
        }
        5 => {
            let id = list_obj(&mut t, "items");
            let len = t.length(&id);
            let at = rng.below(len + 1);
            if rng.chance(30) {
                let entry = t.insert_object(&id, at, ObjType::Map).unwrap();
                t.put(&entry, "name", word(rng)).unwrap();
                t.put(&entry, "count", ScalarValue::counter(rng.below(5) as i64))
                    .unwrap();
            } else {
                t.insert(&id, at, word(rng)).unwrap();
            }
        }
        _ => {
            let id = list_obj(&mut t, "items");
            let len = t.length(&id);
            if len > 0 {
                t.delete(&id, rng.below(len)).unwrap();
            }
        }
    }
    t.commit();
}

fn empty_value() -> hydrate::Value {
    hydrate::Value::Map(hydrate::Map::default())
}

fn materialize_from_root(doc: &Automerge) -> hydrate::Value {
    let mut value = empty_value();
    value
        .apply_patches(doc.text_encoding(), doc.diff(&[], &doc.get_heads()))
        .unwrap();
    value
}

pub(crate) struct Swarm {
    pub(crate) main: Automerge,
    peers: Vec<Automerge>,
}

impl Swarm {
    pub(crate) fn new(rng: &mut Rng) -> Self {
        let mut main = Automerge::new().with_actor(ActorId::from([0u8; 16].as_slice()));
        edit(&mut main, rng);
        let peers = (1..=PEERS)
            .map(|n| {
                let mut fork = main.fork();
                fork.set_actor(ActorId::from([n as u8; 16].as_slice()));
                fork
            })
            .collect();
        Swarm { main, peers }
    }

    pub(crate) fn step(&mut self, rng: &mut Rng) {
        match rng.below(4) {
            0 | 1 => edit(&mut self.main, rng),
            2 => {
                let peer = rng.below(self.peers.len());
                edit(&mut self.peers[peer], rng);
            }
            _ => {
                let peer = rng.below(self.peers.len());
                let mut fork = self.peers[peer].clone();
                self.main.merge(&mut fork).unwrap();
                if rng.chance(50) {
                    let mut main = self.main.clone();
                    self.peers[peer].merge(&mut main).unwrap();
                }
            }
        }
    }
}

#[test]
fn incremental_patches_match_a_diff_from_the_root() {
    for seed in 0..SEEDS {
        let mut rng = Rng::new(seed);
        let mut swarm = Swarm::new(&mut rng);
        let mut live = empty_value();
        let mut heads = Vec::new();

        for _ in 0..STEPS {
            swarm.step(&mut rng);
            let next = swarm.main.get_heads();
            if next == heads {
                continue;
            }
            let patches = swarm.main.diff(&heads, &next);
            live.apply_patches(swarm.main.text_encoding(), patches)
                .unwrap();
            heads = next;
        }

        assert_eq!(live, materialize_from_root(&swarm.main), "seed {seed}");
        assert_eq!(live, swarm.main.hydrate(None), "seed {seed}");
    }
}

type Records = (
    Vec<StoredRecord<LooseCommit>>,
    Vec<StoredRecord<SedimentreeFragment>>,
);

fn stored_records(ingested: Ingested) -> Records {
    (
        ingested
            .commits
            .into_iter()
            .map(|(meta, blob)| StoredRecord { meta, blob })
            .collect(),
        ingested
            .fragments
            .into_iter()
            .map(|(meta, blob)| StoredRecord { meta, blob })
            .collect(),
    )
}

#[test]
fn stored_sedimentree_records_rebuild_the_live_document() {
    let mut saw_fragments = false;
    for seed in 0..SEEDS {
        let mut rng = Rng::new(seed);
        let mut swarm = Swarm::new(&mut rng);
        let sid = DocId([seed as u8; 16]).sedimentree_id();
        let mut stored_commits = HashSet::new();
        let mut stored_fragments = HashSet::new();
        let mut commits = Vec::new();
        let mut fragments = Vec::new();

        for step in 0..STEPS {
            swarm.step(&mut rng);
            if step + 1 < STEPS && !rng.chance(SAVE_CHANCE) {
                continue;
            }
            let ingested = ingest(&swarm.main, sid, &stored_commits, &stored_fragments)
                .expect("ingest should not panic");
            stored_commits.extend(ingested.commit_heads.iter().copied());
            stored_fragments.extend(ingested.fragment_heads.iter().copied());
            let (new_commits, new_fragments) = stored_records(ingested);
            saw_fragments |= !new_fragments.is_empty();
            commits.extend(new_commits);
            fragments.extend(new_fragments);
        }

        for _ in 0..rng.below(4) {
            commits.reverse();
            fragments.reverse();
        }

        let mut loaded = Automerge::new();
        load_blob_batch(&mut loaded, commits, fragments).expect("stored blobs should order");

        assert_eq!(loaded.get_heads(), swarm.main.get_heads(), "seed {seed}");
        assert_eq!(
            materialize_from_root(&loaded),
            materialize_from_root(&swarm.main),
            "seed {seed}"
        );
    }
    assert!(saw_fragments, "no run bundled a fragment record");
}

#[test]
fn out_of_order_blob_batches_converge() {
    for seed in 0..SEEDS {
        let mut rng = Rng::new(seed);
        let mut swarm = Swarm::new(&mut rng);
        let id = DocId([seed as u8; 16]);
        let sid = id.sedimentree_id();
        let mut stored_commits = HashSet::new();
        let mut stored_fragments = HashSet::new();
        let mut batches = Vec::new();

        for step in 0..STEPS {
            swarm.step(&mut rng);
            if step + 1 < STEPS && !rng.chance(SAVE_CHANCE) {
                continue;
            }
            let ingested = ingest(&swarm.main, sid, &stored_commits, &stored_fragments)
                .expect("ingest should not panic");
            stored_commits.extend(ingested.commit_heads.iter().copied());
            stored_fragments.extend(ingested.fragment_heads.iter().copied());
            let (commits, fragments) = stored_records(ingested);
            if !commits.is_empty() || !fragments.is_empty() {
                batches.push(StoredBatch {
                    sedimentree_id: sid,
                    commits,
                    fragments,
                });
            }
        }

        for index in (1..batches.len()).rev() {
            batches.swap(index, rng.below(index + 1));
        }

        let mut state = DocState::new(Automerge::new());
        for batch in batches {
            let (_, failed) = apply_batch_to_state(&mut state, batch, id);
            assert!(!failed, "seed {seed}: a stored blob failed to load");
        }

        assert_eq!(state.doc.get_heads(), swarm.main.get_heads(), "seed {seed}");
        assert_eq!(
            materialize_from_root(&state.doc),
            materialize_from_root(&swarm.main),
            "seed {seed}"
        );
    }
}

async fn drain(events: &mut broadcast::Receiver<RepoEvent>) {
    while events.try_recv().is_ok() {}
}

async fn wait_for_heads(repo: &Arc<Repo>, id: DocId, want: &[ChangeHash]) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        let heads = repo.read_doc(id, |doc| Ok(doc.get_heads())).await.unwrap();
        if heads == want {
            return;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "doc never caught up to the stored heads"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[tokio::test]
async fn repo_reopen_matches_the_in_memory_document() {
    for seed in 0..6u64 {
        let mut rng = Rng::new(seed ^ 0xfeed);
        let dir = tempfile::tempdir().unwrap();
        let repo = Repo::start(dir.path().to_path_buf(), "http://[".to_string(), false)
            .await
            .unwrap();
        let mut events = repo.subscribe();
        let id = repo
            .create_doc(|doc| {
                let mut rng = Rng::new(seed);
                edit(doc, &mut rng);
                Ok(())
            })
            .await
            .unwrap();
        let mut peers: HashMap<usize, Automerge> = HashMap::new();

        for _ in 0..24 {
            if rng.chance(60) {
                let mut step = Rng(rng.next());
                repo.change_doc(id, move |doc| {
                    edit(doc, &mut step);
                    Ok(())
                })
                .await
                .unwrap();
                continue;
            }
            let index = rng.below(PEERS);
            let peer = match peers.entry(index) {
                std::collections::hash_map::Entry::Occupied(entry) => entry.into_mut(),
                std::collections::hash_map::Entry::Vacant(entry) => {
                    let mut fork = repo.read_doc(id, |doc| Ok(doc.fork())).await.unwrap();
                    fork.set_actor(ActorId::from([200 + index as u8; 16].as_slice()));
                    entry.insert(fork)
                }
            };
            for _ in 0..=rng.below(3) {
                edit(peer, &mut rng);
            }
            let ingested =
                ingest(peer, id.sedimentree_id(), &HashSet::new(), &HashSet::new()).unwrap();
            let mut merged = repo.read_doc(id, |doc| Ok(doc.fork())).await.unwrap();
            merged.merge(&mut peer.clone()).unwrap();
            drain(&mut events).await;
            repo.core
                .store_built_batch(id.sedimentree_id(), ingested.commits, ingested.fragments)
                .await
                .unwrap();
            wait_for_heads(&repo, id, &merged.get_heads()).await;
        }

        let (heads, live) = repo
            .read_doc(id, |doc| Ok((doc.get_heads(), materialize_from_root(doc))))
            .await
            .unwrap();

        repo.drop_doc(id).await;
        repo.ensure_doc(id).await.unwrap();

        let (reloaded_heads, reloaded) = repo
            .read_doc(id, |doc| Ok((doc.get_heads(), materialize_from_root(doc))))
            .await
            .unwrap();
        assert_eq!(reloaded_heads, heads, "seed {seed}");
        assert_eq!(reloaded, live, "seed {seed}");
    }
}
