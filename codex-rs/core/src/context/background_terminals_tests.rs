use super::*;

#[test]
fn renders_running_and_completed_terminals() {
    let terminals = BackgroundTerminals::new(vec![
        BackgroundTerminalContext {
            process_id: 61326,
            command: "sleep 731".to_string(),
            status: BackgroundTerminalStatus::CompletedWaitingToBeReaped,
            wake_on_exit: true,
        },
        BackgroundTerminalContext {
            process_id: 48102,
            command: "scripts/build-codex-docker.sh --all-tests".to_string(),
            status: BackgroundTerminalStatus::Running,
            wake_on_exit: false,
        },
    ])
    .expect("terminals should render context");

    assert_eq!(
        terminals.render(),
        r#"<background_terminals>
  <terminal session_id="48102" status="running" wake_on_exit="false" command="scripts/build-codex-docker.sh --all-tests" />
  <terminal session_id="61326" status="completed_waiting_to_be_reaped" wake_on_exit="true" command="sleep 731" />
</background_terminals>"#,
    );
}

#[test]
fn truncates_and_escapes_terminal_commands() {
    let terminals = BackgroundTerminals::new(vec![BackgroundTerminalContext {
        process_id: 1,
        command: format!("<{}", "x".repeat(50)),
        status: BackgroundTerminalStatus::Running,
        wake_on_exit: true,
    }])
    .expect("terminal should render context");

    assert_eq!(
        terminals.render(),
        r#"<background_terminals>
  <terminal session_id="1" status="running" wake_on_exit="true" command="&lt;xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx…" />
</background_terminals>"#,
    );
}

#[test]
fn limits_rendered_terminals() {
    let terminals = BackgroundTerminals::new(
        (1..=6)
            .map(|process_id| BackgroundTerminalContext {
                process_id,
                command: format!("command-{process_id}"),
                status: BackgroundTerminalStatus::Running,
                wake_on_exit: false,
            })
            .collect(),
    )
    .expect("terminals should render context");

    assert_eq!(
        terminals.render(),
        r#"<background_terminals>
  <terminal session_id="1" status="running" wake_on_exit="false" command="command-1" />
  <terminal session_id="2" status="running" wake_on_exit="false" command="command-2" />
  <terminal session_id="3" status="running" wake_on_exit="false" command="command-3" />
  <terminal session_id="4" status="running" wake_on_exit="false" command="command-4" />
  <terminal session_id="5" status="running" wake_on_exit="false" command="command-5" />
  <additional_terminal_count>1</additional_terminal_count>
</background_terminals>"#,
    );
}
