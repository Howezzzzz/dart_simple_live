import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/account.dart';
import 'package:simple_live_app/requests/common_request.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/web_login_cookies.dart';
import 'package:simple_live_app/services/safe_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class PlatformService extends GetxService {
  static PlatformService get instance => Get.find<PlatformService>();

  StreamSubscription<dynamic>? subscription;

  RxList<Account> accountList = RxList();

  bool _inited = false;

  Future<void> _initAccount() async {
    accountList.value = await SafeService.instance.getDecodeAccounts();
    // 加密模式, 未登录->跳过cookie使用/登录->解码
    if (AppSettingsController.instance.appSafeEnable.value && !AppSettingsController.instance.appStoreKey.value) {
      return;
    }
    // 自动更新
    for (var account in accountList) {
      accountLogin(account);
    }
  }

  // 更新指定的站点账户数据
  Future<void> updateAccount(Account ac) async {
    accountList.assignAll(
      accountList.map((a) => a.id == ac.id ? ac : a).toList(),
    );
    accountList.refresh();
    await SafeService.instance.encodeAccount(ac);
  }

  Future<void> accountLogout(Account ac) async {
    var logout = ac.copyWith(
      id: ac.id,
      userName: '',
      credential: '',
      isActive: false,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await updateAccount(logout);
    // 同步清掉应用内「网页登录」残留的 Cookie。
    // 否则退号后再点网页登录，登录页会带着旧 Cookie 自动登录，用户无法换号。
    // 注：登录页入口不再做阻塞式清理（会导致登录页空白，见 douyu/web_login_controller.dart）；
    // 本处是唯一防线，已修复“挂死”问题（见 clearWebLoginCookies 顶部 flush 说明）。
    final clean = await clearWebLoginCookies(ac.siteId);
    if (!clean) {
      Log.e('退号：${ac.siteId} 的网页登录 Cookie 未能完全清理（下次网页登录可能仍为旧账号）', StackTrace.current);
    }
  }

  /// 清理「应用内网页登录」（InAppWebView）的 Cookie——**只清该站点自己的域名**。
  ///
  /// 旧实现直接用 `deleteAllCookies()`：会把**其它站点**的网页登录态一并清掉
  /// （例：退 B站 账号 → 斗鱼网页登录也失效），故改为按域名定向清理（ISS-113）。
  ///
  /// 每个目标 URL 会：①先 `getCookies(url)` 读出每条，按**每条自身的 domain/path** 精确过期；
  /// ②再补一次**不带 domain** 的过期（专杀 host-only cookie——见下）；③回读，
  /// 残留则重试一次；④顺带清该站点的 **Web 存储**（localStorage/sessionStorage，仅该站点 origin）。
  ///
  /// 2026-10-20 修（Howe 真机：**斗鱼网页登录点进去空白**）——根因曾是本函数末尾的显式
  /// `await cookieManager.flush()`：插件 Android 端 `MyCookieManager.java` 的 `flush()` **漏了
  /// `result.success(...)`**，Dart 侧 `await invokeMethod('flush')` **永不返回且不抛异常**
  /// → 本函数永不返回 → 调用方 `await` 卡死（登录页入口曾有 await → loadUrl 永不执行 → 空白；
  /// 退号侧 await → 退号清理链卡死）。**该 flush 本就冗余**：插件里 setCookie/deleteCookies/
  /// deleteAllCookies/removeSessionCookies 内部都已调用原生 flush 且回包；iOS/macOS/Windows/Web 的
  /// flush 未实现（基类直接 throw）——显式调用零收益。故**彻底删除**。
  ///
  /// 2026-10-19 修（Howe 真机：**Android 退斗鱼号后网页登录仍自动登入**）——
  /// 旧实现每次都带 `Domain=`，而 Chromium 里带 Domain 的 cookie 其 host_key 带前导点
  /// （`.douyu.com`），不带 Domain 的 **host-only** cookie host_key 是主机名（`www.douyu.com`）——
  /// 二者不是同一行，故 host-only 登录态**永远删不掉**。故补「不带 domain」的删除。
  /// 另：各插件调用加 [_webLoginCleanupTimeout] 超时护栏，防未来同类「不回包」插件 bug 拖死流程。
  static const Duration _webLoginCleanupTimeout = Duration(seconds: 8);

  Future<bool> clearWebLoginCookies(String siteId) async {
    final urls = webLoginCookieDomainsFor(siteId);
    if (urls.isEmpty) {
      return true;
    }
    final cookieManager = CookieManager.instance();
    var clean = true;
    var anySwept = false; // 是否真的删过东西（全程无 cookie 可删时跳过回读/重试）

    Future<void> expire(WebUri url, String? domain, String path) async {
      try {
        await cookieManager.deleteCookies(url: url, domain: domain, path: path).timeout(_webLoginCleanupTimeout);
      } catch (e) {
        clean = false;
        Log.e('清理 $siteId 网页登录 Cookie 失败（$url / domain=$domain / path=$path）: $e', StackTrace.current);
      }
    }

    Future<void> sweep() async {
      for (final raw in urls) {
        final url = WebUri(raw);
        // 插件 deleteCookies 内部会对该 url 可见的**所有** cookie 名逐个下发过期，
        // 故同一 (domain,path) 只需调用一次 → 去重避免 O(n²) 次 setCookie/flush。
        final pairs = <(String?, String)>{};
        void add(String? domain, String path) => pairs.add((domain, path.isEmpty ? '/' : path));

        // ① 读现存 → 用 cookieDeleteDomain 判定传 null（host-only）还是带点域；path 用其自身值
        var readOk = true;
        try {
          for (final c in await cookieManager.getCookies(url: url).timeout(_webLoginCleanupTimeout)) {
            add(cookieDeleteDomain(c.domain), c.path ?? '/');
          }
        } catch (e) {
          readOk = false;
          clean = false; // 读不到 = 无法确认已清，不当成功（不糊弄）
          Log.e('回读 $siteId 网页登录 Cookie 失败（$raw）: $e', StackTrace.current);
        }
        // 提速·方案A（2026-10-21）：该 URL **读成功且无任何 cookie** → 无可删项，
        // 跳过其余部 deleteCookies（含下方兜底变体）。Windows 上每次 deleteCookies 会
        // 临时创建 WebView2，空操作是退号慢的主因；getCookies 返回该 URL 可见的全部
        // cookie（含 host-only），为空则可安全跳过。读取失败（readOk=false）时仍走
        // 兜底尽力删，不跳过。
        if (Platform.isWindows && readOk && pairs.isEmpty) {
          continue;
        }
        anySwept = true;
        // ② 兜底：常见域变体 + 不带 domain（覆盖 getCookies 未列出的 path/子域）
        for (final d in cookieDomainVariants(raw)) {
          add(d, '/');
        }
        add(null, '/');

        for (final (dom, path) in pairs) {
          await expire(url, dom, path);
        }
      }
      // 不再调用显式 flush：Android 插件 flush() 永不回包（MyCookieManager.java 无 result.success），
      // 会让本函数永久挂起（2026-10-20 斗鱼登录页空白根因）；且插件写操作内部已自带 flush。
    }

    Future<List<String>> leftovers() async {
      final left = <String>[];
      for (final raw in urls) {
        try {
          final cs = await cookieManager.getCookies(url: WebUri(raw)).timeout(_webLoginCleanupTimeout);
          if (cs.isNotEmpty) {
            left.add('$raw: ${cs.map((e) => '${e.name}@${e.domain ?? '-'}${e.path ?? ''}').join(',')}');
          }
        } catch (_) {}
      }
      return left;
    }

    await sweep();
    // 观测点：仅当确实删过东西时才回读确认（无删除 = 无残留，省一波 getCookies +
    // 可能的第二次 sweep；同样是 Windows 临时 Webview2 开销的主要来源）。
    if (anySwept) {
      var left = await leftovers();
      if (left.isNotEmpty) {
        await sweep();
        left = await leftovers();
      }
      if (left.isNotEmpty) {
        clean = false;
        Log.e('⚠️ $siteId 网页登录 Cookie 仍有残留：$left', StackTrace.current);
      }
    }

    // ④ 清该站点的 Web 存储（localStorage/sessionStorage）——只清该站点 origin
    for (final raw in urls) {
      try {
        await WebStorageManager.instance().deleteOrigin(origin: raw).timeout(_webLoginCleanupTimeout);
      } catch (e) {
        Log.e('清理 $siteId 网页存储失败（$raw）: $e', StackTrace.current);
      }
    }
    return clean;
  }

  Future<bool> accountLogin(Account ac) async {
    var site = Sites.allSites[ac.siteId]!;
    AccountInfo info = await site.liveSite.getAccountInfo(credential: ac.credential);
    var resAc = ac.copyWith(
      userName: info.name,
      avatar: info.avatar,
      uid: info.uid,
      credential: info.credential,
      isActive: info.isValid,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    if (!info.isValid) {
      SmartDialog.showToast('${site.name}账号失效，请重新设置');
      // 失效也要回写 isActive，否则 UI 无法反映账号已失效（见 ISS-220）；不覆盖原 credential
      await updateAccount(ac.copyWith(
        isActive: false,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ));
    } else {
      site.liveSite.setSiteAttrs(resAc.credential);
      await updateAccount(resAc);
    }
    return info.isValid;
  }

  // ==================== 抖音 ====================

  final _douyinSite = (Sites.allSites[Constant.kDouyin]!.liveSite as DouyinSite);

  void _updateDouyinAttr() {
    var douyinHlsFirst = LocalStorageService.instance.getValue(LocalStorageService.kDouyinHlsFirst, false);
    Map<String, dynamic> params = {
      'hlsFirst': douyinHlsFirst,
    };
    _douyinSite.setSiteAttrs(jsonEncode(params));
  }

  // ==================== 虎牙 ====================

  /// 内置兑底 UA（2026-10-21 更新为上游当前值；网络源不可用时的最后防线）。
  static const String defaultHuyaSdkUa = "HYSDK(Windows,30000002)_APP(pc_exe&7100004&official)_SDK(trans&2.40.0.6448)";
  final _huyaSite = (Sites.allSites[Constant.kHuya]!.liveSite as HuyaSite);
  var huyaSdkUa = "".obs;

  void _initHuya() {
    huyaSdkUa.value = LocalStorageService.instance.getValue(LocalStorageService.kHuyaSdkUa, "");
    _updateHuyaAttr();
  }

  void _updateHuyaAttr() {
    var ua = huyaSdkUa.value.isNotEmpty ? huyaSdkUa.value : defaultHuyaSdkUa;
    _huyaSite.setSiteAttrs(jsonEncode(
      {
        'ua': ua,
      },
    ));
    Log.i("HuyaSite.HYSDK_UA 已设置: $ua");
  }

  Future<void> fetchHuyaSdkUa() async {
    try {
      SmartDialog.showLoading(msg: "正在拉取配置...");
      var request = CommonRequest();
      var config = await request.fetchHuyaConfig();
      var ua = config['hysdk_ua'] as String? ?? "";
      if (ua.isEmpty) {
        SmartDialog.dismiss();
        SmartDialog.showToast("配置中未找到 hysdk_ua");
        return;
      }
      huyaSdkUa.value = ua;
      await LocalStorageService.instance.setValue(LocalStorageService.kHuyaSdkUa, ua);
      _updateHuyaAttr();
      SmartDialog.dismiss();
      SmartDialog.showToast("虎牙配置已更新");
      Log.i("HuyaSite.HYSDK_UA 已更新: $ua");
    } catch (e) {
      SmartDialog.dismiss();
      SmartDialog.showToast("拉取配置失败: $e");
      Log.e("拉取虎牙配置失败: $e", StackTrace.current);
    }
  }

  // ==================== 生命周期 ====================

  @override
  Future<void> onInit() async {
    // 幂等：Get.put 内部已会触发 onInit，调用方再手动调一次不得重复初始化
    // （否则 EventBus 双订阅泄漏 + _initAccount/accountLogin 双跑，见 ISS-217）
    if (_inited) {
      super.onInit();
      return;
    }
    _inited = true;
    subscription = EventBus.instance.listen(Constant.kUpdateAccount, (data) {
      Log.i('update Account');
      if (data is Account) {
        accountLogin(data);
      } else {
        // 非 Account 载荷（如 webdav 恢复后的刷新信号 0）→ 整体重载并重加密（见 ISS-216）
        _initAccount();
      }
    });
    await _initAccount();
    _updateDouyinAttr();
    _initHuya();
    super.onInit();
  }

  @override
  void onClose() {
    subscription?.cancel();
  }
}
