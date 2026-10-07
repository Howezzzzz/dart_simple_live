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

  /// 登录页域：命中即拦截（登录成功后斗鱼会跳回 www.douyu.com）
  static const String _passportHost = "passport.douyu.com";

  bool _saved = false;
  bool _checking = false;

  void onWebViewCreated(InAppWebViewController controller) {
    webViewController = controller;
    webViewController!.loadUrl(urlRequest: URLRequest(url: WebUri(loginUrl)));
  }

  /// 是否已离开登录页、落到斗鱼主站（此时尝试抓取 Cookie）。
  bool shouldIntercept(Uri uri) {
    if (_saved) {
      return false;
    }
    var host = uri.host;
    if (host.isEmpty || host == _passportHost) {
      return false;
    }
    return host == "www.douyu.com" || host.endsWith(".douyu.com");
  }

  /// 读取 WebView Cookie：仅在拿到**非空** `acf_jwt_token`（登录态判据，与
  /// 上游 DouyuUtils.refreshCookie 一致）时才算登录成功，避免游客态误判。
  Future<bool> logined() async {
    if (_saved) {
      return true;
    }
    // 双通道（shouldOverrideUrlLoading / onLoadStop）可能同时触发，这里同步占位防重复弹栈
    if (_checking) {
      return false;
    }
    _checking = true;
    try {
      var cookies =
          await cookieManager.getCookies(url: WebUri("https://www.douyu.com"));
      if (cookies.isEmpty) {
        return false;
      }
      var cookieMap = <String, String>{};
      for (final c in cookies) {
        cookieMap[c.name] = c.value == null ? "" : c.value.toString();
      }
      if ((cookieMap["acf_jwt_token"] ?? "").isEmpty) {
        // 未登录（游客）不保存，继续等待用户完成登录
        return false;
      }
      var cookieStr =
          cookies.map((e) => "${e.name}=${e.value}").join("; ");
      Log.i(cookieStr);
      PlatformService.instance.setDouyuCookie(cookieStr);
      var did = cookieMap["dy_did"] ?? "";
      var ltp0 = cookieMap["LTP0"] ?? "";
      if (did.isNotEmpty || ltp0.isNotEmpty) {
        await PlatformService.instance.setDouyuDidAndLtp0(did, ltp0);
      }
      _saved = true;
      Get.back();
      return true;
    } catch (e, stack) {
      Log.e("斗鱼登录Cookie获取失败: $e", stack);
      return false;
    } finally {
      _checking = false;
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
}
