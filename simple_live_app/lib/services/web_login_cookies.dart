import 'package:simple_live_app/app/constant.dart';

/// 使用「应用内网页登录」（InAppWebView）的站点 → 其登录相关域名。
///
/// 退出账号时需清掉这些站点的网页登录 Cookie：否则再次点「网页登录」时，
/// 登录页会带着旧 Cookie 直接以网页身份自动登录，用户无法换号。
///
/// 实现见 `PlatformService.clearWebLoginCookies`——**按域名定向清理**，
/// 只动该站点自己的 Cookie，不影响其它站点的网页登录态（ISS-113）。
/// 其余站点（抖音/虎牙/Twitch）无网页登录，返回空。
const Map<String, List<String>> kWebLoginCookieDomains = {
  Constant.kBiliBili: [
    'https://bilibili.com',
    'https://www.bilibili.com',
    'https://passport.bilibili.com',
  ],
  Constant.kDouyu: [
    'https://douyu.com',
    'https://www.douyu.com',
    'https://passport.douyu.com',
  ],
};

/// 返回该站点需要清理 Cookie 的域名列表（无网页登录取空的）。
List<String> webLoginCookieDomainsFor(String siteId) =>
    kWebLoginCookieDomains[siteId] ?? const <String>[];

/// 把「网页登录域名」展开为需要清理的 Cookie domain 变体。
///
/// 依据已核对的 flutter_inappwebview 6.2.0-beta.3 各平台实现：
/// - **Android**：`deleteCookies` 取该 URL 的 Cookie 头（含 HttpOnly）逐个下发
///   `Max-Age=-1` 过期 Cookie；**带 Domain 才能命中域级 Cookie**（`Domain=.bilibili.com`），
///   不带 Domain 只能命中 host-only 的。
/// - **iOS/macOS**：`deleteCookies` 按 `cookie.domain == domain && cookie.path == path`
///   **精确匹配**删除，而系统里域级 Cookie 的 domain 带前导点（`.bilibili.com`）
///   → 必须带点 / 不带点各清一次。
///
/// 因此统一返回三个变体：注册域（末两段，如 `bilibili.com`）、其带点形式、原始主机名。
List<String> cookieDomainVariants(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  if (host.isEmpty) {
    return const <String>[];
  }
  final parts = host.split('.');
  final base =
      parts.length >= 2 ? parts.sublist(parts.length - 2).join('.') : host;
  return <String>{base, '.$base', host}.toList();
}
