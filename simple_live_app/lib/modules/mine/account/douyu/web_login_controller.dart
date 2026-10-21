import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/models/db/account.dart';
import 'package:simple_live_app/services/platform_service.dart';

/// 斗鱼「网页登录」：在应用内打开斗鱼登录页，用户用账号密码/手机验证码登录，
/// 登录成功后自动从 WebView 读取并保存 Cookie（等同官方网页登录，无需扫码/装 App）。
class DouyuWebLoginController extends BaseController {
  Account account = Get.arguments;
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
    _loadLoginPage();
  }

  /// 加载斗鱼登录页：**进入即加载，不在加载前做任何 await 清理**。
  ///
  /// 2026-10-20 Howe 真机报「点网页登录是空白」→ 根因：本页曾在 v1.8.18 于加载前
  /// `await clearWebLoginCookies(...)`（入口冗余清理）。该清理要串行读/删 Cookie + flush +
  /// 清 Web 存储（Android 端这些是主线程同步调用，Windows 端部分 API 未实现会抛错/耗时），
  /// 使 `loadUrl` 被长时间推迟乃至阻塞 → 登录页迟迟不出现（看即空白）。
  /// **证据：B 站登录页无此入口清理、直接加载，一直正常**（见 bilibili/web_login_controller.dart）。
  /// 故与 B 站对齐，**进入即加载**；「退号后自动登入」的防线仍在退号侧
  /// （accountLogout → clearWebLoginCookies，含 host-only 补删 + 回读重试 + 清 Web 存储）。
  void _loadLoginPage() {
    final c = webViewController;
    if (c == null) {
      return; // 页面已销毁，别再加载
    }
    Log.d('[斗鱼登录] 开始加载登录页: $loginUrl');
    c.loadUrl(urlRequest: URLRequest(url: WebUri(loginUrl))).catchError((e) {
      Log.e("斗鱼登录页加载失败: $e", StackTrace.current);
    });
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
      var cookies = await cookieManager.getCookies(url: WebUri("https://www.douyu.com"));
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
      var cookieStr = cookies.map((e) => "${e.name}=${e.value}").join("; ");
      // 不把 Cookie 明文写日志（含 acf_jwt_token/LTP0 等敏感项），只记录字段清单
      Log.i("斗鱼网页登录成功，已获取 Cookie 字段：${cookieMap.keys.join(',')}");
      var did = cookieMap["dy_did"] ?? "";
      var ltp0 = cookieMap["LTP0"] ?? "";
      var credential = jsonEncode({
        'cookie': cookieStr,
        'dy_did': did,
        'LTP0': ltp0,
      });
      // 账号体系统一入口：写入 credential 并做一次有效性校验（刷新 cookie）
      await PlatformService.instance.accountLogin(account.copyWith(credential: credential));
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
      Log.d('[斗鱼登录] onLoadStop uri=null');
      return;
    }
    Log.d('[斗鱼登录] 页面加载完成: $uri');
    if (shouldIntercept(uri)) {
      logined();
    }
  }
}
