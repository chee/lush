use futures::executor::block_on;
use lush_core::api::{Core, SearchParent};

fn main() -> anyhow::Result<()> {
    let _ = std::fs::remove_dir_all("/tmp/searchtest-data");
    let core =
        Core::new("/tmp/searchtest-data".into(), None).map_err(|e| anyhow::anyhow!("{e}"))?;
    let root = core
        .ensure_folder(None)
        .map_err(|e| anyhow::anyhow!("{e}"))?;
    let note1 = core
        .create_note("surface note".into(), false)
        .map_err(|e| anyhow::anyhow!("{e}"))?;
    core.update_note_spans(
        note1.clone(),
        r#"[{"type":"block","value":{"type":"paragraph","parents":[],"attrs":{},"isEmbed":false}},{"type":"text","value":"the walrus lives on the surface"}]"#.into(),
        None,
    ).map_err(|e| anyhow::anyhow!("{e}"))?;
    let sub = core
        .create_subfolder("deeper".into())
        .map_err(|e| anyhow::anyhow!("{e}"))?;
    core.ensure_folder(Some(sub.clone()))
        .map_err(|e| anyhow::anyhow!("{e}"))?;
    let note2 = core
        .create_note("hidden note".into(), false)
        .map_err(|e| anyhow::anyhow!("{e}"))?;
    core.update_note_spans(
        note2.clone(),
        r#"[{"type":"block","value":{"type":"paragraph","parents":[],"attrs":{},"isEmbed":false}},{"type":"text","value":"a walrus hiding in a subfolder"}]"#.into(),
        None,
    ).map_err(|e| anyhow::anyhow!("{e}"))?;
    // back to root, search recursively
    core.ensure_folder(Some(root.clone()))
        .map_err(|e| anyhow::anyhow!("{e}"))?;
    let hits = core.search_notes("walrus".into(), None);
    for h in &hits {
        println!("hit: {} | {} | {}", h.name, h.url, h.snippet);
    }
    assert_eq!(hits.len(), 2, "expected hits from root and subfolder");
    core.set_search_parents(vec![
        SearchParent {
            url: note1.clone(),
            parent: root.clone(),
        },
        SearchParent {
            url: sub.clone(),
            parent: root.clone(),
        },
        SearchParent {
            url: note2.clone(),
            parent: sub.clone(),
        },
    ]);
    let scoped = core.search_notes(
        "walrus".into(),
        Some(lush_core::api::SearchFilter {
            scope: Some(sub.clone()),
            ..Default::default()
        }),
    );
    assert_eq!(
        scoped.iter().map(|h| h.url.clone()).collect::<Vec<_>>(),
        vec![note2.clone()],
        "a scoped search sees only the subfolder"
    );
    let entries = block_on(core.list_notes());
    println!(
        "root entries: {:?}",
        entries
            .iter()
            .map(|e| format!("{}({})", e.name, e.kind))
            .collect::<Vec<_>>()
    );
    println!("ok root={root}");
    Ok(())
}
