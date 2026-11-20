//! The window, on GPUI and gpui-kit. One entity, [`window::StudioWindow`],
//! holds what is shown; each page is a file that draws its part of it.
//! Everything slow (compiling, running and drawing a package, reading and
//! writing archives, the `scriptwidget` child process) runs on background
//! threads and comes back as a message.

mod access;
mod ai;
mod editor;
mod gallery;
mod library;
mod preview_pane;
mod settings;
mod skills;
mod templates;
mod window;

use std::sync::Arc;

use futures::channel::mpsc::UnboundedReceiver;
use gpui_kit::{App, AppContext as _, Bounds, KeyBinding, TitlebarOptions, WindowBounds, WindowOptions, px, size};

use crate::instance::Request;
use crate::launch::StartPage;
use crate::model::Studio;
use crate::strings::t;

pub use window::StudioWindow;

gpui_kit::actions!(studio, [Save, Back]);

/// What the Wayland compositor and the desktop file know the window by.
pub const APP_ID: &str = "scriptwidget-studio";

/// Opens the window and runs until it is closed. `requests` carries what later starts of the program ask for.
pub fn run(studio: Arc<Studio>, first: Request, page: Option<StartPage>, requests: UnboundedReceiver<Request>) {
    gpui_kit::application().with_assets(gpui_kit::assets::Assets).run(move |cx: &mut App| {
        gpui_kit::init(cx);
        cx.bind_keys([KeyBinding::new("ctrl-s", Save, None), KeyBinding::new("alt-left", Back, None)]);
        cx.on_window_closed(|cx, _| {
            if cx.windows().is_empty() {
                cx.quit();
            }
        })
        .detach();
        cx.activate(true);

        let options = WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(Bounds::centered(None, size(px(1280.), px(800.)), cx))),
            titlebar: Some(TitlebarOptions { title: Some(t("app.title").into()), ..Default::default() }),
            app_id: Some(APP_ID.to_owned()),
            window_min_size: Some(size(px(960.), px(600.))),
            ..Default::default()
        };
        let opened = gpui_kit::open_window(options, cx, move |window, cx| {
            window.set_window_title(&t("app.title"));
            cx.new(|cx| StudioWindow::new(studio, first, page, requests, window, cx))
        });
        if let Err(error) = opened {
            eprintln!("{}", crate::strings::tf("startup.failed", &[&error.to_string()]));
            cx.quit();
        }
    });
}
