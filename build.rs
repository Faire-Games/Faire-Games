//! Generates typed resource constants from this app's `resource/` directory (§18.5).
//!
//! `day-build` scans `resource/{images,assets,fonts}` and writes `$OUT_DIR/day_resources.rs`, which
//! `src/lib.rs` surfaces as the `res` module. App code then references bundled resources by a
//! compiler-checked symbol, `image(res::images::app_logo)`, instead of a bare string: a typo is a
//! build error, the resource is guaranteed bundled, and the available names autocomplete. Adding or
//! removing a file under `resource/` regenerates on the next build.
//! The app title is embedded from Day's resolved metadata for the home and window headings.
fn main() {
    day_build::generate_resources().expect("day-build: resource codegen");
    let title = day_build::app_title().expect("day-build: app title");
    let out = std::path::PathBuf::from(std::env::var_os("OUT_DIR").expect("OUT_DIR"));
    std::fs::write(
        out.join("app_title.rs"),
        format!("const APP_TITLE: &str = {title:?};\n"),
    )
    .expect("write app title");
}
