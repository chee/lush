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
    let spans = lush_core::shapes::spans_to_json(&doc).unwrap();
    println!("{}", serde_json::to_string_pretty(&spans).unwrap());
}
