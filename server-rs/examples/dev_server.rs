fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "debug,redb=info".into()),
        )
        .init();
    let dir = std::env::temp_dir().join("patchwork-dev-server");
    let _ = std::fs::remove_dir_all(&dir);
    let port = patchwork_server::server_start(dir.to_string_lossy().into_owned(), 43999)
        .expect("server_start");
    println!("dev server on ws://127.0.0.1:{port}");
    loop {
        std::thread::sleep(std::time::Duration::from_secs(3600));
    }
}
