import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/utils/volume_norm.dart';

/// 音量均衡（两段链：dynaudnorm 轻压 + loudnorm 定标准）纯逻辑单测。
///
/// 回归锚点：跨直播间响度一致性（ISS-260）。改动滤镜链、回读判定或决策表时
/// 必须同步本文件——「链没挂全」这类静默降级否则不会被 CI 拦住。
void main() {
  group('滤镜链定义', () {
    test('两段链顺序：dynaudnorm 在前、loudnorm 在后（顺序不可反）', () {
      expect(volumeNormFilter, '$volumeNormPreFilter,$volumeNormPostFilter');
      expect(volumeNormFilter.indexOf('dynaudnorm'),
          lessThan(volumeNormFilter.indexOf('loudnorm')));
    });

    test('参数与实测选型一致（f=250/g=15/p=0.95/m=8/r=0.5 + LRA=5）', () {
      expect(volumeNormPreFilter, 'dynaudnorm=f=250:g=15:p=0.95:m=8:r=0.5');
      expect(volumeNormPostFilter, 'loudnorm=I=-16:TP=-1.5:LRA=5');
    });

    test('链内不含空格（mpv af 语法）', () {
      expect(volumeNormFilter.contains(' '), isFalse);
    });
  });

  group('volumeNormSupportedFromReadback（回读判定）', () {
    test('两个滤镜都在 → 支持', () {
      expect(
        volumeNormSupportedFromReadback(
            'dynaudnorm=f=250:g=15:p=0.95:m=8:r=0.5,loudnorm=I=-16:TP=-1.5:LRA=5'),
        isTrue,
      );
    });

    test('只有 loudnorm（旧产物）→ 不支持（回归：链没挂全不能算支持）', () {
      expect(
        volumeNormSupportedFromReadback('loudnorm=I=-16:TP=-1.5:LRA=11'),
        isFalse,
      );
    });

    test('空串 / 其它滤镜 → 不支持', () {
      expect(volumeNormSupportedFromReadback(''), isFalse);
      expect(volumeNormSupportedFromReadback('equalizer'), isFalse);
    });
  });

  group('volumeNormLogIndicatesFailure（静默降级防线）', () {
    test('错误关键字命中（大小写不敏感）', () {
      expect(volumeNormLogIndicatesFailure('Cannot find filter dynaudnorm'),
          isTrue);
      expect(
          volumeNormLogIndicatesFailure('audio filter not found: no such filter'),
          isTrue);
      expect(volumeNormLogIndicatesFailure('Failed to create filter chain'),
          isTrue);
      expect(volumeNormLogIndicatesFailure('UNKNOWN FILTER foo'), isTrue);
    });

    test('正常日志不误报', () {
      expect(volumeNormLogIndicatesFailure('Playing: 1080p'), isFalse);
      expect(volumeNormLogIndicatesFailure('audio: 48000 Hz stereo'), isFalse);
      expect(volumeNormLogIndicatesFailure(''), isFalse);
    });
  });

  group('决策表', () {
    test('volumeNormShouldApply：仅「用户开 + 已知支持」才挂链', () {
      expect(volumeNormShouldApply(userOn: true, supported: true), isTrue);
      expect(volumeNormShouldApply(userOn: true, supported: false), isFalse);
      expect(volumeNormShouldApply(userOn: true, supported: null), isFalse);
      expect(volumeNormShouldApply(userOn: false, supported: true), isFalse);
    });

    test('volumeNormShouldPreApply：能力未知也预挂（首帧回读兜底）', () {
      expect(volumeNormShouldPreApply(userOn: true, supported: true), isTrue);
      expect(volumeNormShouldPreApply(userOn: true, supported: null), isTrue);
      expect(volumeNormShouldPreApply(userOn: true, supported: false), isFalse);
      expect(volumeNormShouldPreApply(userOn: false, supported: null), isFalse);
    });
  });
}
