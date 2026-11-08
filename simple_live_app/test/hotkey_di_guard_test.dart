import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/services/hot_key_service.dart';

/// P0-1 回归测试（ISS-237 / RT-132）：
/// 上游 31f40ed 把 HotKeyService 注册限定在桌面端（main.dart 非 Android/iOS 分支），
/// 但 live_room_controller.onInit 无条件调 _initHotKeyWhenFull() → 移动端
/// Get.find<HotKeyService>() 必抛（'"HotKeyService" not found...'）导致进房崩溃。
/// 修复：_initHotKeyWhenFull 加 Get.isRegistered 守卫。
/// 本测试保护 DI 不变量：未注册时 Get.find 必须抛（一旦有人删守卫/改注册条件，此测试变红）。
void main() {
  setUp(() {
    // 隔离：确保本文件执行前无残留注册
    if (Get.isRegistered<HotKeyService>()) {
      Get.delete<HotKeyService>();
    }
  });

  test('RT-132: HotKeyService 未注册时 Get.find 必抛（移动端崩溃路径的守卫前提）', () {
    expect(Get.isRegistered<HotKeyService>(), isFalse);
    expect(() => Get.find<HotKeyService>(), throwsA(anything),
        reason: '移动端 main.dart 不注册 HotKeyService；守卫缺失时 _initHotKeyWhenFull 的 Get.find 即此异常');
  });
}
