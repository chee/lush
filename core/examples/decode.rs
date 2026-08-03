fn main() {
    for u in [
        "2gRztfBxgWnWGCUN6VSVYDM5v2ei",
        "DmdKB6mKqPzaFNonbbWFBAAb5w7",
        "4RGmEmQZAyDorZoMcgwNU4Z4wtyn",
    ] {
        let d = bs58::decode(u).with_check(None).into_vec().unwrap();
        println!(
            "{u} -> {}",
            d.iter().map(|b| format!("{b:02x}")).collect::<String>()
        );
    }
}
