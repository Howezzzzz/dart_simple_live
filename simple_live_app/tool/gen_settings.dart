// 运行设置代码生成器：扫描 app_settings_controller.dart 的 @SettingItem，
// 重新生成 app_settings_controller.g.dart。
// 用法（在 simple_live_app/ 下）：dart run tool/gen_settings.dart
import 'dart:io';

import 'package:simple_live_app/app/utils/setting_gen_util.dart';

void main() {
  final target = SettingGenUtil.generateForFile(
    File('lib/app/controller/app_settings_controller.dart'),
  );
  print('generated: ${target.path}');
}