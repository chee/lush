use automerge::Automerge;
use lush_core::repo::DocId;
use sedimentree_fs_storage::FsStorage;
use subduction_core::storage::traits::Storage;

#[tokio::main]
async fn main() {
    let url = std::env::args().nth(1).expect("url");
    let home = std::env::var("HOME").unwrap();
    let dir = std::path::PathBuf::from(home).join(
        "Library/Containers/party.chee.patchwork.lush/Data/Library/Application Support/LushCore/sedimentree",
    );
    let storage = FsStorage::new(dir).unwrap();
    let id = DocId::from_url(&url).unwrap();
    let sid = id.sedimentree_id();
    let commits = <FsStorage as Storage<future_form::Sendable>>::load_loose_commits(&storage, sid)
        .await
        .unwrap();
    let fragments = <FsStorage as Storage<future_form::Sendable>>::load_fragments(&storage, sid)
        .await
        .unwrap();
    let mut doc = Automerge::new();
    for r in &fragments {
        let _ = doc.load_incremental(r.blob().as_slice());
    }
    for r in &commits {
        let _ = doc.load_incremental(r.blob().as_slice());
    }

    let changes: Vec<_> = doc.get_changes(&[]);
    println!("{} changes total", changes.len());
    let mut last_with = None;
    for (i, change) in changes.iter().enumerate() {
        let heads = vec![change.hash()];
        let Ok(fork) = doc.fork_at(&heads) else {
            continue;
        };
        let Ok(spans) = lush_core::shapes::spans_to_json(&fork) else {
            continue;
        };
        let json = serde_json::to_string(&spans).unwrap_or_default();
        let count = json.matches("\"embed\"").count();
        if count > 0 {
            last_with = Some((i, change.hash(), count));
        }
    }
    match last_with {
        Some((i, hash, count)) => {
            println!("last state with embeds: change {i} ({hash}) — {count} embed block(s)");
            let fork = doc.fork_at(&[hash]).unwrap();
            let spans = lush_core::shapes::spans_to_json(&fork).unwrap();
            for s in &spans {
                let j = serde_json::to_string(s).unwrap();
                if j.contains("\"embed\"") {
                    println!("  {j}");
                }
            }
        }
        None => println!("no state in history ever had embed blocks"),
    }
}
