//! Shared by the `plugins_*` tests: the plugin of the Swift tests and
//! hand-written ZIP archives. Ported from
//! `Windows/tests/ScriptWidget.Core.Tests/Plugins/PluginFixtures.cs`.
#![allow(dead_code)]

use std::io::Write;

use serde_json::Value;
use sw_core::json::Object;
use sw_core::plugins::manifest::{self, PluginError, PluginErrorKind, PluginManifest};

pub const ID: &str = "dev.scriptwidget.test-source";

/// The plugin of `testRequestBuilderMapsPathQueryHeaderAndJSONBody` in the Swift tests.
pub const BASE: &str = r#"
{
  "formatVersion": 1, "id": "dev.scriptwidget.test-source", "name": "Test Source", "version": "1.0.0",
  "summary": "Test", "symbol": "network", "author": "Tests", "license": "MIT", "minimumRuntimeVersion": "1.0",
  "baseURL": "https://api.example.com", "hosts": ["api.example.com"],
  "operations": [
    {"id": "update", "title": "Update", "method": "POST", "path": "/users/{user}", "responseType": "json", "parameters": [
      {"id": "user", "label": "User", "location": "path", "required": true},
      {"id": "page", "label": "Page", "location": "query", "required": false, "defaultValue": "1"},
      {"id": "X-Token", "label": "Token", "location": "header", "required": true, "defaultValue": null},
      {"id": "enabled", "label": "Enabled", "location": "jsonBody", "required": true}
    ]},
    {"id": "status", "title": "Status", "method": "GET", "path": "/status", "responseType": "text", "parameters": []}
  ]
}
"#;

/// The base plugin after `mutate`, as bytes.
pub fn bytes_with(mutate: impl FnOnce(&mut Value)) -> Vec<u8> {
    let mut root: Value = serde_json::from_str(BASE).expect("base plugin");
    mutate(&mut root);
    root.to_string().into_bytes()
}

pub fn bytes() -> Vec<u8> {
    bytes_with(|_| {})
}

pub fn manifest_with(mutate: impl FnOnce(&mut Value)) -> PluginManifest {
    manifest::decode(&bytes_with(mutate)).expect("a valid plugin")
}

pub fn base_manifest() -> PluginManifest {
    manifest_with(|_| {})
}

pub fn remove(value: &mut Value, key: &str) {
    value.as_object_mut().expect("object").shift_remove(key);
}

pub fn values(value: Value) -> Object {
    value.as_object().cloned().expect("values")
}

pub fn assert_rejected(expected: &str, mutate: impl FnOnce(&mut Value)) {
    let error: PluginError = manifest::decode(&bytes_with(mutate)).expect_err("the manifest must be refused");
    assert_eq!(error.kind, PluginErrorKind::InvalidManifest);
    assert!(error.message.contains(expected), "Expected \"{expected}\" in \"{}\"", error.message);
}

/// One hand-written ZIP entry; every header field an attacker controls can be forged.
#[derive(Clone)]
pub struct RawEntry {
    pub name: String,
    pub data: Vec<u8>,
    pub external_attributes: u32,
    pub flags: u16,
    pub method: u16,
    /// Deflate the data before storing it.
    pub deflate: bool,
}

impl RawEntry {
    pub fn new(name: &str, data: &[u8]) -> Self {
        Self { name: name.into(), data: data.to_vec(), external_attributes: 0x81A4 << 16, flags: 0x0800, method: 0, deflate: false }
    }

    pub fn deflated(name: &str, data: &[u8]) -> Self {
        Self { method: 8, deflate: true, ..Self::new(name, data) }
    }

    pub fn directory(name: &str) -> Self {
        Self { external_attributes: 0x41ED << 16, ..Self::new(name, b"") }
    }
}

/// A ZIP written byte by byte, like `makeStoredZIP` in the Swift tests.
pub fn raw_zip(entries: &[RawEntry]) -> Vec<u8> {
    let mut locals: Vec<u8> = Vec::new();
    let mut central: Vec<u8> = Vec::new();
    for entry in entries {
        let stored = if entry.deflate {
            let mut encoder = flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::best());
            encoder.write_all(&entry.data).unwrap();
            encoder.finish().unwrap()
        } else {
            entry.data.clone()
        };
        let crc = sw_core::plugins::files::crc32(&entry.data);
        let offset = locals.len() as u32;
        let shared: Vec<u8> = [20u16.to_le_bytes(), entry.flags.to_le_bytes(), entry.method.to_le_bytes(), 0u16.to_le_bytes(), 0x21u16.to_le_bytes()].concat();
        let sizes: Vec<u8> = [crc.to_le_bytes(), (stored.len() as u32).to_le_bytes(), (entry.data.len() as u32).to_le_bytes()].concat();
        locals.extend_from_slice(&0x0403_4B50u32.to_le_bytes());
        locals.extend_from_slice(&shared);
        locals.extend_from_slice(&sizes);
        locals.extend_from_slice(&(entry.name.len() as u16).to_le_bytes());
        locals.extend_from_slice(&0u16.to_le_bytes());
        locals.extend_from_slice(entry.name.as_bytes());
        locals.extend_from_slice(&stored);

        central.extend_from_slice(&0x0201_4B50u32.to_le_bytes());
        central.extend_from_slice(&0x031Eu16.to_le_bytes());
        central.extend_from_slice(&shared);
        central.extend_from_slice(&sizes);
        central.extend_from_slice(&(entry.name.len() as u16).to_le_bytes());
        central.extend_from_slice(&[0u8; 8]);
        central.extend_from_slice(&entry.external_attributes.to_le_bytes());
        central.extend_from_slice(&offset.to_le_bytes());
        central.extend_from_slice(entry.name.as_bytes());
    }
    let mut output = locals.clone();
    output.extend_from_slice(&central);
    output.extend_from_slice(&0x0605_4B50u32.to_le_bytes());
    output.extend_from_slice(&[0u8; 4]);
    output.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    output.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    output.extend_from_slice(&(central.len() as u32).to_le_bytes());
    output.extend_from_slice(&(locals.len() as u32).to_le_bytes());
    output.extend_from_slice(&0u16.to_le_bytes());
    output
}

/// Overwrites the uncompressed size the central directory declares for entry `index`.
pub fn forge_declared_size(archive: &[u8], index: usize, size: u32) -> Vec<u8> {
    let mut bytes = archive.to_vec();
    let u16_at = |bytes: &[u8], at: usize| u16::from_le_bytes([bytes[at], bytes[at + 1]]) as usize;
    let end = bytes.len() - 22;
    let mut cursor = u32::from_le_bytes([bytes[end + 16], bytes[end + 17], bytes[end + 18], bytes[end + 19]]) as usize;
    for _ in 0..index {
        cursor += 46 + u16_at(&bytes, cursor + 28) + u16_at(&bytes, cursor + 30) + u16_at(&bytes, cursor + 32);
    }
    assert_eq!(&bytes[cursor..cursor + 4], &0x0201_4B50u32.to_le_bytes());
    bytes[cursor + 24..cursor + 28].copy_from_slice(&size.to_le_bytes());
    bytes
}

/// Entry names and contents of an archive, in order.
pub fn read_zip(archive: &[u8]) -> Vec<(String, Vec<u8>)> {
    let entries = sw_core::plugins::files::validate_archive(archive).expect("a valid archive");
    entries.iter().map(|entry| (entry.name.clone(), sw_core::plugins::files::inflate(archive, entry, 1 << 24).expect("entry data"))).collect()
}
