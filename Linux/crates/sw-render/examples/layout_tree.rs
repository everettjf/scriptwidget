//! Lays out canonical element trees and writes the recorded elements as JSON,
//! without painting: what `Linux/scripts/find-truncated-text.mjs` reads to
//! find text that did not fit.
//!
//!   cargo run --release -p sw-render --example layout_tree -- [assets directory] < jobs
//!
//! Each line of standard input is one job, its fields separated by tabs:
//! `<tree.json> <family> <now, in milliseconds since 1970, or -> <package folder or -> <out.json>`.
//! One line is printed for each job: `ok` or `failed: <reason>`. The assets
//! directory is the one `node Linux/scripts/build-shared-js.mjs` writes
//! (default: `Linux/assets/scriptwidget`). A tree is what a package execution
//! returns; this example does not run packages.

use std::io::BufRead;
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;

use sw_core::{DiskPackageFiles, PackageFiles, SharedScripts};
use sw_render::{RenderRequest, WidgetRenderer};

fn lay_out(renderer: &WidgetRenderer, line: &str) -> Result<(), String> {
    let [tree_file, family, now, package, output] = line.split('\t').collect::<Vec<_>>()[..] else {
        return Err("a job is <tree.json> <family> <now or -> <package folder or -> <out.json>, separated by tabs".into());
    };
    let tree = std::fs::read_to_string(tree_file).map_err(|error| format!("{tree_file}: {error}"))?;
    let mut request = RenderRequest::for_family(tree, family, 1.0).ok_or_else(|| format!("{family} is not a widget family"))?;
    if now != "-" {
        request.now_milliseconds = Some(now.parse().map_err(|_| format!("{now} is not a time"))?);
    }
    if package != "-" {
        request.files = Some(Arc::new(DiskPackageFiles::new(PathBuf::from(package))) as Arc<dyn PackageFiles>);
    }
    let layout = renderer.layout(request).map_err(|error| error.to_string())?;
    std::fs::write(output, layout).map_err(|error| format!("{output}: {error}"))
}

fn main() -> ExitCode {
    let assets = std::env::args().nth(1).map_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../assets/scriptwidget"), PathBuf::from);
    let renderer = match SharedScripts::new(assets).map_err(|error| error.to_string()).and_then(|scripts| WidgetRenderer::new(Arc::new(scripts)).map_err(|error| error.to_string())) {
        Ok(renderer) => renderer,
        Err(message) => {
            eprintln!("{message}");
            return ExitCode::FAILURE;
        }
    };
    for line in std::io::stdin().lock().lines().map_while(Result::ok).filter(|line| !line.is_empty()) {
        match lay_out(&renderer, &line) {
            Ok(()) => println!("ok"),
            Err(message) => println!("failed: {}", message.replace('\n', " ")),
        }
    }
    ExitCode::SUCCESS
}
