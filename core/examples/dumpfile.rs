use automerge::Automerge;

fn main() {
    let path = std::env::args().nth(1).unwrap();
    let bytes = std::fs::read(path).unwrap();
    let doc = Automerge::load(&bytes).unwrap();
    let spans = richtext_core::shapes::spans_to_json(&doc).unwrap();
    println!("{}", serde_json::to_string_pretty(&spans).unwrap());
}
