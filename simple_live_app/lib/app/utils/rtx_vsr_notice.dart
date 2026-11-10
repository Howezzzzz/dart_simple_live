import 'package:simple_live_app/app/utils.dart';

/// 开启 NVIDIA RTX VSR 前的须知弹窗（设置页与直播间共用，避免文案漂移）。
///
/// 返回用户是否确认开启（仅在「开」方向调用；「关」是纯降风险动作，不弹窗）。
Future<bool> showRtxVsrConfirmDialog() {
  return Utils.showAlertDialog(
    "开启前请注意以下事项与硬件要求：\n\n"
    "1. 硬件限制：支持 NVIDIA GeForce RTX 20 / 30 / 40 系列及更新显卡，显卡驱动版本需在 545.84 以上。旧款 GTX 系列不受支持。\n\n"
    "2. 前置配置：开启前必须在【NVIDIA 控制面板】或【NVIDIA App】中开启【RTX 视频增强 - 超分辨率 (RTX Video Enhancements - Super Resolution)】。\n\n"
    "3. 功耗说明：开启后播放低分辨率直播流时将占用显卡 Tensor Core，显卡功耗与发热量会有所增加（可根据需要调整超分等级，建议 1~2 级或自动）。\n\n"
    "4. 自动处理：当直播源原生分辨率等于或大于显示分辨率时（如 4K 屏播放 4K 直播），显卡驱动会自动 Pass-through（跳过超分），不会二次放大。",
    title: "NVIDIA RTX VSR 功能说明",
    confirm: "确认开启",
  );
}
