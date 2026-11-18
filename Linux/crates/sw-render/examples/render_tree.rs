//! Draws a canonical element tree to a PNG, without a graphical session.
//!
//!   cargo run -p sw-render --example render_tree -- <tree.json> <family> <scale> <out.png> [assets directory]
//!
//! `family` is small, medium, large or extraLarge. The assets directory is
//! the one `node Linux/scripts/build-shared-js.mjs` writes (default:
//! `Linux/assets/scriptwidget`). A tree is what a package execution returns;
//! this example does not run packages.

use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;

use sw_core::SharedScripts;
use sw_render::{RenderRequest, WidgetRenderer};

fn run(arguments: &[String]) -> Result<String, String> {
    let [tree_file, family, scale, output, rest @ ..] = arguments else {
        return Err("usage: render_tree <tree.json> <family> <scale> <out.png> [assets directory]".into());
    };
    let assets = rest.first().map_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../assets/scriptwidget"), PathBuf::from);
    let tree = std::fs::read_to_string(tree_file).map_err(|error| format!("{tree_file}: {error}"))?;
    let scale: f32 = scale.parse().map_err(|_| format!("{scale} is not a scale"))?;
    let request = RenderRequest::for_family(tree, family, scale).ok_or_else(|| format!("{family} is not a widget family"))?;
    let scripts = Arc::new(SharedScripts::new(assets).map_err(|error| error.to_string())?);
    let renderer = WidgetRenderer::new(scripts).map_err(|error| error.to_string())?;
    let rendered = renderer.render(request).map_err(|error| error.to_string())?;
    std::fs::write(output, rendered.encode_png().map_err(|error| error.to_string())?).map_err(|error| format!("{output}: {error}"))?;
    Ok(format!(
        "{output}: {}x{} pixels, layout {:.2} ms, paint {:.2} ms, {} tap regions, {} animated GIFs",
        rendered.pixel_width,
        rendered.pixel_height,
        rendered.layout_time.as_secs_f64() * 1000.0,
        rendered.paint_time.as_secs_f64() * 1000.0,
        rendered.hit_regions.len(),
        rendered.gif_slots.len()
    ))
}

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    match run(&arguments) {
        Ok(summary) => {
            println!("{summary}");
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}
