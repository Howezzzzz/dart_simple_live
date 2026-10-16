import 'dart:async';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/account.dart';
import 'package:simple_live_app/requests/common_request.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/web_login_cookies.dart';
import 'package:simple_live_core/simple_live_core.dart';

class PlatformService extends GetxService {
  static PlatformService get instance => Get.find<PlatformService>();

  StreamSubscription<dynamic>? subscription;

  RxList<Account> accountList = RxList();

  void _initAccount() {
    accountList.value = DBService.instance.getAllAccounts();
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
    await DBService.instance.addAccount(ac);
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
    final clean = await clearWebLoginCookies(ac.siteId);
    if (!clean) {
      Log.e('退号：${ac.siteId} 的网页登录 Cookie 未能完全清理（下次网页登录可能仍为旧账号）',
          StackTrace.current);
    }
  }

  /// 清理「应用内网页登录」（InAppWebView）的 Cookie——**只清该站点自己的域名**。
  ///
  /// 旧实现直接用 `deleteAllCookies()`：会把**其它站点**的网页登录态一并清掉
  /// （例：退 B站 账号 → 斗鱼网页登录也失效），故改为按域名定向清理（ISS-113）。
  ///
  /// 每个域名会清三个 domain 变体（注册域 / 带点 / 主机名），以同时覆盖
  /// Android 的域级 Cookie 与 iOS/macOS 的精确 domain 匹配（依据已核对的插件实现）。
  /// 清理后**回读一次作为观测点**：仍有残留则记日志（含 Cookie 名）且返回 false，
  /// 不静默——便于真机定位。
  Future<bool> clearWebLoginCookies(String siteId) async {
    final domains = webLoginCookieDomainsFor(siteId);
    if (domains.isEmpty) {
      return true;
    }
    final cookieManager = CookieManager.instance();
    var clean = true;
    for (final raw in domains) {
      final url = WebUri(raw);
      for (final domain in cookieDomainVariants(raw)) {
        try {
          await cookieManager.deleteCookies(url: url, domain: domain, path: '/');
        } catch (e) {
          clean = false;
          Log.e('清理 $siteId 网页登录 Cookie 失败（$raw / domain=$domain）: $e',
              StackTrace.current);
        }
      }
    }
    // 观测点：回读确认（清不掉时用户会看到「退号后仍自动登录」）
    for (final raw in domains) {
      try {
        final left = await cookieManager.getCookies(url: WebUri(raw));
        if (left.isNotEmpty) {
          clean = false;
          Log.e(
              '⚠️ $siteId 网页登录 Cookie 仍有残留：${left.map((e) => e.name).join(',')}',
              StackTrace.current);
        }
      } catch (e) {
        Log.e('回读 $siteId 网页登录 Cookie 失败: $e', StackTrace.current);
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
    await updateAccount(resAc);
    site.liveSite.setSiteAttrs(resAc.credential);
    if(!info.isValid){
      SmartDialog.showToast('${site.name}账号失效，请重新设置');
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

  static const String defaultHuyaSdkUa = "HYSDK(Windows,30000002)_APP(pc_exe&7090000&official)_SDK(trans&2.35.0.5996)";
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
  void onInit() {
    subscription = EventBus.instance.listen(Constant.kUpdateAccount, (data) {
      Log.i('update Account');
      _initAccount();
    });
    _initAccount();
    _updateDouyinAttr();
    _initHuya();
    super.onInit();
  }

  @override
  void onClose(){
    subscription?.cancel();
  }
}
