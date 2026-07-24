use super::*;

#[tokio::test]
async fn wait_for_activity_returns_steered_when_input_arrives_during_a_wait() {
    let (activity_tx, mut activity_rx) = tokio::sync::watch::channel(InputQueueActivity::Mailbox);
    let wait_task = tokio::spawn(async move {
        wait_for_activity(
            &mut activity_rx,
            /*pending_activity*/ None,
            Instant::now() + Duration::from_secs(/*secs*/ 1),
        )
        .await
    });
    tokio::task::yield_now().await;

    activity_tx.send_replace(InputQueueActivity::Steer);

    assert_eq!(
        wait_task.await.expect("wait task should join"),
        WaitOutcome::Steered
    );
}
