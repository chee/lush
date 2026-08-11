use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::Path;

/// Persistent Ed25519 seed, stored as 64 hex chars, created 0o600 on first
/// run so the server's peer id is stable across launches.
pub fn load_or_create_seed(path: &Path) -> io::Result<[u8; 32]> {
    match fs::read_to_string(path) {
        Ok(contents) => {
            let bytes = hex::decode(contents.trim())
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
            return bytes.try_into().map_err(|_| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "key file must be 32 bytes of hex",
                )
            });
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    let mut seed = [0u8; 32];
    getrandom::getrandom(&mut seed).map_err(|e| io::Error::other(e.to_string()))?;
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("key");
    let mut nonce = [0u8; 8];
    getrandom::getrandom(&mut nonce).map_err(|e| io::Error::other(e.to_string()))?;
    let pending = path.with_file_name(format!(".{name}.{}.pending", hex::encode(nonce)));
    let result: io::Result<()> = (|| {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&pending)?;
        file.write_all(hex::encode(seed).as_bytes())?;
        file.sync_all()?;
        fs::rename(&pending, path)?;
        if let Some(parent) = path.parent() {
            fs::File::open(parent)?.sync_all()?;
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&pending);
    }
    result?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    }
    Ok(seed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    fn dir() -> std::path::PathBuf {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let nonce = format!(
            "{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        );
        let dir = std::env::temp_dir().join(format!("lush-server-key-{nonce}"));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn malformed_key_is_not_replaced() {
        let dir = dir();
        let path = dir.join("server.key");
        fs::write(&path, "malformed").unwrap();
        assert_eq!(
            load_or_create_seed(&path).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
        assert_eq!(fs::read_to_string(path).unwrap(), "malformed");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn non_missing_read_errors_are_returned() {
        let dir = dir();
        let path = dir.join("server.key");
        fs::create_dir(&path).unwrap();
        assert!(load_or_create_seed(&path).is_err());
        assert!(path.is_dir());
        fs::remove_dir_all(dir).unwrap();
    }
}
