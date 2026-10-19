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

  // 2026-10-19（Howe 真机：安卓退斗鱼号后网页登录仍自动登入）
  // 旧实现只带 Domain= 删 cookie → 删不掉 host-only；且子域 host-only 根本读不到。
  // 这里守住「子域主机名也进清理列表」。
  test('子域主机名也在清理列表内（host-only cookie 覆盖）', () {
    expect(webLoginCookieDomainsFor(Constant.kDouyu),
        containsAll(['https://m.douyu.com', 'https://h5.douyu.com']));
    expect(webLoginCookieDomainsFor(Constant.kBiliBili),
        contains('https://m.bilibili.com'));
  });

  // RT-105 / ISS-113：定向清理需要正确的 domain 变体；漏一个就会退号后仍自动登录，
  // 多一个就可能误伤别的站点。
  group('cookieDomainVariants', () {
    test('注册域本身：给出域级（带点/不带点）两个变体', () {
      expect(cookieDomainVariants('https://bilibili.com'),
          ['bilibili.com', '.bilibili.com']);
    });

    test('子域：额外带上原始主机名（host-only Cookie）', () {
      expect(
          cookieDomainVariants('https://www.bilibili.com'),
          containsAll(
              ['bilibili.com', '.bilibili.com', 'www.bilibili.com']));
      expect(cookieDomainVariants('https://passport.douyu.com'),
          containsAll(['douyu.com', '.douyu.com', 'passport.douyu.com']));
    });

    test('不产生其它站点的域名（不误伤）', () {
      final variants = cookieDomainVariants('https://www.bilibili.com');
      expect(variants.any((d) => d.contains('douyu')), isFalse);
    });

    test('非法输入：返回空而不是抛异常', () {
      expect(cookieDomainVariants('not a url'), isEmpty);
      expect(cookieDomainVariants(''), isEmpty);
    });
  });

  // 2026-10-19 真机修复：host-only cookie 的 domain 是主机名，当成 Domain 传进去会落到
  // `.www.douyu.com` 这一行、删不掉原 cookie；必须传 null。
  group('cookieDeleteDomain', () {
    test('host-only（不带点 / 空）→ 传 null', () {
      expect(cookieDeleteDomain('www.douyu.com'), isNull);
      expect(cookieDeleteDomain('passport.douyu.com'), isNull);
      expect(cookieDeleteDomain(''), isNull);
      expect(cookieDeleteDomain(null), isNull);
    });

    test('域级（带前导点）→ 原样传', () {
      expect(cookieDeleteDomain('.douyu.com'), '.douyu.com');
      expect(cookieDeleteDomain('.bilibili.com'), '.bilibili.com');
    });
  });
}
