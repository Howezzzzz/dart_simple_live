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
// ⚠️ 滤镜已编入自建 libmpv（Windows / Android；2026-11-10 真机 P0：当时构建漏了
//    aresample → lavfi 图运行时配置失败、滤镜被 Disabling、音频直通——已重建补上）。
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
/// 回读校验是主门禁；这里兜「运行时滤镜图配置失败 / 链创建失败但属性被接受」。
/// 2026-11-10 真机 P0（ISS-276）：旧关键字只覆盖「创建期拒绝」，漏了实际形态——
/// `failed to configure the filter graph`（lavfi 图配置失败，如缺 aresample 时
/// 无格式转换桥）+ `Disabling filter ... because it has failed.`（mpv 禁用失败滤镜）。
/// 两形态已补入；`'aresample' filter not present`（prefix: ffmpeg）刻意不收——
/// 它必伴随 af 前缀的 Disabling 行（后者已命中），且 ffmpeg 前缀作用域过宽易误报。
const List<String> volumeNormFilterErrorKeywords = <String>[
  'cannot find filter',
  'no such filter',
  'unknown filter',
  'failed to create filter',
  'cannot initialize a filter',
  'failed to configure the filter graph',
  'because it has failed',
];

/// 日志行是否表明**音量均衡滤镜链**失败（大小写不敏感）。
///
/// 复核 P0-4：mpv 的滤镜错误关键字是通用措辞——VSR 重挂 vf（d3d11vpp）失败同样会命中；
/// 不限定作用域会把 VSR 故障误判成音量均衡不支持并持久化禁用。因此额外要求行内出现
/// 音量均衡音频滤镜上下文：两个滤镜名之一，或 mpv 的 af 裸前缀（行首 `af `），或
/// lavfi 前缀（`lavfi `——af 链的 lavfi 图配置失败；当前 vf 无 lavfi 滤镜，安全）。
/// 注：本防线只兜运行时失败/链创建失败；主门禁是回读校验
/// （volumeNormSupportedFromReadback，只能验证属性层，验不出运行时图构建失败）。
bool volumeNormLogIndicatesFailure(String line) {
  final lower = line.toLowerCase();
  final inAudioScope =
      lower.contains('dynaudnorm') ||
      lower.contains('loudnorm') ||
      lower.startsWith('af ') ||
      lower.startsWith('lavfi ');
  return inAudioScope && volumeNormFilterErrorKeywords.any(lower.contains);
}

/// 是否需要把链挂上：用户开启且能力「已知支持」（严格判定，==true）。
///
/// 注：与 volumeNormShouldPreApply **不同**（v2 起：后者为 !=false 宽松判定，供探测式
/// 预挂用）；本函数无生产调用点（阶段4 第3轮判为死代码），保留仅作测试锚点（决策表），
/// 生产代码直接判 `afLoudnormSupported == true`。
bool volumeNormShouldApply({required bool userOn, required bool? supported}) => userOn && supported == true;

/// 起流前是否需要预挂链：用户开启且能力「不是已知不支持」。
///
/// v2（优雅版，ISS-274）：能力未知（null）也预挂——预挂即探测（set + 回读），
/// 回读当场判定能力并持久化：支持则链已生效（**首房零等待**，RISK-69 消除）；
/// 不支持则清链并持久化 false。安全性依据：libavfilter 解析期即拒绝不存在的
/// 滤镜/非法参数（mpv 同引擎，EV-411 实证）；且判定失败路径必清链 + persist false，
/// 封死「错误能力持久化 true / 整场无声」路径（原 P0-3 的担忧场景）。
bool volumeNormShouldPreApply({required bool userOn, required bool? supported}) => userOn && supported != false;
