import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/utils/encrypt/aes_util.dart';
import 'package:simple_live_app/models/db/account.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/resources/settings_sync_resource.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/resources/user_account_cookie_sync_resource.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/safe_service.dart';

/// 上游「安全模式」合入的回归测试（对应台账 ISS-211 / ISS-212 / ISS-215 / ISS-222）。
/// 说明：本沙箱无法本地跑 `flutter test`（media_kit native-assets 需 clang），
///       本文件由 CI test.yml 执行。
void main() {
  test('ISS-211 设置同步必须排除「安全模式」相关键', () {
    final keys = SettingsSyncResource.excludedSyncKeys;
    expect(keys.contains(kAppSafeEnable), isTrue, reason: 'kAppSafeEnable 跨设备同步会触发对端破坏性 reset()');
    expect(keys.contains(kAppAuthorName), isTrue, reason: 'kAppAuthorName 是密钥哨兵密文，不能跨设备同步');
    expect(keys.contains(LocalStorageService.kWebDAVPassword), isTrue);
    expect(keys.contains(LocalStorageService.kHiveDbVer), isTrue);
  });

  test('ISS-212 decodeAccounts 返回副本、绝不改写入参对象', () async {
    final key = await AesUtils.generateKey();
    final enc = await AesUtils.encrypt('{"cookie":"SECRET"}', key);
    final a = Account(
      id: '1',
      siteId: 'bilibili',
      credential: enc,
      createdAt: 1,
      updatedAt: 1,
    );

    final out = await SafeService.decodeAccounts([a], key);

    expect(a.credential, equals(enc), reason: '原对象必须保持密文（否则明文会被 webdav 上传）');
    expect(out.first.credential, equals('{"cookie":"SECRET"}'));
    expect(identical(out.first, a), isFalse, reason: '必须是新对象');
  });

  test('ISS-212 解密失败时保持原文（不降级成明文/不丢数据）', () async {
    final key = await AesUtils.generateKey();
    final wrongKey = await AesUtils.generateKey();
    final enc = await AesUtils.encrypt('x', key);
    final a = Account(
      id: '1',
      siteId: 'douyu',
      credential: enc,
      createdAt: 1,
      updatedAt: 1,
    );

    final out = await SafeService.decodeAccounts([a], wrongKey);
    expect(out.first.credential, equals(enc));
  });

  test('ISS-222 AesUtils 加解密往返 + 短输入 fail-fast', () async {
    final key = await AesUtils.generateKey();
    final c = await AesUtils.encrypt('hello 世界', key);
    expect(await AesUtils.decrypt(c, key), equals('hello 世界'));

    expectLater(
      AesUtils.decrypt(base64Encode(<int>[1, 2, 3]), key),
      throwsA(isA<FormatException>()),
      reason: '非密文/截断数据应抛 FormatException，而非 sublist 的 RangeError',
    );
  });

  test('ISS-215 merge 遇到本地没有的 siteId 不崩且并入', () {
    final res = UserAccountCookieSyncResource();
    final local = [
      Account(id: '0', siteId: 'bilibili', credential: 'a', createdAt: 1, updatedAt: 1),
    ];
    final remote = [
      Account(id: '9', siteId: 'huya', credential: 'b', createdAt: 2, updatedAt: 2),
    ];

    final merged = res.merge(local, remote);

    expect(merged.any((e) => e.siteId == 'huya'), isTrue, reason: '远端新站点的账号应被并入（旧实现此处 null 断言崩溃）');
    expect(merged.any((e) => e.siteId == 'bilibili'), isTrue);
  });
}
