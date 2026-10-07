import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/platform_service.dart';

class AccountController extends GetxController {
  void bilibiliTap() async {
    if (BiliBiliAccountService.instance.logined.value) {
      var result = await Utils.showAlertDialog("确定要退出哔哩哔哩账号吗？", title: "退出登录");
      if (result) {
        BiliBiliAccountService.instance.logout();
      }
    } else {
      //AppNavigator.toBiliBiliLogin();
      bilibiliLogin();
    }
  }

  void bilibiliLogin() {
    Utils.showBottomSheet(
      title: "登录哔哩哔哩",
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Visibility(
            visible: Platform.isAndroid || Platform.isIOS,
            child: ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: const Text("Web登录"),
              subtitle: const Text("填写用户名密码登录"),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Get.back();
                Get.toNamed(RoutePath.kBiliBiliWebLogin);
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.qr_code),
            title: const Text("扫码登录"),
            subtitle: const Text("使用哔哩哔哩APP扫描二维码登录"),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Get.back();
              Get.toNamed(RoutePath.kBiliBiliQRLogin);
            },
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text("Cookie登录"),
            subtitle: const Text("手动输入Cookie登录"),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Get.back();
              doCookieLogin();
            },
          ),
        ],
      ),
    );
  }

  void doCookieLogin() async {
    var cookie = await Utils.showEditTextDialog(
      "",
      title: "请输入Cookie",
      hintText: "请输入Cookie",
    );
    if (cookie == null || cookie.isEmpty) {
      return;
    }
    BiliBiliAccountService.instance.setCookie(cookie);
    await BiliBiliAccountService.instance.loadUserInfo();
  }

  // 需要用户手动复制抖音的Cookie
  void douyinTap() async {
    if (PlatformService.instance.douyinLogined.value) {
      var result = await Utils.showAlertDialog("确定要清除抖音Cookie吗？", title: "清除Cookie");
      if (result) {
        PlatformService.instance.douyinLogout();
      }
    } else {
      final cookie = await Utils.showEditTextDialog(
        "",
        title: "请输入抖音Cookie",
        hintText: "__ac_signature=...;sessionid=...;",
      );
      if (cookie == null || cookie.isEmpty) return;
      PlatformService.instance.setDouyinCookie(cookie);
      // 检查输入的cookie是否有效
      await PlatformService.instance.loadDouyinUserInfo();
    }
  }

  void douyuTap() async {
    if (PlatformService.instance.douyuCookie.value.isNotEmpty) {
      var result = await Utils.showAlertDialog("确定要清除斗鱼Cookie吗？", title: "清除Cookie");
      if (result) {
        PlatformService.instance.douyuLogout();
      }
    } else {
      douyuLoginSheet();
    }
  }

  // 登录方式选择：网页登录（推荐）/ 手动填写 Cookie
  void douyuLoginSheet() {
    Utils.showBottomSheet(
      title: "登录斗鱼",
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Visibility(
            visible: Platform.isAndroid ||
                Platform.isIOS ||
                Platform.isWindows ||
                Platform.isMacOS,
            child: ListTile(
              leading: const Icon(Icons.web_outlined),
              title: const Text("网页登录"),
              subtitle: const Text("账号密码 / 手机验证码登录（推荐）"),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Get.back();
                Get.toNamed(RoutePath.kDouyuWebLogin);
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text("手动填写 Cookie"),
            subtitle: const Text("自行粘贴 dy_did / LTP0 等参数"),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Get.back();
              douyuCookieInput();
            },
          ),
        ],
      ),
    );
  }

  void douyuCookieInput() async {
    final douyuParams = await Utils.showEditTextsDialog([
      TextEditItem(
        value: PlatformService.instance.douyuCookie.value,
        label: 'cookie',
        hintText: 'dy_did=...; acf_did=...;etc',
        key: 'cookie',
      ),
      TextEditItem(
        value: PlatformService.instance.dy_did,
        label: 'dy_did',
        hintText: '10000000000000000000000000001501',
        key: 'dy_did',
      ),
      TextEditItem(
        value: PlatformService.instance.dyLtp0,
        label: 'ltp0',
        hintText: '自动更新cookie',
        obscureText: true,
        key: 'ltp0',
      ),
    ], title: '请输入斗鱼各项参数');
    if (douyuParams == null || douyuParams.isEmpty) return;
    var dyCookie = douyuParams['cookie'] ?? '';
    var dyDid = douyuParams['dy_did'] ?? '';
    var dyLtp0 = douyuParams['ltp0'] ?? '';
    PlatformService.instance.setDouyuCookie(dyCookie);
    await PlatformService.instance.setDouyuDidAndLtp0(dyDid, dyLtp0);
  }
}
