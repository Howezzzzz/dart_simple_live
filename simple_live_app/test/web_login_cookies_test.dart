import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/services/web_login_cookies.dart';

/// 回归守卫（RT）：退号时需清理网页登录 Cookie 的域名映射。
///
/// 修复场景：退出 B站/斗鱼账号后，应用内网页登录（InAppWebView）的 Cookie 未清理，
/// 再次点「网页登录」会被旧 Cookie 自动登录，无法换号。
/// 该映射一旦被误删/改空，本测试即失败。
void main() {
  test('使用网页登录的站点（B站/斗鱼）有清理域名，其余站点为空', () {
    expect(webLoginCookieDomainsFor(Constant.kBiliBili), isNotEmpty);
    expect(webLoginCookieDomainsFor(Constant.kDouyu), isNotEmpty);

    for (final site in [Constant.kDouyin, Constant.kHuya, Constant.kTwitch]) {
      expect(webLoginCookieDomainsFor(site), isEmpty,
          reason: '$site 无应用内网页登录，不应清理任何域名');
    }
  });

  test('B站清理域名覆盖主站与 passport（网页登录页所在域）', () {
    final domains = webLoginCookieDomainsFor(Constant.kBiliBili);
    expect(domains, contains('https://www.bilibili.com'));
    expect(domains, contains('https://passport.bilibili.com'));
  });

  test('斗鱼清理域名覆盖主站与 passport（网页登录页所在域）', () {
    final domains = webLoginCookieDomainsFor(Constant.kDouyu);
    expect(domains, contains('https://www.douyu.com'));
    expect(domains, contains('https://passport.douyu.com'));
  });

  test('未知站点返回空列表（不误伤其它 WebView）', () {
    expect(webLoginCookieDomainsFor('nope'), isEmpty);
  });
}
