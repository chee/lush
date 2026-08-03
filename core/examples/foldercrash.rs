use lush_core::api::Core;

fn main() {
    let _ = std::fs::remove_dir_all("/tmp/foldercrash-data");
    let core = Core::new("/tmp/foldercrash-data".into(), None).expect("core");
    let root = "automerge:2gRztfBxgWnWGCUN6VSVYDM5v2ei".to_string();
    let mut queue = vec![root];
    let mut visited = std::collections::HashSet::new();
    while let Some(url) = queue.pop() {
        if !visited.insert(url.clone()) {
            continue;
        }
        eprintln!("--- ensure_folder {url}");
        match core.ensure_folder(Some(url.clone())) {
            Ok(_) => eprintln!("    ok: {}", core.folder_title()),
            Err(e) => eprintln!("    ERROR: {e}"),
        }
        for entry in core.folder_entries_of(url.clone()) {
            eprintln!("    entry: {} ({}) {}", entry.name, entry.kind, entry.url);
            if entry.kind == "folder" {
                queue.push(entry.url);
            } else if entry.kind == "rich" {
                eprintln!("    open_note {}", entry.url);
                if let Err(e) = core.open_note(entry.url.clone()) {
                    eprintln!("    note ERROR: {e}");
                }
            }
        }
    }
    eprintln!("walk complete");
}
