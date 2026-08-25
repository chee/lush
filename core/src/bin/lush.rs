use std::{path::PathBuf, sync::Arc, time::Duration};

use anyhow::Result;
use clap::{Parser, Subcommand};
use lush_core::{
    repo::{DocId, Repo, RepoEvent, DEFAULT_SERVER},
    shapes,
};

#[derive(Parser)]
struct Args {
    #[arg(long, default_value = "/tmp/lush-data")]
    data: PathBuf,
    #[arg(long, default_value = DEFAULT_SERVER)]
    server: String,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Fetch a doc from the sync server and dump it
    Fetch { url: String },
    /// Create a patchwork folder doc
    InitFolder {
        #[arg(default_value = "Notes")]
        title: String,
    },
    /// Create a rich note inside a folder
    AddNote {
        folder: String,
        #[arg(default_value = "Untitled")]
        title: String,
    },
    /// Watch a doc for remote changes
    Watch { url: String },
    /// Append text to a note's content
    Append { url: String, text: String },
    /// Dump a doc as raw JSON
    Json { url: String },
    /// Repair url fields in an account's lush config that concurrent edits
    /// fused into unparseable urls, recovering the originals from history
    RepairConfig { account: String },
}

async fn dump(repo: &Arc<Repo>, id: DocId) -> Result<()> {
    let (title, spans, links) = repo
        .read_doc(id, |doc| {
            Ok((
                shapes::doc_title(doc),
                shapes::spans_to_json(doc)?,
                shapes::folder_entries(doc)?,
            ))
        })
        .await?;
    println!("url:   {}", id.to_url());
    println!("title: {title}");
    if !links.is_empty() {
        println!("docs:");
        for l in links {
            println!("  {} ({}) -> {}", l.name, l.kind, l.url);
        }
    }
    if !spans.is_empty() {
        println!("spans: {}", serde_json::to_string_pretty(&spans)?);
    }
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "warn".into()),
        )
        .init();
    let args = Args::parse();
    let repo = Repo::start(args.data, args.server, false).await?;

    match args.command {
        Command::Fetch { url } => {
            let id = DocId::from_url(&url)?;
            repo.ensure_doc(id).await?;
            if !repo.wait_for_doc(id, Duration::from_secs(20)).await {
                eprintln!("timed out waiting for doc");
            }
            dump(&repo, id).await?;
        }
        Command::InitFolder { title } => {
            let id = repo
                .create_doc(|doc| shapes::init_folder(doc, &title))
                .await?;
            repo.flush(id).await?;
            println!("{}", id.to_url());
        }
        Command::AddNote { folder, title } => {
            let folder_id = DocId::from_url(&folder)?;
            repo.ensure_doc(folder_id).await?;
            if !repo.wait_for_doc(folder_id, Duration::from_secs(20)).await {
                anyhow::bail!("folder doc never arrived");
            }
            let note_id = repo
                .create_doc(|doc| shapes::init_rich_note(doc, &title))
                .await?;
            repo.change_doc(folder_id, |doc| {
                shapes::add_folder_entry(
                    doc,
                    &shapes::DocLink {
                        name: title.clone(),
                        kind: "rich".into(),
                        url: note_id.to_url(),
                        lush: None,
                    },
                    // the CLI has no settings to read, so it does what the app
                    // does out of the box
                    false,
                )
            })
            .await?;
            repo.flush(note_id).await?;
            repo.flush(folder_id).await?;
            println!("{}", note_id.to_url());
        }
        Command::Append { url, text } => {
            let id = DocId::from_url(&url)?;
            repo.ensure_doc(id).await?;
            if !repo.wait_for_doc(id, Duration::from_secs(20)).await {
                anyhow::bail!("doc never arrived");
            }
            repo.change_doc(id, |doc| {
                let mut spans = shapes::spans_to_json(doc)?;
                spans.push(shapes::SpanJson::Text {
                    value: text.clone(),
                    marks: None,
                });
                shapes::update_spans_from_json(doc, &spans)?;
                Ok(())
            })
            .await?;
            repo.flush(id).await?;
            dump(&repo, id).await?;
        }
        Command::Json { url } => {
            let id = DocId::from_url(&url)?;
            repo.ensure_doc(id).await?;
            if !repo.wait_for_doc(id, Duration::from_secs(30)).await {
                anyhow::bail!("doc never arrived");
            }
            let json = repo
                .read_doc(id, |doc| {
                    Ok(serde_json::to_string(&automerge::AutoSerde::from(doc))?)
                })
                .await?;
            println!("{json}");
        }
        Command::RepairConfig { account } => {
            let account_id = DocId::from_url(&account)?;
            repo.ensure_doc(account_id).await?;
            if !repo.wait_for_doc(account_id, Duration::from_secs(30)).await {
                anyhow::bail!("account doc never arrived");
            }
            let config_url = repo
                .read_doc(account_id, |doc| Ok(shapes::account_tools_lush(doc)))
                .await?
                .ok_or_else(|| anyhow::anyhow!("account has no lush config"))?;
            let config = DocId::from_url(&config_url)?;
            repo.ensure_doc(config).await?;
            if !repo.wait_for_doc(config, Duration::from_secs(30)).await {
                anyhow::bail!("config doc never arrived");
            }
            let before = repo
                .read_doc(config, |doc| Ok(shapes::config_folders(doc)))
                .await?;
            repo.change_doc(config, shapes::repair_config_urls).await?;
            let after = repo
                .read_doc(config, |doc| Ok(shapes::config_folders(doc)))
                .await?;
            repo.flush(config).await?;
            println!("config: {config_url}");
            println!("folders before repair: {}", before.len());
            for url in &after {
                println!("  {url}");
            }
            if after == before {
                println!("nothing to repair");
            }
        }
        Command::Watch { url } => {
            let id = DocId::from_url(&url)?;
            let mut events = repo.subscribe();
            repo.ensure_doc(id).await?;
            repo.wait_for_doc(id, Duration::from_secs(20)).await;
            dump(&repo, id).await?;
            println!("--- watching (ctrl-c to stop) ---");
            while let Ok(event) = events.recv().await {
                match event {
                    RepoEvent::DocChanged(changed) if changed == id => {
                        println!("--- changed ---");
                        dump(&repo, id).await?;
                    }
                    RepoEvent::Connected => println!("[connected]"),
                    RepoEvent::Disconnected => println!("[disconnected]"),
                    _ => {}
                }
            }
        }
    }
    Ok(())
}
