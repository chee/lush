use std::path::{Path, PathBuf};

fn path(data_dir: &Path) -> PathBuf {
    data_dir.join("peers.json")
}

pub fn load(data_dir: &Path) -> Vec<String> {
    std::fs::read(path(data_dir))
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

pub fn add(data_dir: &Path, node_id: String) {
    let mut peers = load(data_dir);
    if peers.contains(&node_id) {
        return;
    }
    peers.push(node_id);
    if let Ok(bytes) = serde_json::to_vec_pretty(&peers) {
        let _ = std::fs::write(path(data_dir), bytes);
    }
}
