/// C3 R3 ⑤（批次 B / 1.08.84）：VSR「终态显示比 / 由其派生的面板几何」写入的
/// **校正器守卫**（纯逻辑，无副作用，便于单测）。
///
/// 背景（v3.3 ISS-294 P1-2）：应用级校正器一旦按**实测** dw/dh 比写过 `_vsrDisplayAspect`
/// （`_vsrCorrectorFired`），随后的尺寸/布局事件（W3/W4/W5）不得再用**假说比**
/// （按源尺寸推导）把它冲回——否则刚校正的面板宽被打回假说值 → 房 B 黑边复现；
/// 保持实测比直到代际重置（`_resetLastVoutDwh`）。锁只在「链已挂」时有意义：
/// VSR 关（链未挂/已摘）时 `_vsrDisplayAspect` 必须能正常置 null / 由假说比预写
/// （toggle 路径），故合取式为「fired ∧ 链已挂」才锁。
///
/// 抽出动机（§11.3 N6 / §11.4 ⑤ / §11.6 C-5）：该守卫**合取式**在全仓仅两个调用点
/// （`player_controller.dart` 的 `_syncRtxVsrCrop` 显示比缓存路径、
/// `_applyRtxVsrSetting` toggle Rx 预写路径），且都在 `PlayerController` 内——
/// `test/` 下无法对 PlayerController 建单测（需 Flutter binding + media_kit
/// native assets）⇒ 按仓内惯例（`vsr_replay_policy.dart` 纯函数下沉 utils）
/// 才可测。**语义等价、零行为变**（原式 `!(fired && applied)` 直译）；
/// 禁快照字段、禁回退分支（M4/N6）。
///
/// 本文件只依赖 dart:core，可脱离 Flutter 环境 `dart run` 实跑。
library;

/// 是否允许写入「VSR 终态显示比 / 由其派生的面板几何」。
///
/// - [correctorFired]：应用级校正器是否已按实测比写过显示比（`_vsrCorrectorFired`）。
/// - [chainApplied]：VSR 滤镜链当前是否已挂（`_rtxVsrChainApplied`）。
///
/// 返回 `false` = **锁住**（校正器已 fired ∧ 链已挂）⇒ 保持实测比直到代际重置；
/// 返回 `true` = 放行写入（未 fired，或链未挂/已摘）。
bool vsrDisplayAspectWritable({
  required bool correctorFired,
  required bool chainApplied,
}) =>
    !(correctorFired && chainApplied);
