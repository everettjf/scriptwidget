//! A small hand-written argument parser: `--name value`, `--name=value`,
//! `--flag`, positional arguments, and `--` to end the options. Each command
//! names the options it takes; anything else is a usage error, so a typing
//! mistake is never silently ignored.

use std::collections::HashMap;

use crate::report::Failure;

/// What one command accepts.
pub struct Shape {
    /// Options that take a value, without the dashes.
    pub values: &'static [&'static str],
    /// Options that take none.
    pub flags: &'static [&'static str],
    pub minimum_positionals: usize,
    pub maximum_positionals: usize,
    /// What the positional arguments are, for the message when one is missing or extra.
    pub positionals: &'static str,
}

#[derive(Debug, Default)]
pub struct Arguments {
    values: HashMap<&'static str, String>,
    flags: Vec<&'static str>,
    positionals: Vec<String>,
}

/// `--format json` is accepted by every command, as the Mac command line
/// takes it; JSON is the only format here.
const FORMAT: &str = "format";

impl Arguments {
    pub fn parse(arguments: &[String], shape: &Shape) -> Result<Self, Failure> {
        let mut parsed = Self::default();
        let mut options_ended = false;
        let mut index = 0;
        while index < arguments.len() {
            let argument = &arguments[index];
            index += 1;
            if options_ended || !argument.starts_with("--") {
                // A negative number is a value (`move <id> <screen> -20 40`), not an option.
                let negative_number = argument.len() > 1 && argument[1..].bytes().all(|byte| byte.is_ascii_digit() || byte == b'.') && argument.as_bytes()[1].is_ascii_digit();
                if !options_ended && argument.len() > 1 && argument.starts_with('-') && !negative_number {
                    return Err(Failure::usage(format!("Unknown option {argument}")));
                }
                parsed.positionals.push(argument.clone());
                continue;
            }
            if argument == "--" {
                options_ended = true;
                continue;
            }
            let (name, inline) = match argument[2..].split_once('=') {
                Some((name, value)) => (name, Some(value.to_owned())),
                None => (&argument[2..], None),
            };
            if let Some(flag) = shape.flags.iter().find(|flag| **flag == name) {
                if inline.is_some() {
                    return Err(Failure::usage(format!("--{name} takes no value")));
                }
                if !parsed.flags.contains(flag) {
                    parsed.flags.push(flag);
                }
                continue;
            }
            let Some(known) = shape.values.iter().copied().chain([FORMAT]).find(|value| *value == name) else {
                return Err(Failure::usage(format!("Unknown option --{name}")));
            };
            let value = match inline {
                Some(value) => value,
                None => {
                    let value = arguments.get(index).ok_or_else(|| Failure::usage(format!("--{name} needs a value")))?;
                    index += 1;
                    value.clone()
                }
            };
            if parsed.values.insert(known, value).is_some() {
                return Err(Failure::usage(format!("--{name} was given twice")));
            }
        }
        if parsed.positionals.len() < shape.minimum_positionals {
            return Err(Failure::usage(format!("Missing {}", shape.positionals)));
        }
        if parsed.positionals.len() > shape.maximum_positionals {
            return Err(Failure::usage(if shape.maximum_positionals == 0 { "This command takes no arguments".to_owned() } else { format!("Too many arguments: expected {}", shape.positionals) }));
        }
        if parsed.value(FORMAT).is_some_and(|format| format != "json") {
            return Err(Failure::usage("--format must be json: reports are always JSON"));
        }
        Ok(parsed)
    }

    pub fn value(&self, name: &str) -> Option<&str> {
        self.values.get(name).map(String::as_str)
    }

    pub fn flag(&self, name: &str) -> bool {
        self.flags.contains(&name)
    }

    pub fn positional(&self, index: usize) -> Option<&str> {
        self.positionals.get(index).map(String::as_str)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SHAPE: Shape = Shape { values: &["family", "output"], flags: &["dark"], minimum_positionals: 1, maximum_positionals: 2, positionals: "a package folder" };

    fn parse(arguments: &[&str]) -> Result<Arguments, Failure> {
        Arguments::parse(&arguments.iter().map(|text| text.to_string()).collect::<Vec<_>>(), &SHAPE)
    }

    #[test]
    fn reads_values_flags_and_positionals_in_any_order() {
        let parsed = parse(&["--family", "large", "pkg", "--dark", "--output=a=b.png", "second"]).unwrap();
        assert_eq!(parsed.value("family"), Some("large"));
        assert_eq!(parsed.value("output"), Some("a=b.png"));
        assert!(parsed.flag("dark"));
        assert_eq!((parsed.positional(0), parsed.positional(1), parsed.positional(2)), (Some("pkg"), Some("second"), None));
    }

    #[test]
    fn a_double_dash_ends_the_options() {
        let parsed = parse(&["--", "--dark", "-x"]).unwrap();
        assert!(!parsed.flag("dark"));
        assert_eq!((parsed.positional(0), parsed.positional(1)), (Some("--dark"), Some("-x")));
    }

    #[test]
    fn mistakes_are_usage_errors() {
        for arguments in [
            &["pkg", "--unknown", "1"][..],
            &["pkg", "-f"],
            &["pkg", "--family"],
            &["pkg", "--family", "a", "--family", "b"],
            &["pkg", "--dark=yes"],
            &[],
            &["a", "b", "c"],
            &["pkg", "--format", "text"],
        ] {
            let failure = parse(arguments).expect_err(&format!("{arguments:?}"));
            assert_eq!((failure.exit, failure.code.as_str()), (crate::report::EXIT_USAGE, "usage"), "{arguments:?}");
        }
        assert!(parse(&["pkg", "--format", "json"]).is_ok());
        assert_eq!(parse(&["-"]).unwrap().positional(0), Some("-"));
        // A negative number is a value.
        let parsed = parse(&["-20", "-4.5"]).unwrap();
        assert_eq!((parsed.positional(0), parsed.positional(1)), (Some("-20"), Some("-4.5")));
        assert!(parse(&["-.5"]).is_err());
        assert!(parse(&["-2x"]).is_err());
    }
}
