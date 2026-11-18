//! The client side of the socket, used by the `scriptwidget` command line
//! and by the management window.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

use serde_json::Value;

use crate::protocol::{Refusal, Request};

/// How long a command waits for the service's answer.
const REPLY_TIMEOUT: Duration = Duration::from_secs(15);
/// A reply or an event line longer than this is not from the service.
const MAXIMUM_REPLY_BYTES: u64 = 4 * 1024 * 1024;

#[derive(Debug)]
pub enum ClientError {
    /// Nothing is listening: the service is not running.
    NotRunning,
    /// The connection ended before the answer came.
    Lost,
    /// The service refused the request.
    Refused { code: String, message: String },
}

fn connect(socket: &Path) -> Result<UnixStream, ClientError> {
    UnixStream::connect(socket).map_err(|_| ClientError::NotRunning)
}

fn read_line(reader: &mut impl BufRead) -> Option<String> {
    let mut line = String::new();
    match std::io::Read::take(reader, MAXIMUM_REPLY_BYTES).read_line(&mut line) {
        Ok(count) if count > 0 && line.ends_with('\n') => Some(line.trim_end().to_owned()),
        _ => None,
    }
}

/// Sends one request and returns the service's reply object when it says `"ok": true`.
pub fn request(socket: &Path, request: &Request) -> Result<Value, ClientError> {
    let mut stream = connect(socket)?;
    let _ = stream.set_read_timeout(Some(REPLY_TIMEOUT));
    let _ = stream.set_write_timeout(Some(REPLY_TIMEOUT));
    let mut line = request.line();
    line.push('\n');
    stream.write_all(line.as_bytes()).map_err(|_| ClientError::Lost)?;
    let reply: Value = read_line(&mut BufReader::new(stream)).and_then(|line| serde_json::from_str(&line).ok()).ok_or(ClientError::Lost)?;
    if reply["ok"] == true {
        return Ok(reply);
    }
    let error = &reply["error"];
    Err(ClientError::Refused { code: error["code"].as_str().unwrap_or("request.invalid").to_owned(), message: error["message"].as_str().unwrap_or("The service refused the request.").to_owned() })
}

/// How an event stream ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WatchEnd {
    /// The service was not running.
    NotRunning,
    /// The service said `bye`.
    Bye,
    /// The connection ended without a `bye`.
    Lost,
    /// `on_event` returned false.
    Stopped,
}

/// Connects as a watcher and calls `on_event` with every event line, until the stream ends or `on_event` returns false.
pub fn watch(socket: &Path, mut on_event: impl FnMut(&str) -> bool) -> WatchEnd {
    let Ok(mut stream) = connect(socket) else { return WatchEnd::NotRunning };
    let mut line = Request::Watch.line();
    line.push('\n');
    if stream.write_all(line.as_bytes()).is_err() {
        return WatchEnd::Lost;
    }
    let mut reader = BufReader::new(stream);
    while let Some(line) = read_line(&mut reader) {
        let Ok(event) = serde_json::from_str::<Value>(&line) else { return WatchEnd::Lost };
        // A refusal instead of events (too many connections) ends the stream like a lost connection.
        if event.get("event").is_none() {
            return WatchEnd::Lost;
        }
        if !on_event(&line) {
            return WatchEnd::Stopped;
        }
        if event["event"] == "bye" {
            return WatchEnd::Bye;
        }
    }
    WatchEnd::Lost
}

impl From<Refusal> for ClientError {
    fn from(refusal: Refusal) -> Self {
        Self::Refused { code: refusal.code.to_owned(), message: refusal.message }
    }
}
