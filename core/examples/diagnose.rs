//! Read-only: report which stored blob of a doc automerge cannot parse.
//!
//!   cargo run --example diagnose -- automerge:<id> [data-dir]

use std::collections::HashSet;

use automerge::Automerge;
use lush_core::repo::DocId;
use sedimentree_core::blob::Blob;
use sedimentree_fs_storage::FsStorage;
use subduction_core::storage::traits::Storage;

#[tokio::main]
async fn main() {
    let mut args = std::env::args().skip(1);
    let url = args.next().expect("usage: diagnose <automerge:url> [data-dir]");
    let data_dir = args.next().map(std::path::PathBuf::from).unwrap_or_else(|| {
        let home = std::env::var("HOME").expect("HOME");
        std::path::PathBuf::from(home).join(
            "Library/Containers/party.chee.patchwork.lush/Data/\
             Library/Application Support/LushCore",
        )
    });

    let id = DocId::from_url(&url).expect("bad doc url");
    let sid = id.sedimentree_id();
    println!("doc  {url}");
    println!("dir  {}", data_dir.display());

    let storage = FsStorage::new(data_dir.join("sedimentree"))
        .expect("opening sedimentree storage");

    let commits = <FsStorage as Storage<future_form::Sendable>>::load_loose_commits(&storage, sid)
        .await
        .expect("load_loose_commits");
    let fragments = <FsStorage as Storage<future_form::Sendable>>::load_fragments(&storage, sid)
        .await
        .expect("load_fragments");
    println!(
        "held {} loose commit(s), {} fragment(s)\n",
        commits.len(),
        fragments.len()
    );

    // Each blob on its own: does automerge parse the bytes at all?
    let mut bad = Vec::new();
    let mut record = |kind: &str, index: usize, blob: &Blob| {
        let bytes = blob.as_slice();
        let mut probe = Automerge::new();
        let verdict = match probe.load_incremental(bytes) {
            Ok(_) => "parses".to_string(),
            Err(e) => {
                bad.push(format!("{kind} #{index}"));
                format!("FAILS: {e}")
            }
        };
        println!("{kind:9} #{index:<4} {:>9} bytes  {verdict}", bytes.len());
    };
    for (i, verified) in commits.iter().enumerate() {
        record("commit", i, verified.blob());
    }
    for (i, verified) in fragments.iter().enumerate() {
        record("fragment", i, verified.blob());
    }

    // Then cumulatively, in storage order, to see how far a real load gets.
    println!();
    let mut doc = Automerge::new();
    let mut applied = 0usize;
    let mut seen: HashSet<Vec<u8>> = HashSet::new();
    let all: Vec<Vec<u8>> = commits
        .iter()
        .map(|v| v.blob().as_slice().to_vec())
        .chain(fragments.iter().map(|v| v.blob().as_slice().to_vec()))
        .collect();
    for bytes in all {
        if !seen.insert(bytes.clone()) {
            continue;
        }
        match doc.load_incremental(&bytes) {
            Ok(_) => applied += 1,
            Err(e) => println!("cumulative load stopped after {applied} blob(s): {e}"),
        }
    }
    println!("cumulative: {applied} blob(s) applied, heads {:?}", doc.get_heads());
    if bad.is_empty() {
        println!("\nevery blob parses on its own");
    } else {
        println!("\nunparseable on their own: {}", bad.join(", "));
    }
}
