import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils/encrypt/aes_util.dart';
import 'package:simple_live_app/models/db/account.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/secure_store_service.dart';

class SafeService extends GetxService {
  static SafeService get instance => Get.find<SafeService>();

  /// 安全模式哨兵：校验「密钥 ↔ 数据」是否配套（来自 Constant，单一来源，见 ISS-223）
  static const String kSafeMarker = Constant.kSafeMarker;

  // 统一管理需要加密的数据源

  /// 纯函数：用 [key] 解密 [src] 中每条账号的 credential，返回**新列表**。
  /// - 不改写入参对象（否则会污染 Hive 缓存对象 → 明文被 webdav 上传，见 ISS-212）
  /// - 解密失败的账号原样保留（保持密文，不降级成明文）
  static Future<List<Account>> decodeAccounts(List<Account> src, String key) async {
    final out = <Account>[];
    for (final account in src) {
      if (account.credential.isEmpty) {
        out.add(account);
        continue;
      }
      try {
        final plain = await AesUtils.decrypt(account.credential, key);
        out.add(account.copyWith(credential: plain));
      } catch (e, s) {
        Log.e('decode_account_credential: $e', s);
        out.add(account);
      }
    }
    return out;
  }

  /// 获取所有的解密账号（返回副本，不污染 DB 缓存对象）
  Future<List<Account>> getDecodeAccounts() async {
    final list = DBService.instance.getAllAccounts();
    if (AppSettingsController.instance.appSafeEnable.value &&
        AppSettingsController.instance.appStoreKey.value) {
      final key = await SecureStoreService.instance.getAppSecureKey();
      if (key == null || key.isEmpty) {
        return list;
      }
      return decodeAccounts(list, key);
    }
    return list;
  }

  /// 加密指定账号
  Future<void> encodeAccount(Account ac) async {
    var plainCredential = ac.credential;
    // 加密模式, 尝试写入, 无key直接重置所有数据
    if (AppSettingsController.instance.appSafeEnable.value) {
      if (AppSettingsController.instance.appStoreKey.value) {
        final key = await SecureStoreService.instance.getAppSecureKey();
        try {
          plainCredential = await AesUtils.encrypt(plainCredential, key!);
        } catch (e, s) {
          // 加密失败（密钥不可用/非法）不得以明文写回库（见 ISS-222）
          Log.e('encode_account_credential: $e', s);
          return;
        }
      } else {
        // 无 key：重置敏感数据后**必须返回**，不得再以明文写回（见 ISS-214）
        await reset();
        return;
      }
    }
    final dbAc = DBService.instance.getAccount(ac.id);
    // credential 更新入库
    if (dbAc?.credential != plainCredential) {
      final itemAc = ac.copyWith(credential: plainCredential);
      await DBService.instance.addAccount(itemAc);
    }
  }

  /// webdavPassword
  Future<String> getDecodeWPassword() async {
    var wPassword = LocalStorageService.instance.getValue(LocalStorageService.kWebDAVPassword, '');
    if (wPassword.isNotEmpty) {
      if (AppSettingsController.instance.appSafeEnable.value && AppSettingsController.instance.appStoreKey.value) {
        var secretKey = await SecureStoreService.instance.getAppSecureKey();
        try {
          wPassword = await AesUtils.decrypt(wPassword, secretKey!);
        } catch (e, s) {
          Log.e('decode_webdav_password: $e', s);
          wPassword = '';
        }
      }
    }
    return wPassword;
  }

  Future<void> encodeWPassword(String wPassword) async {
    if (wPassword.isNotEmpty) {
      // 逻辑同 encodeAccount
      if (AppSettingsController.instance.appSafeEnable.value) {
        if (AppSettingsController.instance.appStoreKey.value) {
          var secretKey = await SecureStoreService.instance.getAppSecureKey();
          wPassword = await AesUtils.encrypt(wPassword, secretKey!);
        } else {
          await reset();
        }
      }
    }
    LocalStorageService.instance.setValue(LocalStorageService.kWebDAVPassword, wPassword);
  }

  Future<void> decodeData() async {
    // check secretKey right-> decode
    var secretKey = await SecureStoreService.instance.getAppSecureKey();
    if (secretKey != null && secretKey.isNotEmpty) {
      // decode account.credential
      List<Account> accounts = DBService.instance.getAllAccounts();
      for (final account in accounts) {
        if (account.credential.isEmpty) {
          continue;
        }
        try {
          String plain = await AesUtils.decrypt(account.credential, secretKey);
          Account upgradeAc = account.copyWith(credential: plain);
          await DBService.instance.addAccount(upgradeAc);
        } catch (e, s) {
          // error ( secretKey wrong/ data bad / plain )
          Log.e('decode_data id=${account.id}: $e', s);
        }
      }
      // decode webdev.password
      String wPassword = LocalStorageService.instance.getValue(LocalStorageService.kWebDAVPassword, "");
      if (wPassword.isNotEmpty) {
        try {
          String plain = await AesUtils.decrypt(wPassword, secretKey);
          LocalStorageService.instance.setValue(LocalStorageService.kWebDAVPassword, plain);
        } catch (e, s) {
          Log.e('decode_webdav_password: $e', s);
        }
      }

      AppSettingsController.instance.setAppAuthorName(kSafeMarker);
      AppSettingsController.instance.setAppSafeEnable(false);
      SmartDialog.showToast('已解密敏感数据');
    } else {
      // 无密钥时不得静默 no-op：明确提示，避免「加密数据」开关关不掉（见 ISS-219）
      SmartDialog.showToast('未找到可用密钥，无法解密数据');
    }
  }

  Future<void> encodeData() async {
    var secretKey = await SecureStoreService.instance.getAppSecureKey();
    if (secretKey != null && secretKey.isNotEmpty) {
      List<Account> accounts = DBService.instance.getAllAccounts();
      for (final account in accounts) {
        if (account.credential.isEmpty) {
          continue;
        }
        try {
          String plain = await AesUtils.encrypt(account.credential, secretKey);
          Account upgradeAc = account.copyWith(credential: plain);
          await DBService.instance.addAccount(upgradeAc);
        } catch (e, s) {
          // error ( secretKey wrong/ data bad / plain )
          Log.e('encode_data id=${account.id}: $e', s);
        }
      }
      // encode webdev.password
      String wPassword = LocalStorageService.instance.getValue(LocalStorageService.kWebDAVPassword, "");
      if (wPassword.isNotEmpty) {
        String plain = await AesUtils.encrypt(wPassword, secretKey);
        LocalStorageService.instance.setValue(LocalStorageService.kWebDAVPassword, plain);
      }

      String authorName = await AesUtils.encrypt(AppSettingsController.instance.appAuthorName, secretKey);
      AppSettingsController.instance.setAppAuthorName(authorName);
      AppSettingsController.instance.setAppSafeEnable(true);
      SmartDialog.showToast('已加密敏感数据');
    } else {
      SmartDialog.showToast('key无效');
    }
  }

  /// 检查数据和key关联性
  Future<void> checkKeyValid() async {
    var res = false;
    var secretKey = await SecureStoreService.instance.getAppSecureKey();
    if (secretKey != null && secretKey.isNotEmpty) {
      // check decode
      if (AppSettingsController.instance.appSafeEnable.value) {
        try {
          String plain = await AesUtils.decrypt(AppSettingsController.instance.appAuthorName, secretKey);
          res = plain == kSafeMarker;
        } catch (e) {
          res = false;
        }
      } else {
        res = true;
      }
    } else {
      res = false;
    }
    AppSettingsController.instance.appStoreKey.value = res;
  }

  /// 重置所有敏感数据
  Future<void> reset() async {
    List<Account> list = DBService.instance.getAllAccounts();
    for (final account in list) {
      var logout = account.copyWith(
        id: account.id,
        userName: '',
        credential: '',
        isActive: false,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      await DBService.instance.addAccount(logout);
    }
    await SecureStoreService.instance.removeAppSecretKey();
    LocalStorageService.instance.setValue(LocalStorageService.kWebDAVPassword, '');
    AppSettingsController.instance.setAppAuthorName(kSafeMarker);
    AppSettingsController.instance.setAppSafeEnable(false);
    AppSettingsController.instance.appStoreKey.value = false;
    SmartDialog.showToast('已重置敏感数据');
  }

  bool _inited = false;

  @override
  Future<void> onInit() async {
    // 幂等：避免 main.dart 里 Get.put 与手动 onInit 双跑（见 ISS-217）
    if (_inited) {
      super.onInit();
      return;
    }
    _inited = true;
    await checkKeyValid();
    super.onInit();
  }
}
