import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 回归守卫（RT-103 / ISS-110 / ISS-111）：B站 setSiteAttrs 的凭据兼容性。
///
/// 背景：账号体系迁移后 credential 统一为 `{"cookie":"..."}` JSON，setSiteAttrs
/// 直接 `jsonDecode`。若入参是旧格式（原始 Cookie 串）会抛 FormatException，
/// 导致 activate/login 流程中断 —— 本测试锁定「非 JSON 入参不抛异常且原样采用」。
void main() {
  test('JSON 入参：取 cookie 字段', () {
    final site = BiliBiliSite();
    site.setSiteAttrs('{"cookie":"a=1; b=2"}');
    expect(site.cookie, 'a=1; b=2');
  });

  test('旧格式（原始 Cookie 串）入参：不抛异常并原样采用', () {
    final site = BiliBiliSite();
    expect(() => site.setSiteAttrs('a=1; b=2'), returnsNormally);
    expect(site.cookie, 'a=1; b=2');
  });

  test('JSON 但无 cookie 字段：不覆盖已有值', () {
    final site = BiliBiliSite();
    site.setSiteAttrs('{"cookie":"x=1"}');
    site.setSiteAttrs('{"other":"y"}');
    expect(site.cookie, 'x=1');
  });
}
