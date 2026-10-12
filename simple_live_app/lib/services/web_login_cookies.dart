import 'package:simple_live_app/app/constant.dart';

/// 使用「应用内网页登录」（InAppWebView）的站点 → 其登录相关域名（示意）。
///
/// 退出账号时需清掉这些站点的网页登录 Cookie：否则再次点「网页登录」时，
/// 登录页会带着旧 Cookie 直接以网页身份自动登录，用户无法换号。
///
/// 实现上清 Cookie 用的是 `deleteAllCookies()`（见 PlatformService.clearWebLoginCookies），
/// 本表只用于判定「该站点是否使用网页登录」；域名列出供参考。
/// 其余站点（抖音/虎牙/Twitch）无网页登录，返回空。
const Map<String, List<String>> kWebLoginCookieDomains = {
  Constant.kBiliBili: [
    'https://www.bilibili.com',
    'https://passport.bilibili.com',
    'https://bilibili.com',
  ],
  Constant.kDouyu: [
    'https://www.douyu.com',
    'https://passport.douyu.com',
    'https://douyu.com',
  ],
};

/// 返回该站点需要清理 Cookie 的域名列表（无网页登录取空的）。
List<String> webLoginCookieDomainsFor(String siteId) =>
    kWebLoginCookieDomains[siteId] ?? const <String>[];
