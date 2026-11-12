/// 起播就绪门判定（纯逻辑，便于单测）。
///
/// ready ＝ 门控在途 ∧ play 已发出 ∧ 已见「restart 完成」 ∧ 无在途管线写入。
///
/// 背景（方案 §三 B1；阶段4 复核 B/C）：
/// - 缺「play 已发」→ 进房 6s 内热拨 VSR / seek 触发的 restart 会被误判成「进房就绪」提前放门；
/// - 缺「无在途写入」→ 写链还没落地就露画面；
/// - 三条件必须在**每次前置条件变化时**复检（restart 到达 / play 发出 / 写链完成），
///   否则「restart 到时仍在写链」会永不复检、只能等 6s 超时并误报网络慢。
bool readyGateCanFinish({
  required bool pending,
  required bool playIssued,
  required bool restartSeen,
  required int pipelineBusy,
}) =>
    pending && playIssued && restartSeen && pipelineBusy <= 0;
