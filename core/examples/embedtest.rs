use lush_core::{repo::Repo, shapes};
use std::time::Duration;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let png: Vec<u8> = vec![
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44,
        0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F,
        0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x00,
        0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
        0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ];
    let repo = Repo::start(
        "/tmp/embedtest-data".into(),
        lush_core::repo::DEFAULT_SERVER.into(),
        false,
    )
    .await?;
    repo.wait_connected(Duration::from_secs(15)).await;

    let asset = repo
        .create_doc(|doc| shapes::init_file_doc(doc, "dot.png", "png", "image/png", png.clone()))
        .await?;
    let note = repo
        .create_doc(|doc| shapes::init_rich_note(doc, "embed test"))
        .await?;
    repo.change_doc(note, |doc| {
        let spans = vec![
            shapes::SpanJson::Block { value: serde_json::json!({"type":"paragraph","parents":[],"attrs":{},"isEmbed":false}) },
            shapes::SpanJson::Text { value: "an image:".into(), marks: None },
            shapes::SpanJson::Block { value: serde_json::json!({"type":"embed","parents":[],"attrs":{"url": asset.to_url()},"isEmbed":true}) },
        ];
        shapes::update_spans_from_json(doc, &spans)?;
        Ok(())
    }).await?;
    repo.flush(asset).await?;
    repo.flush(note).await?;
    println!("asset={} note={}", asset.to_url(), note.to_url());

    let fresh = Repo::start(
        "/tmp/embedtest-fresh".into(),
        lush_core::repo::DEFAULT_SERVER.into(),
        false,
    )
    .await?;
    fresh.ensure_doc(note).await?;
    fresh.ensure_doc(asset).await?;
    assert!(
        fresh.wait_for_doc(note, Duration::from_secs(20)).await,
        "note arrived"
    );
    assert!(
        fresh.wait_for_doc(asset, Duration::from_secs(20)).await,
        "asset arrived"
    );
    let spans = fresh.read_doc(note, shapes::spans_to_json).await?;
    println!("note spans: {}", serde_json::to_string(&spans)?);
    let bytes = fresh
        .read_doc(asset, |d| Ok(shapes::file_bytes(d)))
        .await?
        .unwrap();
    assert_eq!(bytes, png, "asset bytes roundtrip");
    println!("asset bytes roundtrip ok ({} bytes)", bytes.len());
    Ok(())
}
