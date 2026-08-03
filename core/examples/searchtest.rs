use lush_core::api::Core;

fn main() -> anyhow::Result<()> {
    let _ = std::fs::remove_dir_all("/tmp/searchtest-data");
    let core =
        Core::new("/tmp/searchtest-data".into(), None).map_err(|e| anyhow::anyhow!("{e}"))?;
    let root = core
        .ensure_folder(None)
        .map_err(|e| anyhow::anyhow!("{e}"))?;
    let note1 = core
        .create_note("surface note".into())
        .map_err(|e| anyhow::anyhow!("{e}"))?;
    core.update_note_spans(
        note1,
        r#"[{"type":"block","value":{"type":"paragraph","parents":[],"attrs":{},"isEmbed":false}},{"type":"text","value":"the walrus lives on the surface"}]"#.into(),
    ).map_err(|e| anyhow::anyhow!("{e}"))?;
    let sub = core
        .create_subfolder("deeper".into())
        .map_err(|e| anyhow::anyhow!("{e}"))?;
    core.ensure_folder(Some(sub.clone()))
        .map_err(|e| anyhow::anyhow!("{e}"))?;
    let note2 = core
        .create_note("hidden note".into())
        .map_err(|e| anyhow::anyhow!("{e}"))?;
    core.update_note_spans(
        note2,
        r#"[{"type":"block","value":{"type":"paragraph","parents":[],"attrs":{},"isEmbed":false}},{"type":"text","value":"a walrus hiding in a subfolder"}]"#.into(),
    ).map_err(|e| anyhow::anyhow!("{e}"))?;
    // back to root, search recursively
    core.ensure_folder(Some(root.clone()))
        .map_err(|e| anyhow::anyhow!("{e}"))?;
    let hits = core.search_notes("walrus".into());
    for h in &hits {
        println!("hit: {} | {} | {}", h.name, h.url, h.snippet);
    }
    assert_eq!(hits.len(), 2, "expected hits from root and subfolder");
    let entries = core.list_notes();
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
