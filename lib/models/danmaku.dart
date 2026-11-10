/// 一条弹幕
class Danmaku {
  const Danmaku({
    required this.time,
    required this.mode,
    required this.fontSize,
    required this.color,
    required this.timestamp,
    required this.pool,
    required this.senderHash,
    required this.text,
  });

  /// 出现时间（秒）
  final double time;

  /// 1/2/3 滚动；4 底部；5 顶部；6 逆向；7 高级；8 代码；9 BAS
  final int mode;
  final int fontSize;
  final int color;
  final int timestamp;
  final int pool;
  final String senderHash;
  final String text;

  bool get isScroll => mode == 1 || mode == 2 || mode == 3 || mode == 6;
  bool get isTop => mode == 5;
  bool get isBottom => mode == 4;

  /// p 属性格式：
  /// 时间,模式,字号,颜色,时间戳,池,发送者hash,数据库id,...
  /// 注意文本里可能有逗号，所以按前 7 个逗号切分。
  static Danmaku? tryParse(String p, String text) {
    final parts = p.split(',');
    if (parts.length < 7) return null;
    final time = double.tryParse(parts[0]);
    if (time == null) return null;
    final mode = int.tryParse(parts[1]) ?? 1;
    final fontSize = int.tryParse(parts[2]) ?? 25;
    final color = int.tryParse(parts[3]) ?? 0xFFFFFF;
    final ts = int.tryParse(parts[4]) ?? 0;
    final pool = int.tryParse(parts[5]) ?? 0;
    final hash = parts[6];
    return Danmaku(
      time: time,
      mode: mode,
      fontSize: fontSize,
      color: color,
      timestamp: ts,
      pool: pool,
      senderHash: hash,
      text: text,
    );
  }
}

/// 弹幕轨道类型
enum DanmakuLane { scroll, top, bottom }
