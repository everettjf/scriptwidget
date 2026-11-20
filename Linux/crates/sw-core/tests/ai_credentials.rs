//! Where the API key lives: the keyring through `secret-tool`, the key for
//! one run from the environment, and the files that must never hold it. New
//! with the Linux port; Android keeps its key in the Keystore-backed store of
//! the app.
//!
//! `secret-tool` here is a shell script that stands in for the real program:
//! it takes the same arguments and keeps its "keyring" in the test's folder.
//! Whether the real program and a real keyring behave the same is not tested
//! on this machine.

mod ai_common;
mod api_common;

use std::ffi::OsString;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use ai_common::*;
use api_common::temporary_directory;
use sw_core::ai::credentials::{ENVIRONMENT_KEY, key_for, key_from_environment};
use sw_core::ai::*;

const KEY: &str = "sk-keyring-SECRET-77c1d0";

/// Writes the stand-in program into `folder` and returns its path. It records its arguments, its
/// environment and, for `store`, what it read from standard input. Like the real program (libsecret
/// on Omarchy 4.5), `lookup` and `clear` end with a failure and say nothing when there is no item.
fn fake_secret_tool(folder: &Path) -> PathBuf {
    let program = folder.join("secret-tool");
    std::fs::write(
        &program,
        r#"#!/bin/sh
dir="$(dirname "$0")"
printf '%s\n' "$*" >> "$dir/arguments"
env > "$dir/environment"
command="$1"
for last; do :; done
case "$command" in
  store) cat > "$dir/item-$last" ;;
  lookup) [ -f "$dir/item-$last" ] || exit 1; cat "$dir/item-$last" ;;
  clear) [ -f "$dir/item-$last" ] || exit 1; rm -f "$dir/item-$last" ;;
  *) echo "unknown command" >&2; exit 2 ;;
esac
"#,
    )
    .unwrap();
    std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
    program
}

fn script(folder: &Path, name: &str, text: &str) -> PathBuf {
    let program = folder.join(name);
    std::fs::write(&program, text).unwrap();
    std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
    program
}

#[test]
fn the_key_goes_to_secret_tool_on_standard_input_and_never_in_an_argument() {
    let folder = temporary_directory("ai-secret-tool");
    let store = SecretToolStore::with_program(fake_secret_tool(&folder));
    assert_eq!(store.load("anthropic").unwrap(), None, "nothing stored yet");
    store.save("anthropic", &ApiKey::new(&format!("  {KEY}\n")).unwrap()).unwrap();
    assert_eq!(std::fs::read_to_string(folder.join("item-anthropic")).unwrap(), KEY, "exactly the key, with no line break added");
    assert_eq!(store.load("anthropic").unwrap().unwrap().expose(), KEY);
    assert_eq!(store.load("openai").unwrap(), None, "one key per provider");

    let arguments = std::fs::read_to_string(folder.join("arguments")).unwrap();
    assert!(!arguments.contains(KEY), "{arguments}");
    assert!(arguments.contains("store --label=ScriptWidget AI key (anthropic) application scriptwidget kind ai-api-key account anthropic"), "{arguments}");
    assert!(arguments.contains("lookup application scriptwidget kind ai-api-key account anthropic"));
    assert!(!std::fs::read_to_string(folder.join("environment")).unwrap().contains(KEY));

    assert!(store.remove("anthropic").unwrap());
    assert!(!store.remove("anthropic").unwrap(), "there was nothing left to remove");
    assert_eq!(store.load("anthropic").unwrap(), None);
    // A key a terminal printed with a line break is read without it.
    std::fs::write(folder.join("item-openai"), format!("{KEY}\n")).unwrap();
    assert_eq!(store.load("openai").unwrap().unwrap().expose(), KEY);
    // What is not a key is not handed on as one, and can still be removed.
    std::fs::write(folder.join("item-custom"), "two\nlines").unwrap();
    assert!(matches!(store.load("custom"), Err(CredentialError::Invalid(_))));
    assert!(store.remove("custom").unwrap());
    // An account is a provider identifier and nothing that could be read as an option or a path.
    for account in ["", "--label=x", "../x", "a b", "Anthropic"] {
        assert!(matches!(store.load(account), Err(CredentialError::Invalid(_))), "{account}");
        assert!(matches!(store.save(account, &ApiKey::new(KEY).unwrap()), Err(CredentialError::Invalid(_))), "{account}");
    }
}

/// Runs in a process of its own that has the variable set; see the next test.
#[test]
#[ignore = "run by a_child_of_this_program_never_inherits_the_key_of_one_run"]
fn child_with_the_key_in_its_environment() {
    let Some(folder) = std::env::var_os("SCRIPTWIDGET_TEST_FOLDER").map(PathBuf::from) else { return };
    assert_eq!(std::env::var(ENVIRONMENT_KEY).as_deref(), Ok(KEY), "this process was started with the key");
    let store = SecretToolStore::with_program(folder.join("secret-tool"));
    store.save("anthropic", &ApiKey::new("another-key").unwrap()).unwrap();
    assert_eq!(store.load("anthropic").unwrap().unwrap().expose(), "another-key");
}

#[test]
fn a_child_of_this_program_never_inherits_the_key_of_one_run() {
    let folder = temporary_directory("ai-secret-tool-environment");
    fake_secret_tool(&folder);
    let status = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "child_with_the_key_in_its_environment", "--ignored", "--test-threads=1"])
        .env(ENVIRONMENT_KEY, KEY)
        .env("SCRIPTWIDGET_TEST_FOLDER", &folder)
        .output()
        .unwrap();
    assert!(status.status.success(), "{}", String::from_utf8_lossy(&status.stdout));
    let environment = std::fs::read_to_string(folder.join("environment")).unwrap();
    assert!(environment.contains("PATH="), "the stand-in did run and saw an environment");
    assert!(!environment.contains(ENVIRONMENT_KEY) && !environment.contains(KEY), "{environment}");
}

#[test]
fn without_secret_tool_or_a_keyring_nothing_is_stored_and_the_message_says_so() {
    let folder = temporary_directory("ai-no-keyring");
    let key = ApiKey::new(KEY).unwrap();
    let missing = SecretToolStore::with_program(folder.join("not-installed"));
    for result in [missing.save("anthropic", &key).err(), missing.load("anthropic").err(), missing.remove("anthropic").err()] {
        let Some(CredentialError::Unavailable(message)) = result else { panic!("{result:?}") };
        assert!(message.contains("secret-tool") && message.contains("Nothing was stored") && message.contains(ENVIRONMENT_KEY), "{message}");
        assert!(!message.contains(KEY));
    }
    // secret-tool is there and no keyring answers: it says why on standard error and fails.
    let no_keyring = SecretToolStore::with_program(script(&folder, "no-keyring", "#!/bin/sh\ncat > /dev/null\necho 'secret-tool: Cannot autolaunch D-Bus without X11 $DISPLAY' >&2\nexit 1\n"));
    for result in [no_keyring.save("anthropic", &key).err(), no_keyring.load("anthropic").err(), no_keyring.remove("anthropic").err()] {
        let Some(CredentialError::Unavailable(message)) = result else { panic!("{result:?}") };
        assert!(message.contains("keyring") && message.contains("Nothing was stored elsewhere"), "{message}");
        assert!(!message.contains("D-Bus"), "what the program printed is not repeated");
    }
    // A program that cannot be run at all.
    std::fs::write(folder.join("not-a-program"), "text").unwrap();
    assert!(matches!(SecretToolStore::with_program(folder.join("not-a-program")).save("anthropic", &key), Err(CredentialError::Unavailable(_))));
    let left: Vec<String> = std::fs::read_dir(&folder).unwrap().map(|entry| entry.unwrap().file_name().into_string().unwrap()).collect();
    assert!(left.iter().all(|name| ["no-keyring", "not-a-program"].contains(&name.as_str())), "nothing was written as a fallback: {left:?}");
    for name in left {
        assert!(!std::fs::read_to_string(folder.join(name)).unwrap().contains(KEY));
    }
}

#[test]
fn the_key_of_one_run_comes_from_the_environment_and_wins() {
    let read = |value: Option<&str>| key_from_environment(value.map(OsString::from));
    assert_eq!(read(None).unwrap(), None);
    assert_eq!(read(Some("")).unwrap(), None);
    assert_eq!(read(Some("   ")).unwrap(), None);
    assert_eq!(read(Some(&format!(" {KEY} "))).unwrap().unwrap().expose(), KEY);
    for bad in ["a\nb", "a\rX-Evil: 1", "kéy"] {
        let Err(CredentialError::Invalid(message)) = read(Some(bad)) else { panic!("{bad:?} was accepted") };
        assert!(message.contains(ENVIRONMENT_KEY) && !message.contains(bad), "{message}");
    }

    let store = MemoryCredentialStore::new();
    let Err(CredentialError::Missing(message)) = key_for(&store, None, AiProviderKind::Anthropic) else { panic!("a key from nowhere") };
    assert!(message.contains("Anthropic") && message.contains("scriptwidget ai key set"), "{message}");
    store.save("anthropic", &ApiKey::new("stored-key").unwrap()).unwrap();
    assert_eq!(key_for(&store, None, AiProviderKind::Anthropic).unwrap().expose(), "stored-key");
    assert!(matches!(key_for(&store, None, AiProviderKind::OpenAi), Err(CredentialError::Missing(_))), "a key belongs to its provider");
    let one_run = ApiKey::new(KEY).unwrap();
    assert_eq!(key_for(&store, Some(&one_run), AiProviderKind::Anthropic).unwrap().expose(), KEY);
    assert_eq!(store.load("anthropic").unwrap().unwrap().expose(), "stored-key", "the key of one run is never saved");
    // Without a keyring the key of one run still works, and the stored one fails closed.
    let none = MemoryCredentialStore::unavailable();
    assert_eq!(key_for(&none, Some(&one_run), AiProviderKind::Anthropic).unwrap().expose(), KEY);
    assert!(matches!(key_for(&none, None, AiProviderKind::Anthropic), Err(CredentialError::Unavailable(_))));
    assert!(matches!(none.save("anthropic", &one_run), Err(CredentialError::Unavailable(_))));
}

#[test]
fn a_key_is_checked_and_never_printed() {
    for bad in ["", "  ", "a\nb", "a\u{0}b", "kéy"] {
        assert!(matches!(ApiKey::new(bad), Err(CredentialError::Invalid(_))), "{bad:?}");
    }
    assert!(ApiKey::new(&"k".repeat(AiClient::MAXIMUM_KEY_LENGTH + 1)).is_err());
    let key = ApiKey::new(KEY).unwrap();
    assert!(!format!("{key:?} {:?} {:#?}", Some(&key), vec![key.clone()]).contains("SECRET"));
    for error in [CredentialError::Invalid("x".into()), ApiKey::new("a\nb").unwrap_err()] {
        assert!(!format!("{error} {error:?}").contains("a\nb"));
    }
}

/// Records what a model was sent, and answers one turn.
#[derive(Clone, Default)]
struct Recording(Arc<Mutex<Vec<AiHttpRequest>>>);

impl AiTransport for Recording {
    fn execute(&self, request: &AiHttpRequest, _: &AiCancellation) -> Result<AiHttpResponse, AiClientError> {
        self.0.lock().unwrap().push(request.clone());
        let text = reply("Made a clock.", "$render(<vstack/>)", None);
        Ok(AiHttpResponse::new(200, serde_json::json!({ "content": [{ "type": "text", "text": text }], "usage": { "input_tokens": 9, "output_tokens": 4 } }).to_string()))
    }
}

/// The key is used for a whole turn and afterwards is in none of the files the turn leaves:
/// the profile, the conversation, and nothing else in the data folder.
#[test]
fn a_saved_profile_and_a_saved_conversation_contain_no_key() {
    let folder = temporary_directory("ai-no-key-on-disk");
    let paths = sw_core::DataPaths::new(Some(&folder)).unwrap();
    let credentials = MemoryCredentialStore::new();
    credentials.save("anthropic", &ApiKey::new(KEY).unwrap()).unwrap();

    let profiles = AiProfileStore::new(paths.ai_profile());
    assert_eq!(profiles.load(), None);
    let settings = AiSettings::new(AiProfile::new(AiProviderKind::Anthropic, " https://api.anthropic.com/v1/ ", " claude-fable-5-2 "));
    profiles.save(&settings).unwrap();
    let saved = profiles.load().unwrap();
    assert_eq!((saved.profile.base_url.as_str(), saved.profile.model.as_str()), ("https://api.anthropic.com", "claude-fable-5-2"));

    let transport = Recording::default();
    let client = AiClient::new(transport.clone());
    let key = key_for(&credentials, None, saved.profile.kind).unwrap();
    let chat = client.bind(saved.clone(), key.expose());
    let mut conversation = AiConversation::new(now_milliseconds());
    let turn = turn(&mut conversation, "a clock", &chat, |_, _| ok());
    assert_eq!(turn.status, Status::Succeeded);
    let store = AiConversationStore::new(paths.ai_conversations());
    assert!(store.save(&conversation));

    // The key did travel: in the header of the request, and only there.
    let sent = transport.0.lock().unwrap().remove(0);
    assert_eq!(sent.header("x-api-key"), Some(KEY));
    assert!(!String::from_utf8_lossy(sent.body.as_deref().unwrap()).contains(KEY) && !sent.url.contains(KEY));

    fn files(folder: &Path, found: &mut Vec<PathBuf>) {
        for entry in std::fs::read_dir(folder).unwrap().flatten() {
            if entry.path().is_dir() { files(&entry.path(), found) } else { found.push(entry.path()) }
        }
    }
    let mut found = Vec::new();
    files(&folder, &mut found);
    let names: Vec<String> = found.iter().map(|file| file.strip_prefix(&folder).unwrap().display().to_string()).collect();
    assert_eq!(names.len(), 2, "{names:?}");
    assert!(names.contains(&"ai-profile.json".to_owned()) && names.iter().any(|name| name.starts_with("AiConversations/")), "{names:?}");
    for file in &found {
        let text = std::fs::read_to_string(file).unwrap();
        assert!(!text.contains(KEY) && !text.to_lowercase().contains("apikey") && !text.contains("x-api-key") && !text.contains("Bearer"), "{}", file.display());
        assert_eq!(std::fs::metadata(file).unwrap().permissions().mode() & 0o777, 0o600, "{}", file.display());
    }
    // The profile file has exactly the members this code writes.
    let profile: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(paths.ai_profile()).unwrap()).unwrap();
    assert_eq!(profile.as_object().unwrap().keys().map(String::as_str).collect::<Vec<_>>(), ["formatVersion", "provider", "baseUrl", "model", "maxIterations", "temperature"]);
}

#[test]
fn the_profile_file_never_takes_a_key_and_fails_closed() {
    let folder = temporary_directory("ai-profile-store");
    let store = AiProfileStore::new(folder.join("nested/ai-profile.json"));
    assert_eq!(store.load(), None);
    assert_eq!(store.load_or_default().profile, AiProfile::defaults(AiProviderKind::Anthropic));
    // A base URL that carries a credential or a query is refused before anything is written.
    for url in [format!("https://user:{KEY}@api.example.com"), format!("https://api.example.com?key={KEY}"), "http://localhost:11434".to_owned(), String::new()] {
        let error = store.save(&AiSettings::new(AiProfile::new(AiProviderKind::OpenAiCompatible, url.clone(), "m"))).unwrap_err();
        assert!(!error.to_string().contains(KEY), "{error}");
        assert!(!store.file().exists(), "{url}");
    }
    let settings = AiSettings { max_iterations: 500, temperature: 9.0, ..AiSettings::new(AiProfile::new(AiProviderKind::OpenAiCompatible, "https://ollama.lan:8443/v1", "llama3")) };
    store.save(&settings).unwrap();
    let saved = store.load().unwrap();
    assert_eq!(saved.profile, AiProfile::new(AiProviderKind::OpenAiCompatible, "https://ollama.lan:8443", "llama3"));
    assert_eq!((saved.max_iterations, saved.temperature), (AiSettings::MAXIMUM_MAX_ITERATIONS, AiSettings::DEFAULT_TEMPERATURE));
    assert_eq!(std::fs::read_dir(store.file().parent().unwrap()).unwrap().count(), 1, "no temporary file is left");

    // A member this code does not know (someone added a key by hand) is not kept by the next save.
    std::fs::write(store.file(), format!(r#"{{"formatVersion":1,"provider":"openai","baseUrl":"https://api.openai.com","model":"gpt-4o-mini","apiKey":"{KEY}"}}"#)).unwrap();
    let read = store.load().unwrap();
    assert!(!format!("{read:?}").contains(KEY));
    store.save(&read).unwrap();
    assert!(!std::fs::read_to_string(store.file()).unwrap().contains(KEY));

    // What is not a profile this code wrote is not guessed from.
    for text in ["", "{", "[]", r#"{"formatVersion":2,"provider":"openai","baseUrl":"https://api.openai.com","model":"m"}"#, r#"{"formatVersion":1,"provider":"oauth","baseUrl":"https://x.example.com","model":"m"}"#, r#"{"formatVersion":1,"provider":"openai","baseUrl":5,"model":"m"}"#, r#"{"formatVersion":1,"provider":"openai","baseUrl":"https://api.openai.com"}"#] {
        std::fs::write(store.file(), text).unwrap();
        assert_eq!(store.load(), None, "{text}");
    }
    // A link in the place of the file is neither read nor written through.
    let outside = folder.join("outside.json");
    let elsewhere = r#"{"formatVersion":1,"provider":"openai","baseUrl":"https://api.openai.com","model":"m"}"#;
    std::fs::write(&outside, elsewhere).unwrap();
    std::fs::remove_file(store.file()).unwrap();
    std::os::unix::fs::symlink(&outside, store.file()).unwrap();
    assert_eq!(store.load(), None);
    store.save(&settings).unwrap();
    assert_eq!(std::fs::read_to_string(&outside).unwrap(), elsewhere, "the file the link pointed at is as it was");
    assert_eq!(store.load().map(|saved| saved.profile.model), Some("llama3".to_owned()));
    assert!(std::fs::symlink_metadata(store.file()).unwrap().is_file(), "the link was replaced by a file of our own");
}
