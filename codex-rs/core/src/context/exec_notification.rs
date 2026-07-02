use super::ContextualUserFragment;

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct ExecNotification {
    process_id: i32,
}

impl ExecNotification {
    pub(crate) fn new(process_id: i32) -> Self {
        Self { process_id }
    }
}

impl ContextualUserFragment for ExecNotification {
    fn role(&self) -> &'static str {
        "user"
    }

    fn markers(&self) -> (&'static str, &'static str) {
        Self::type_markers()
    }

    fn type_markers() -> (&'static str, &'static str) {
        ("<exec_notification>", "</exec_notification>")
    }

    fn body(&self) -> String {
        format!(
            "\nProcess {} has completed. Call write_stdin with session_id={} and empty chars to collect final output and status.\n",
            self.process_id, self.process_id
        )
    }
}
