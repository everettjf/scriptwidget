//! The Skills page without the window: what is listed, and what its buttons
//! do. `Android/app/.../ui/SkillsScreen.kt` is what it follows; the store is
//! [`sw_core::skills`].
//!
//! A Skill is two text files. The window shows its instructions as text and
//! does nothing else with them: a Skill that is turned on adds that text to
//! AI requests, and one that was just imported is not turned on.

use std::path::Path;
use std::sync::Arc;

use sw_core::skills::{Skill, SkillError, validator};

use crate::model::{Studio, StudioError, write_atomically};

impl From<SkillError> for StudioError {
    fn from(error: SkillError) -> Self {
        Self(error.message)
    }
}

/// One Skill as the page lists it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SkillRow {
    pub id: String,
    pub title: String,
    pub version: String,
    pub summary: String,
    pub author: Option<String>,
    pub tags: Vec<String>,
    /// The text that is added to AI requests while the Skill is on.
    pub instruction: String,
    /// Shipped with the program: it can be turned on and exported, not removed.
    pub built_in: bool,
    pub enabled: bool,
}

pub struct Skills {
    studio: Arc<Studio>,
}

impl Skills {
    pub fn new(studio: Arc<Studio>) -> Self {
        Self { studio }
    }

    /// The Skills shipped with the program, then the imported ones by title.
    pub fn rows(&self) -> Vec<SkillRow> {
        let store = self.studio.skill_store();
        let enabled = store.enabled_ids();
        store.list().into_iter().map(|skill| row(skill, |id| enabled.contains(id))).collect()
    }

    /// The titles of the Skills that are on, in the order their text is added.
    pub fn in_effect(&self) -> Vec<String> {
        self.studio.skill_store().enabled_skills().into_iter().map(|skill| skill.title).collect()
    }

    pub fn set_enabled(&self, id: &str, enabled: bool) -> Result<(), StudioError> {
        Ok(self.studio.skill_store().set_enabled(id, enabled)?)
    }

    /// Imports a `.swskill` archive, or a folder that holds `skill.json` and
    /// `SKILL.md`. Nothing is replaced, and the imported Skill is not turned on.
    pub fn import(&self, source: &Path) -> Result<SkillRow, StudioError> {
        let store = self.studio.skill_store();
        let metadata = std::fs::symlink_metadata(source).map_err(|error| StudioError(format!("{}: {error}", source.display())))?;
        let skill = if metadata.is_dir() {
            store.import_directory(source)?
        } else {
            let mut file = std::fs::File::open(source).ok().filter(|file| file.metadata().is_ok_and(|metadata| metadata.is_file())).ok_or_else(|| StudioError(format!("{} is not a file.", source.display())))?;
            store.import_archive(&mut file)?
        };
        Ok(row(skill, |_| false))
    }

    /// The file name an export suggests: the title as a plain name.
    pub fn export_name(title: &str) -> String {
        format!("{}.swskill", validator::slug(title))
    }

    /// Writes a Skill as a `.swskill` archive, through a private temporary file beside `target`.
    pub fn export(&self, id: &str, target: &Path) -> Result<(), StudioError> {
        let archive = self.studio.skill_store().export_archive(id)?;
        write_atomically(target, &archive, 0o644)?;
        Ok(())
    }

    /// Deletes an imported Skill; it is no longer on afterwards.
    pub fn remove(&self, id: &str) -> Result<(), StudioError> {
        Ok(self.studio.skill_store().delete(id)?)
    }
}

fn row(skill: Skill, enabled: impl Fn(&str) -> bool) -> SkillRow {
    SkillRow { enabled: enabled(&skill.id), id: skill.id, title: skill.title, version: skill.version, summary: skill.summary, author: skill.author, tags: skill.tags, instruction: skill.instruction, built_in: skill.is_built_in }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::{Scratch, studio, zip};

    const MANIFEST: &str = r#"{"formatVersion":1,"id":"com.example.brief","name":"Be Brief","version":"1.2.0","summary":"Short labels.","symbol":"text.alignleft","promptFile":"SKILL.md","tags":["style"],"author":"Ada","minimumRuntimeVersion":"1.0"}"#;
    const INSTRUCTION: &str = "Use at most three words per label.\nNo decorative text.";

    fn skills(scratch: &Scratch) -> Skills {
        Skills::new(Arc::new(studio(scratch)))
    }

    #[test]
    fn the_shipped_skills_are_listed_and_none_is_on() {
        let scratch = Scratch::new("skills-list");
        let skills = skills(&scratch);
        let rows = skills.rows();
        assert_eq!(rows.len(), 5);
        assert!(rows.iter().all(|row| row.built_in && !row.enabled && !row.instruction.is_empty()));
        assert!(skills.in_effect().is_empty());
        assert!(!scratch.path("data/Skills").exists(), "looking writes nothing");
    }

    #[test]
    fn a_skill_is_imported_turned_on_exported_and_removed() {
        let scratch = Scratch::new("skills-life");
        let skills = skills(&scratch);
        let archive = scratch.write("in/brief.swskill", &zip(&[("skill.json", MANIFEST), ("SKILL.md", INSTRUCTION)]));
        let imported = skills.import(&archive).unwrap();
        assert_eq!((imported.id.as_str(), imported.title.as_str(), imported.author.as_deref(), imported.enabled, imported.built_in), ("com.example.brief", "Be Brief", Some("Ada"), false, false));
        assert_eq!(imported.instruction, INSTRUCTION);
        assert_eq!(skills.rows().last(), Some(&imported), "imported Skills come after the shipped ones");
        assert!(skills.import(&archive).unwrap_err().0.contains("already installed"));

        skills.set_enabled("com.example.brief", true).unwrap();
        skills.set_enabled("visual-polish", true).unwrap();
        assert_eq!(skills.in_effect(), ["Visual Polish", "Be Brief"]);
        assert!(skills.rows().iter().filter(|row| row.enabled).count() == 2);
        assert!(skills.set_enabled("com.example.missing", true).is_err());
        skills.set_enabled("visual-polish", false).unwrap();

        // Exported, the archive is what another user imports; a folder works as well.
        assert_eq!(Skills::export_name("Be Brief"), "be-brief.swskill");
        assert_eq!(Skills::export_name("../../etc/passwd"), "etc-passwd.swskill");
        let exported = scratch.path("out/be-brief.swskill");
        std::fs::create_dir_all(exported.parent().unwrap()).unwrap();
        skills.export("com.example.brief", &exported).unwrap();
        let other = Scratch::new("skills-other");
        let received = Skills::new(Arc::new(studio(&other)));
        assert_eq!(received.import(&exported).unwrap(), imported);
        let third = Scratch::new("skills-folder");
        third.write("in/brief/skill.json", MANIFEST.as_bytes());
        third.write("in/brief/SKILL.md", INSTRUCTION.as_bytes());
        assert_eq!(Skills::new(Arc::new(studio(&third))).import(&third.path("in/brief")).unwrap(), imported);

        skills.remove("com.example.brief").unwrap();
        assert_eq!(skills.rows().len(), 5);
        assert!(skills.in_effect().is_empty(), "a removed Skill is no longer on");
        assert!(skills.remove("visual-polish").unwrap_err().0.contains("Built-in"));
        assert!(skills.remove("com.example.brief").is_err());
    }

    #[test]
    fn what_is_not_a_skill_is_refused_and_nothing_is_stored() {
        let scratch = Scratch::new("skills-refused");
        let skills = skills(&scratch);
        let with_tools = MANIFEST.replacen('{', "{\"tools\":[\"shell\"],", 1);
        let refused: [(&str, Vec<u8>, &str); 5] = [
            ("payload.swskill", zip(&[("skill.json", MANIFEST), ("SKILL.md", INSTRUCTION), ("run.sh", "#!/bin/sh")]), "only skill.json and SKILL.md"),
            ("escape.swskill", zip(&[("skill.json", MANIFEST), ("SKILL.md", INSTRUCTION), ("../escape.md", "x")]), "rejected"),
            ("tools.swskill", zip(&[("skill.json", &with_tools), ("SKILL.md", INSTRUCTION)]), "unknown fields: tools"),
            ("blank.swskill", zip(&[("skill.json", MANIFEST), ("SKILL.md", "  \n")]), "must contain instructions"),
            ("text.swskill", b"not an archive".to_vec(), "rejected"),
        ];
        for (name, bytes, reason) in refused {
            let file = scratch.write(&format!("in/{name}"), &bytes);
            let error = skills.import(&file).unwrap_err();
            assert!(error.0.contains(reason), "{name}: {}", error.0);
        }
        assert!(skills.import(&scratch.path("in/absent.swskill")).is_err());
        assert_eq!(skills.rows().len(), 5);
        assert!(std::fs::read_dir(scratch.path("data/Skills")).map_or(true, |mut entries| entries.next().is_none()), "nothing was stored");
        assert!(!scratch.path("escape.md").exists() && !scratch.path("in/escape.md").exists() && !scratch.path("data/escape.md").exists());
    }
}
