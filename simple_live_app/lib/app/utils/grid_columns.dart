/// 网格列数计算（纯 Dart，无 Flutter 依赖，便于单元测试）。
///
/// 背景：紧凑关注列表旧算法 `width ~/ 340`（floor）配合瀑布流「拉伸铺满」，
/// 当窗口宽略小于 (k+1)*340 时会退化为 k 列、列宽被拉到接近 2*340
/// （卡片超宽、右侧大量留白），且除数小导致列数随窗口宽微小变化就跳变，
/// 触发瀑布流整体重排、条目位置漂移。
///
/// 新算法：ceil 封顶 + 最小列宽夹逼——
/// - 列数 = ceil(width / [targetColumnWidth])，保证列宽 ≤ 目标宽（不拉伸）；
/// - 若 ceil 后列宽会小于 [minColumnWidth]（如手机竖屏 390 → 2 列*195 过窄），
///   回退到 floor(width / [minColumnWidth]) 列（至少 1 列），避免出现过窄列。
///
/// 不变式（见 test/grid_columns_test.dart RT-107）：
/// - 任意输入返回 ≥ 1（含 0/负数/NaN/infinity）；
/// - 列数只会 ≥ 旧 floor 算法（卡片只会更窄，不会更宽）；
/// - 手机竖屏（360~430）恒为 1 列、768 → 2 列、1024 → 3 列（与旧算法一致，
///   移动端行为不变）；
/// - width ≥ 560 时列宽落在 [260, 390] 区间（正常 [260, 340]，
///   仅在夹逼回退的窄窗口带最多 ~390）。
int gridColumnsForWidth(
  double width, {
  double targetColumnWidth = 340,
  double minColumnWidth = 260,
}) {
  if (!width.isFinite || !(width > 0) || !(targetColumnWidth > 0) || !(minColumnWidth > 0)) {
    return 1;
  }
  var n = (width / targetColumnWidth).ceil();
  if (minColumnWidth < targetColumnWidth) {
    final maxByMin = (width / minColumnWidth).floor();
    if (maxByMin >= 1 && n > maxByMin) {
      n = maxByMin;
    }
  }
  return n < 1 ? 1 : n;
}
