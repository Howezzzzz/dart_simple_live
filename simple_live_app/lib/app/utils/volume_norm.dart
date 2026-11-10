// 音量均衡（跨直播间响度一致性）的滤镜链定义与纯逻辑（便于单测）。
//
// 背景（2026-11-10 实测，见 文件/Slive/文档/音量均衡-方案调研-20261110.md）：
// 用户反馈「进入不同直播间、同样音量设置下声音大小仍不一样」。用 8 个合成房间
// （重压缩 / 大动态 / 安静人声 / 人声+巨大游戏音 / 低音重 / 极安静 / 长时段漂移 /
// 安静有爆音）对多个候选链路做客观测量（跨房间整体 LUFS 与短时响度 S(3s) 离散、
// 输出 LRA、起步收敛），结论：
//   ① 旧的单级 `loudnorm=I=-16:TP=-1.5:LRA=11` 在常规房间上已很稳，但「安静但偶发
//      爆音 / 宽 crest」的源被 TP=-1.5 的峰值约束顶住，只做到 −22.9（目标 −16）；
//   ② 「测一次定死增益」（ReplayGain 式）短时响度反而更差（离散 23 LU），不适用；
//   ③ 两段「先 dynaudnorm 轻压、再 loudnorm 定标准」最好；参数取「轻快低泵动」一档
//      （f=250/g=15/m=8/r=0.5）优于更重的一档（f=400/g=31/m=4/r=0.2）：
//      跨房间离散 7.1/11.2 → 2.2/2.7 LU，失效房间 −22.9 → −17.8。
//
// ⚠️ 顺序不可反：dynaudnorm 必须在前（先压动态、再定标准）；反了两级会互相打架。
// ⚠️ 这两个滤镜都已编入自建 libmpv（Windows / Android），换用无需重新构建；
//    上游原版 `--disable-filters` 后只有 overlay/equalizer，任何音频滤镜都没有
//    → 探测会失败并自动置灰开关（不崩、不静默）。
// ⚠️ 真峰与延迟：loudnorm 内部升采样到 192k 测真峰（低端 Android 需实测 CPU）；
//    滤镜链延迟由 libavfilter 上报、mpv 自动补偿音画同步，**不要**手调 `audio-delay`。

/// 前级：动态音频归一化（轻压；只削爆音峰、尽量少泵动）。
const String volumeNormPreFilter = 'dynaudnorm=f=250:g=15:p=0.95:m=8:r=0.5';

/// 后级：EBU R128 目标响度（LRA 收紧到 5，输出动态更齐）。
const String volumeNormPostFilter = 'loudnorm=I=-16:TP=-1.5:LRA=5';

/// 完整 `af` 链（顺序不可反：先压后定标）。
const String volumeNormFilter = '$volumeNormPreFilter,$volumeNormPostFilter';

/// 回读 `af` 属性判定「整条链已生效」：两个滤镜都在才算支持。
///
/// 只查 `loudnorm` 是不严的——只编了 loudnorm 的旧产物会把「链没挂全」误判成支持，
/// 结果是前级静默缺失、听感与实测不一致。
bool volumeNormSupportedFromReadback(String readback) =>
    readback.contains('dynaudnorm') && readback.contains('loudnorm');

/// mpv / libavfilter 报出的「滤镜链没挂上」关键字（静默降级防线）。
///
/// 回读校验是主门禁；这里只兜「参数写错导致链创建失败但属性被接受」这类边角情况。
const List<String> volumeNormFilterErrorKeywords = <String>[
  'cannot find filter',
  'no such filter',
  'unknown filter',
  'failed to create filter',
  'cannot initialize a filter',
];

/// 日志行是否表明滤镜链失败（大小写不敏感）。
bool volumeNormLogIndicatesFailure(String line) {
  final lower = line.toLowerCase();
  return volumeNormFilterErrorKeywords.any(lower.contains);
}

/// 是否需要把链挂上：用户开启且能力「已知支持」。
bool volumeNormShouldApply({required bool userOn, required bool? supported}) =>
    userOn && supported == true;

/// 起流前是否需要预挂链：用户开启且能力「不是已知不支持」。
///
/// 能力未知（null）时也先挂：mpv 会拒绝非法滤镜（不生效，无副作用），随后首帧回读
/// 校验兜底；换来的是「进房第一帧就有均衡」——消除旧的「首帧后才挂」造成的 1–3s
/// 未处理窗（复核整合结论）。
bool volumeNormShouldPreApply({required bool userOn, required bool? supported}) =>
    userOn && supported != false;
