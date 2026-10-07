import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/services/platform_service.dart';

/// 斗鱼「网页登录」：在应用内打开斗鱼登录页，用户用账号密码/手机验证码登录，
/// 登录成功后自动从 WebView 读取并保存 Cookie（等同官方网页登录，无需扫码/装 App）。
class DouyuWebLoginController extends BaseController {
  InAppWebViewController? webViewController;
  final CookieManager cookieManager = CookieManager.instance();

  /// 登录入口页（网页端自带 账号密码 / 手机验证码 / 扫码 三种方式）
  static const String loginUrl =
      "https://passport.douyu.com/index/login?client_id=1&type=login&state=https%3A%2F%2Fwww.douyu.com%2F&source=click_topnavi_login";

  bool _saved = false;

  void onWebViewCreated(InAppWebViewController controller) {
    webViewController = controller;
    webViewController!.loadUrl(urlRequest: URLRequest(url: WebUri(loginUrl)));
  }

  /// 登录完成后斗鱼会把页面跳回 www.douyu.com，此时尝试抓取 Cookie。
  bool shouldIntercept(Uri uri) {
    if (_saved) {
      return false;
    }
    var host = uri.host;
    if (host.isEmpty || host.startsWith("passport.douyu.com")) {
      return false;
    }
    return host == "www.douyu.com" || host.endsWith(".douyu.com");
  }

  Future<bool> logined() async {
    if (_saved) {
      return true;
    }
    try {
      var cookies =
          await cookieManager.getCookies(url: WebUri("https://www.douyu.com"));
      if (cookies.isEmpty) {
        return false;
      }
      var cookieStr = cookies.map((e) => "${e.name}=${e.value}").join("; ");
      // 未登录时不会有 jwt token / uid，避免误判
      if (!cookieStr.contains("acf_jwt_token=") &&
          !cookieStr.contains("acf_uid=")) {
        return false;
      }
      Log.i(cookieStr);
      PlatformService.instance.setDouyuCookie(cookieStr);
      var did = _pickCookie(cookieStr, "dy_did");
      var ltp0 = _pickCookie(cookieStr, "LTP0");
      if (did.isNotEmpty || ltp0.isNotEmpty) {
        await PlatformService.instance.setDouyuDidAndLtp0(did, ltp0);
      }
      _saved = true;
      Get.back();
      return true;
    } catch (e, stack) {
      Log.e("斗鱼登录Cookie获取失败: $e", stack);
      return false;
    }
  }

  /// onLoadStop 兜底：某些机型 shouldOverrideUrlLoading 不触发时也能抓取。
  void onLoadStop(InAppWebViewController controller, Uri? uri) {
    if (uri == null) {
      return;
    }
    if (shouldIntercept(uri)) {
      logined();
    }
  }

  String _pickCookie(String cookieStr, String name) {
    for (final pair in cookieStr.split(";")) {
      var p = pair.trim();
      if (p.startsWith("$name=")) {
        return p.substring(name.length + 1);
      }
    }
    return "";
  }
}
