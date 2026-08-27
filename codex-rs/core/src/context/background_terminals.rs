use super::ContextualUserFragment;
use crate::context::environment_context::push_xml_escaped_text;
use crate::unified_exec::BackgroundTerminalContext;
use crate::unified_exec::BackgroundTerminalStatus;
use codex_protocol::models::ContentItemKind;

const MAX_BACKGROUND_TERMINALS: usize = 5;
const MAX_COMMAND_CHARS: usize = 50;

/// A snapshot of terminal sessions that can be collected with `write_stdin`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct BackgroundTerminals {
    terminals: Vec<BackgroundTerminalContext>,
    omitted_terminal_count: usize,
}

impl BackgroundTerminals {
    pub(crate) fn new(mut terminals: Vec<BackgroundTerminalContext>) -> Option<Self> {
        if terminals.is_empty() {
            return None;
        }
        terminals.sort_by_key(|terminal| terminal.process_id);
        let omitted_terminal_count = terminals.len().saturating_sub(MAX_BACKGROUND_TERMINALS);
        terminals.truncate(MAX_BACKGROUND_TERMINALS);
        Some(Self {
            terminals,
            omitted_terminal_count,
        })
    }
}

impl ContextualUserFragment for BackgroundTerminals {
    fn content_kind(&self) -> ContentItemKind {
        ContentItemKind("unified_exec.background_terminals".to_string())
    }

    fn role(&self) -> &'static str {
        "user"
    }

    fn markers(&self) -> (&'static str, &'static str) {
        Self::type_markers()
    }

    fn type_markers() -> (&'static str, &'static str) {
        ("<background_terminals>", "</background_terminals>")
    }

    fn body(&self) -> String {
        let mut rendered = "\n".to_string();
        for terminal in &self.terminals {
            rendered.push_str("  <terminal session_id=\"");
            rendered.push_str(&terminal.process_id.to_string());
            rendered.push_str("\" status=\"");
            rendered.push_str(match terminal.status {
                BackgroundTerminalStatus::Running => "running",
                BackgroundTerminalStatus::CompletedWaitingToBeReaped => {
                    "completed_waiting_to_be_reaped"
                }
            });
            rendered.push_str("\" wake_on_exit=\"");
            rendered.push_str(if terminal.wake_on_exit { "true" } else { "false" });
            rendered.push_str("\" command=\"");
            push_xml_escaped_text(&mut rendered, &truncate_command(&terminal.command));
            rendered.push_str("\" />\n");
        }
        if self.omitted_terminal_count > 0 {
            rendered.push_str("  <additional_terminal_count>");
            rendered.push_str(&self.omitted_terminal_count.to_string());
            rendered.push_str("</additional_terminal_count>\n");
        }
        rendered
    }
}

fn truncate_command(command: &str) -> String {
    let mut characters = command.chars();
    let truncated = characters.by_ref().take(MAX_COMMAND_CHARS).collect::<String>();
    if characters.next().is_some() {
        format!("{truncated}…")
    } else {
        truncated
    }
}

#[cfg(test)]
#[path = "background_terminals_tests.rs"]
mod tests;
