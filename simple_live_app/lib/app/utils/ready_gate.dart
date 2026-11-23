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

/// 1.08.87（ISS-317）：就绪门 `_playIssued` 的**等价补位**判定（纯逻辑，便于单测）。
///
/// 背景：换线路 / 出错重试走 `player.jump()` 时，media_kit 的 `playing` 流**不重发 true**
///（播放器状态从未变 false）→ `_playIssued` 恒 false → `readyGateCanFinish` 只能等 6s 超时
///（真机 2026-11-22 11:41:25→31 实证）。而「restart 完成 ∧ 播放器在播」即「play 已生效」的
/// **等价事实**，可作补位依据。
///
/// **窄口径**（防回归）：仅对**换线路/重试武装的门**（`fromSwitch`）生效——进房（首开）路径
/// 零改动，保住「防进房期热拨 VSR/seek 被误判就绪」那道闸（见上方背景第二条）。
bool readyGateCanBackfillPlayIssued({
  required bool pending,
  required bool fromSwitch,
  required bool playing,
}) =>
    pending && fromSwitch && playing;
