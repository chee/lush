use std::{path::PathBuf, sync::Arc, time::Duration};

use tokio::runtime::Runtime;

use crate::{
    repo::{DocId, Repo, RepoEvent, DEFAULT_SERVER},
    shapes,
};

fn synthesize_kind(kind: &str, lush: Option<&str>) -> String {
    if kind == "file" && lush == Some("script") {
        "lush:script".into()
    } else {
        kind.into()
    }
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("{msg}")]
    General { msg: String },
}

impl From<anyhow::Error> for CoreError {
    fn from(e: anyhow::Error) -> Self {
        CoreError::General {
            msg: format!("{e:#}"),
        }
    }
}

/// The pinned automerge fragments branch can panic on some change graphs
/// (change_graph.rs fragment-level assertions). Turn panics in write paths
/// into errors so a single bad doc can't abort a batch operation.
fn guarded<T>(f: impl FnOnce() -> Result<T, CoreError>) -> Result<T, CoreError> {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or_else(|_| {
        Err(CoreError::General {
            msg: "internal error (automerge panic); the change was not saved".into(),
        })
    })
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct NoteInfo {
    pub url: String,
    pub name: String,
    pub kind: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AssetInfo {
    pub name: String,
    pub mime_type: String,
    pub extension: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SearchHit {
    pub url: String,
    pub name: String,
    pub snippet: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AssetVision {
    pub description: String,
    pub ocr: String,
}

#[uniffi::export(callback_interface)]
pub trait CoreDelegate: Send + Sync {
    fn on_doc_changed(&self, url: String);
    fn on_connection_changed(&self, connected: bool);
}

#[derive(uniffi::Object)]
pub struct Core {
    runtime: Runtime,
    repo: Arc<Repo>,
    folder: std::sync::Mutex<Option<DocId>>,
}

const OPEN_TIMEOUT: Duration = Duration::from_secs(20);

#[uniffi::export]
impl Core {
    #[uniffi::constructor]
    pub fn new(data_dir: String, server_url: Option<String>) -> Result<Arc<Self>, CoreError> {
        let runtime = Runtime::new().map_err(|e| CoreError::General {
            msg: format!("tokio runtime: {e}"),
        })?;
        let server = server_url.unwrap_or_else(|| DEFAULT_SERVER.to_string());
        let repo = runtime.block_on(Repo::start(PathBuf::from(data_dir), server))?;
        Ok(Arc::new(Core {
            runtime,
            repo,
            folder: std::sync::Mutex::new(None),
        }))
    }

    pub fn set_delegate(&self, delegate: Box<dyn CoreDelegate>) {
        let mut events = self.repo.subscribe();
        self.runtime.spawn(async move {
            while let Ok(event) = events.recv().await {
                match event {
                    RepoEvent::DocChanged(id) => delegate.on_doc_changed(id.to_url()),
                    RepoEvent::Connected => delegate.on_connection_changed(true),
                    RepoEvent::Disconnected => delegate.on_connection_changed(false),
                }
            }
        });
    }

    pub fn is_connected(&self) -> bool {
        self.repo.is_connected()
    }

    /// Open an existing folder doc (waiting for it to arrive if needed) or
    /// create a fresh one. Returns the folder's automerge URL.
    pub fn ensure_folder(&self, existing_url: Option<String>) -> Result<String, CoreError> {
        let repo = self.repo.clone();
        let id = self.runtime.block_on(async move {
            match existing_url {
                Some(url) => {
                    let id = DocId::from_url(&url)?;
                    repo.ensure_doc(id).await?;
                    if !repo.wait_for_doc(id, OPEN_TIMEOUT).await {
                        anyhow::bail!("folder doc not found locally or on the server");
                    }
                    repo.change_doc(id, |doc| shapes::normalize_strings(doc)).await?;
                    Ok(id)
                }
                None => repo.create_doc(|doc| shapes::init_folder(doc, "Notes")).await,
            }
        })?;
        *self.folder.lock().unwrap() = Some(id);
        Ok(id.to_url())
    }

    pub fn folder_url(&self) -> Option<String> {
        self.folder.lock().unwrap().map(DocId::to_url)
    }

    pub fn folder_title(&self) -> String {
        let Some(id) = *self.folder.lock().unwrap() else {
            return String::new();
        };
        self.runtime
            .block_on(self.repo.read_doc(id, |doc| Ok(shapes::doc_title(doc))))
            .unwrap_or_default()
    }

    pub fn list_notes(&self) -> Vec<NoteInfo> {
        let Some(id) = *self.folder.lock().unwrap() else {
            return Vec::new();
        };
        self.runtime
            .block_on(self.repo.read_doc(id, |doc| shapes::folder_entries(doc)))
            .map(|entries| {
                entries
                    .into_iter()
                    .filter_map(|e| {
                        let kind = synthesize_kind(&e.kind, e.lush.as_deref());
                        if kind == "rich" || kind == "folder" || kind == "lush:script" {
                            Some(NoteInfo { url: e.url, name: e.name, kind })
                        } else {
                            None
                        }
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Entries of any folder doc we hold locally (no waiting, no network).
    pub fn folder_entries_of(&self, url: String) -> Vec<NoteInfo> {
        let Ok(id) = DocId::from_url(&url) else {
            return Vec::new();
        };
        self.runtime
            .block_on(self.repo.read_doc(id, |doc| shapes::folder_entries(doc)))
            .map(|entries| {
                entries
                    .into_iter()
                    .map(|e| {
                        let kind = synthesize_kind(&e.kind, e.lush.as_deref());
                        NoteInfo { url: e.url, name: e.name, kind }
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Move an entry from one folder doc to another, refusing cycles.
    pub fn move_entry(
        &self,
        from_folder: String,
        to_folder: String,
        url: String,
    ) -> Result<(), CoreError> {
        if from_folder == to_folder || to_folder == url {
            return Ok(());
        }
        let repo = self.repo.clone();
        self.runtime.block_on(async move {
            let from = DocId::from_url(&from_folder)?;
            let to = DocId::from_url(&to_folder)?;
            let moved = DocId::from_url(&url)?;
            // reject moving a folder into its own subtree
            let mut stack = vec![moved];
            let mut visited = std::collections::HashSet::new();
            while let Some(folder) = stack.pop() {
                if !visited.insert(folder) {
                    continue;
                }
                if folder == to {
                    anyhow::bail!("can't move a folder inside itself");
                }
                if let Ok(entries) = repo.read_doc(folder, |d| shapes::folder_entries(d)).await {
                    for entry in entries.iter().filter(|e| e.kind == "folder") {
                        if let Ok(id) = DocId::from_url(&entry.url) {
                            stack.push(id);
                        }
                    }
                }
            }
            let link = repo
                .read_doc(from, |d| {
                    Ok(shapes::folder_entries(d)?.into_iter().find(|e| e.url == url))
                })
                .await?
                .ok_or_else(|| anyhow::anyhow!("entry not found in source folder"))?;
            repo.change_doc(to, |d| shapes::add_folder_entry(d, &link)).await?;
            repo.change_doc(from, |d| shapes::remove_folder_entry(d, &url))
                .await?;
            Ok::<_, anyhow::Error>(())
        })?;
        Ok(())
    }

    /// Remove an entry from a specific folder doc.
    pub fn remove_entry(&self, folder_url: String, url: String) -> Result<(), CoreError> {
        let repo = self.repo.clone();
        self.runtime.block_on(async move {
            let folder = DocId::from_url(&folder_url)?;
            repo.change_doc(folder, |doc| shapes::remove_folder_entry(doc, &url))
                .await?;
            Ok::<_, anyhow::Error>(())
        })?;
        Ok(())
    }

    /// Rename a doc and its entry inside a specific folder doc.
    pub fn rename_entry(
        &self,
        folder_url: String,
        url: String,
        title: String,
    ) -> Result<(), CoreError> {
        let repo = self.repo.clone();
        self.runtime.block_on(async move {
            let id = DocId::from_url(&url)?;
            repo.change_doc(id, |doc| shapes::set_note_title(doc, &title))
                .await?;
            let folder = DocId::from_url(&folder_url)?;
            repo.change_doc(folder, |doc| {
                shapes::rename_folder_entry(doc, &url, &title)
            })
            .await?;
            Ok::<_, anyhow::Error>(())
        })?;
        Ok(())
    }

    /// Create a folder doc inside the current folder.
    pub fn create_subfolder(&self, title: String) -> Result<String, CoreError> {
        let folder = self
            .folder
            .lock()
            .unwrap()
            .ok_or_else(|| CoreError::General {
                msg: "no folder open".into(),
            })?;
        let repo = self.repo.clone();
        let url = self.runtime.block_on(async move {
            let sub = repo
                .create_doc(|doc| shapes::init_folder(doc, &title))
                .await?;
            repo.change_doc(folder, |doc| {
                shapes::add_folder_entry(
                    doc,
                    &shapes::DocLink {
                        name: title.clone(),
                        kind: "folder".into(),
                        url: sub.to_url(),
                        lush: None,
                    },
                )
            })
            .await?;
            Ok::<_, anyhow::Error>(sub.to_url())
        })?;
        Ok(url)
    }

    pub fn create_note(&self, title: String) -> Result<String, CoreError> {
        let folder = self
            .folder
            .lock()
            .unwrap()
            .ok_or_else(|| CoreError::General {
                msg: "no folder open".into(),
            })?;
        let repo = self.repo.clone();
        let url = self.runtime.block_on(async move {
            let note = repo
                .create_doc(|doc| shapes::init_rich_note(doc, &title))
                .await?;
            repo.change_doc(folder, |doc| {
                shapes::add_folder_entry(
                    doc,
                    &shapes::DocLink {
                        name: title.clone(),
                        kind: "rich".into(),
                        url: note.to_url(),
                        lush: None,
                    },
                )
            })
            .await?;
            Ok::<_, anyhow::Error>(note.to_url())
        })?;
        Ok(url)
    }

    pub fn delete_note(&self, url: String) -> Result<(), CoreError> {
        let folder = self
            .folder
            .lock()
            .unwrap()
            .ok_or_else(|| CoreError::General {
                msg: "no folder open".into(),
            })?;
        let repo = self.repo.clone();
        self.runtime.block_on(async move {
            repo.change_doc(folder, |doc| shapes::remove_folder_entry(doc, &url))
                .await?;
            Ok::<_, anyhow::Error>(())
        })?;
        Ok(())
    }

    pub fn rename_note(&self, url: String, title: String) -> Result<(), CoreError> {
        let folder = self
            .folder
            .lock()
            .unwrap()
            .ok_or_else(|| CoreError::General {
                msg: "no folder open".into(),
            })?;
        let repo = self.repo.clone();
        self.runtime.block_on(async move {
            let id = DocId::from_url(&url)?;
            repo.change_doc(id, |doc| shapes::set_note_title(doc, &title))
                .await?;
            repo.change_doc(folder, |doc| {
                shapes::rename_folder_entry(doc, &url, &title)
            })
            .await?;
            Ok::<_, anyhow::Error>(())
        })?;
        Ok(())
    }

    /// Start tracking + syncing a note. Returns once the doc is available
    /// locally (immediately for docs we already have).
    pub fn open_note(&self, url: String) -> Result<(), CoreError> {
        let repo = self.repo.clone();
        self.runtime.block_on(async move {
            let id = DocId::from_url(&url)?;
            repo.ensure_doc(id).await?;
            if repo.wait_for_doc(id, OPEN_TIMEOUT).await {
                repo.change_doc(id, |doc| shapes::normalize_strings(doc)).await?;
            }
            Ok::<_, anyhow::Error>(())
        })?;
        Ok(())
    }

    /// Start tracking + syncing docs without waiting for them to arrive,
    /// recursing into subfolders. Once a doc lands, its legacy scalar
    /// strings are normalized to Text.
    pub fn prefetch_notes(&self, urls: Vec<String>) {
        let repo = self.repo.clone();
        self.runtime.spawn(async move {
            let mut visited = std::collections::HashSet::new();
            let mut queue: Vec<String> = urls;
            while let Some(url) = queue.pop() {
                let Ok(id) = DocId::from_url(&url) else { continue };
                if !visited.insert(id) || visited.len() > 500 {
                    continue;
                }
                if repo.ensure_doc(id).await.is_err() {
                    continue;
                }
                if !repo.wait_for_doc(id, Duration::from_secs(30)).await {
                    continue;
                }
                let _ = repo
                    .change_doc(id, |doc| shapes::normalize_strings(doc))
                    .await;
                if let Ok(entries) = repo.read_doc(id, |doc| shapes::folder_entries(doc)).await {
                    for entry in entries {
                        queue.push(entry.url);
                    }
                }
                if let Ok(embeds) = repo.read_doc(id, |doc| Ok(shapes::embed_urls(doc))).await {
                    queue.extend(embeds);
                }
            }
        });
    }

    /// Case-insensitive full-text search across every note reachable from the
    /// current folder, recursing into subfolders. Docs are held in memory by
    /// prefetch, so this is a local scan.
    pub fn search_notes(&self, query: String) -> Vec<SearchHit> {
        let query = query.trim().to_string();
        if query.is_empty() {
            return Vec::new();
        }
        let Some(root) = *self.folder.lock().unwrap() else {
            return Vec::new();
        };
        let repo = self.repo.clone();
        self.runtime.block_on(async move {
            let mut hits = Vec::new();
            let mut visited = std::collections::HashSet::new();
            let mut folders = vec![root];
            visited.insert(root);
            while let Some(folder) = folders.pop() {
                let Ok(entries) = repo.read_doc(folder, |doc| shapes::folder_entries(doc)).await
                else {
                    continue;
                };
                for entry in entries {
                    let Ok(id) = DocId::from_url(&entry.url) else {
                        continue;
                    };
                    if !visited.insert(id) {
                        continue;
                    }
                    if entry.kind == "folder" {
                        folders.push(id);
                        continue;
                    }
                    if entry.kind != "rich" {
                        continue;
                    }
                    let matched = repo
                        .read_doc(id, |doc| {
                            let title = shapes::doc_title(doc);
                            let text = shapes::full_text(doc);
                            if let Some(snippet) = shapes::search_snippet(&text, &query) {
                                return Ok(Some(snippet));
                            }
                            if shapes::search_snippet(&title, &query).is_some() {
                                return Ok(Some(shapes::note_preview(doc)));
                            }
                            Ok(None)
                        })
                        .await;
                    if let Ok(Some(snippet)) = matched {
                        hits.push(SearchHit {
                            url: entry.url,
                            name: entry.name,
                            snippet,
                        });
                        continue;
                    }
                    // no body match: check attached files' names + vision text
                    let embeds = repo
                        .read_doc(id, |doc| Ok(shapes::embed_urls(doc)))
                        .await
                        .unwrap_or_default();
                    for asset_url in embeds {
                        let Ok(asset_id) = DocId::from_url(&asset_url) else {
                            continue;
                        };
                        let found = repo
                            .read_doc(asset_id, |doc| {
                                Ok(shapes::search_snippet(
                                    &shapes::asset_search_text(doc),
                                    &query,
                                ))
                            })
                            .await;
                        if let Ok(Some(snippet)) = found {
                            hits.push(SearchHit {
                                url: entry.url.clone(),
                                name: entry.name.clone(),
                                snippet,
                            });
                            break;
                        }
                    }
                }
            }
            hits
        })
    }

    pub fn note_preview(&self, url: String) -> String {
        let Ok(id) = DocId::from_url(&url) else {
            return String::new();
        };
        self.runtime
            .block_on(self.repo.read_doc(id, |doc| Ok(shapes::note_preview(doc))))
            .unwrap_or_default()
    }

    /// Store binary data as a patchwork UnixFileEntry doc; returns its URL.
    pub fn create_asset(
        &self,
        name: String,
        extension: String,
        mime_type: String,
        data: Vec<u8>,
    ) -> Result<String, CoreError> {
        let repo = self.repo.clone();
        let url = self.runtime.block_on(async move {
            let id = repo
                .create_doc(|doc| {
                    shapes::init_file_doc(doc, &name, &extension, &mime_type, data)
                })
                .await?;
            Ok::<_, anyhow::Error>(id.to_url())
        })?;
        Ok(url)
    }

    /// Write Vision OCR + description onto a UnixFileEntry doc.
    pub fn update_asset_vision(
        &self,
        url: String,
        description: String,
        ocr: String,
    ) -> Result<(), CoreError> {
        let repo = self.repo.clone();
        self.runtime.block_on(async move {
            let id = DocId::from_url(&url)?;
            repo.ensure_doc(id).await?;
            if !repo.wait_for_doc(id, OPEN_TIMEOUT).await {
                anyhow::bail!("asset not found");
            }
            repo.change_doc(id, |doc| shapes::set_vision_metadata(doc, &description, &ocr))
                .await?;
            Ok::<_, anyhow::Error>(())
        })?;
        Ok(())
    }

    pub fn asset_info(&self, url: String) -> Option<AssetInfo> {
        let id = DocId::from_url(&url).ok()?;
        self.runtime
            .block_on(self.repo.read_doc(id, |doc| {
                Ok(AssetInfo {
                    name: shapes::doc_field(doc, "name"),
                    mime_type: shapes::doc_field(doc, "mimeType"),
                    extension: shapes::doc_field(doc, "extension"),
                })
            }))
            .ok()
    }

    pub fn asset_vision(&self, url: String) -> Option<AssetVision> {
        let id = DocId::from_url(&url).ok()?;
        self.runtime
            .block_on(self.repo.read_doc(id, |doc| Ok(shapes::asset_vision(doc))))
            .ok()
            .flatten()
            .map(|(description, ocr)| AssetVision { description, ocr })
    }

    pub fn asset_bytes(&self, url: String) -> Result<Vec<u8>, CoreError> {
        let repo = self.repo.clone();
        let bytes = self.runtime.block_on(async move {
            let id = DocId::from_url(&url)?;
            repo.ensure_doc(id).await?;
            if !repo.wait_for_doc(id, OPEN_TIMEOUT).await {
                anyhow::bail!("asset not found locally or on the server");
            }
            repo.read_doc(id, |doc| {
                shapes::file_bytes(doc).ok_or_else(|| anyhow::anyhow!("doc has no binary content"))
            })
            .await
        })?;
        Ok(bytes)
    }

    pub fn note_title(&self, url: String) -> String {
        let Ok(id) = DocId::from_url(&url) else {
            return String::new();
        };
        self.runtime
            .block_on(self.repo.read_doc(id, |doc| Ok(shapes::doc_title(doc))))
            .unwrap_or_default()
    }

    pub fn note_spans_json(&self, url: String) -> Result<String, CoreError> {
        let repo = self.repo.clone();
        let json = self.runtime.block_on(async move {
            let id = DocId::from_url(&url)?;
            let spans = repo.read_doc(id, |doc| shapes::spans_to_json(doc)).await?;
            Ok::<_, anyhow::Error>(serde_json::to_string(&spans)?)
        })?;
        Ok(json)
    }

    pub fn update_note_spans(&self, url: String, spans_json: String) -> Result<(), CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            self.runtime.block_on(async move {
                let id = DocId::from_url(&url)?;
                let spans: Vec<shapes::SpanJson> = serde_json::from_str(&spans_json)?;
                repo.change_doc(id, |doc| {
                    shapes::update_spans_from_json(doc, &spans)?;
                    Ok(())
                })
                .await?;
                Ok::<_, anyhow::Error>(())
            })?;
            Ok(())
        })
    }

    /// Like `update_note_spans`, but the commit is stamped with the given
    /// unix-seconds timestamp — used by importers to preserve edit dates.
    pub fn update_note_spans_at(
        &self,
        url: String,
        spans_json: String,
        timestamp: i64,
    ) -> Result<(), CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            self.runtime.block_on(async move {
                let id = DocId::from_url(&url)?;
                let spans: Vec<shapes::SpanJson> = serde_json::from_str(&spans_json)?;
                repo.change_doc(id, |doc| {
                    shapes::update_spans_from_json_at(doc, &spans, timestamp)?;
                    Ok(())
                })
                .await?;
                Ok::<_, anyhow::Error>(())
            })?;
            Ok(())
        })
    }

    pub fn create_script_in(&self, folder_url: String, name: String) -> Result<String, CoreError> {
        let repo = self.repo.clone();
        let url = self.runtime.block_on(async move {
            let script = repo.create_doc(|doc| shapes::init_script(doc, &name)).await?;
            let folder = DocId::from_url(&folder_url)?;
            repo.change_doc(folder, |doc| {
                shapes::add_folder_entry(
                    doc,
                    &shapes::DocLink {
                        name: name.clone(),
                        kind: "file".into(),
                        url: script.to_url(),
                        lush: Some("script".into()),
                    },
                )
            })
            .await?;
            Ok::<_, anyhow::Error>(script.to_url())
        })?;
        Ok(url)
    }

    /// Unix seconds of the newest change in the doc (0 when unknown).
    pub fn note_modified(&self, url: String) -> i64 {
        let Ok(id) = DocId::from_url(&url) else {
            return 0;
        };
        self.runtime
            .block_on(self.repo.read_doc(id, |doc| {
                Ok(doc
                    .get_changes(&[])
                    .iter()
                    .map(|c| c.timestamp())
                    .max()
                    .unwrap_or(0))
            }))
            .unwrap_or(0)
    }

    /// Create a note inside a specific folder doc.
    pub fn create_note_in(&self, folder_url: String, title: String) -> Result<String, CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            let url = self.runtime.block_on(async move {
                let folder = DocId::from_url(&folder_url)?;
                let note = repo
                    .create_doc(|doc| shapes::init_rich_note(doc, &title))
                    .await?;
                repo.change_doc(folder, |doc| {
                    shapes::add_folder_entry(
                        doc,
                        &shapes::DocLink {
                            name: title.clone(),
                            kind: "rich".into(),
                            url: note.to_url(),
                            lush: None,
                        },
                    )
                })
                .await?;
                Ok::<_, anyhow::Error>(note.to_url())
            })?;
            Ok(url)
        })
    }

    /// Create a folder doc inside a specific folder doc.
    pub fn create_subfolder_in(
        &self,
        folder_url: String,
        title: String,
    ) -> Result<String, CoreError> {
        guarded(|| {
            let repo = self.repo.clone();
            let url = self.runtime.block_on(async move {
                let folder = DocId::from_url(&folder_url)?;
                let sub = repo
                    .create_doc(|doc| shapes::init_folder(doc, &title))
                    .await?;
                repo.change_doc(folder, |doc| {
                    shapes::add_folder_entry(
                        doc,
                        &shapes::DocLink {
                            name: title.clone(),
                            kind: "folder".into(),
                            url: sub.to_url(),
                            lush: None,
                        },
                    )
                })
                .await?;
                Ok::<_, anyhow::Error>(sub.to_url())
            })?;
            Ok(url)
        })
    }
}
