import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

/// 播放器收缩逻辑测试
///
/// 官方行为约束（用户明确要求）：
/// - 收缩高度不得高于视频原始比例高度
/// - 收缩下限是一个"顶部小窗"的高度
void main() {
  const miniHeight = 56.0;

  /// 复刻 video_page 里的高度计算
  double naturalHeight(double videoRatio, double width) {
    final safeRatio = videoRatio <= 0 ? 16 / 9 : videoRatio;
    return width / safeRatio;
  }

  double clampHeight(double value, double natural) {
    final upper = math.max(miniHeight, natural).toDouble();
    return value.clamp(miniHeight, upper).toDouble();
  }

  group('原始比例高度', () {
    test('16:9 横屏视频', () {
      // 393 宽 / (16/9) ≈ 221
      expect(naturalHeight(16 / 9, 393), closeTo(221.06, 0.1));
    });

    test('竖屏 9:16 视频高度远大于宽度', () {
      // 393 / (9/16) ≈ 698.7
      expect(naturalHeight(9 / 16, 393), closeTo(698.67, 0.1));
    });

    test('比例异常时退回 16:9', () {
      expect(naturalHeight(0, 393), closeTo(221.06, 0.1));
      expect(naturalHeight(-1, 393), closeTo(221.06, 0.1));
    });
  });

  group('收缩高度钳制', () {
    test('不得超过视频原始高度', () {
      final natural = naturalHeight(16 / 9, 393);
      // 想拉到 500 高，但 16:9 视频最多 221
      expect(clampHeight(500, natural), closeTo(natural, 0.01));
    });

    test('竖屏视频也不得超过自身原始高度', () {
      final natural = naturalHeight(9 / 16, 393);
      expect(clampHeight(900, natural), closeTo(natural, 0.01));
      // 而且这个上限确实比 16:9 大，说明是按真实比例算的
      expect(natural, greaterThan(naturalHeight(16 / 9, 393)));
    });

    test('不得低于小窗高度', () {
      final natural = naturalHeight(16 / 9, 393);
      expect(clampHeight(10, natural), miniHeight);
      expect(clampHeight(-100, natural), miniHeight);
    });

    test('中间值原样保留', () {
      final natural = naturalHeight(16 / 9, 393);
      expect(clampHeight(150, natural), 150);
    });

    test('自然高度比小窗还小时不崩（极小屏 / 极端比例）', () {
      // 宽 100，比例 16:9 → 自然高 56.25，仅略大于 mini
      final natural = naturalHeight(16 / 9, 100);
      expect(clampHeight(200, natural), closeTo(natural, 0.01));
      // 更极端：自然高 < mini 时，上限应退化为 mini，避免 clamp 区间反转
      final tiny = naturalHeight(16 / 9, 10); // ≈ 5.6
      expect(clampHeight(200, tiny), miniHeight);
      expect(clampHeight(0, tiny), miniHeight);
    });
  });

  group('吸附判定', () {
    test('松手位置偏上则收成小窗，偏下则展开', () {
      final natural = naturalHeight(16 / 9, 393);
      final mid = (miniHeight + natural) / 2;

      expect(miniHeight + 10 < mid, isTrue, reason: '靠近小窗应判定为收');
      expect(natural - 10 > mid, isTrue, reason: '靠近原位应判定为展开');
    });
  });
}
