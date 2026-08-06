use automerge::{Automerge, ReadDoc, ROOT};
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
    for k in doc.keys(ROOT) {
        let v = doc.get(ROOT, k.as_str()).unwrap().unwrap().0;
        let s = format!("{v:?}");
        println!("{k} -> {}", s.chars().take(200).collect::<String>());
    }
    println!(
        "file_bytes len: {:?}",
        lush_core::shapes::file_bytes(&doc)
            .map(|b| (b.len(), b.get(..8).map(|h| format!("{h:02x?}"))))
    );
}
