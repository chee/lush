use std::fs;
use std::io;
use std::path::Path;

/// Persistent Ed25519 seed, stored as 64 hex chars, created 0o600 on first
/// run so the server's peer id is stable across launches.
pub fn load_or_create_seed(path: &Path) -> io::Result<[u8; 32]> {
    if let Ok(contents) = fs::read_to_string(path) {
        let bytes = hex::decode(contents.trim())
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        return bytes.try_into().map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "key file must be 32 bytes of hex",
            )
        });
    }
    let mut seed = [0u8; 32];
    getrandom::getrandom(&mut seed).map_err(|e| io::Error::other(e.to_string()))?;
    fs::write(path, hex::encode(seed))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    }
    Ok(seed)
}
