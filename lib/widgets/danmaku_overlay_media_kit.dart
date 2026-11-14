import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../models/danmaku.dart';
import '../services/bili_player.dart';

/// 弹幕渲染层（media_kit 版）
///
/// 与 video_player 版的区别：位置来源从 `VideoPlayerController.value.position`
/// 换成 media_kit 的 `Player.stream.position`。其余排版 / 轨道分配逻辑不变。
class DanmakuOverlayMediaKit extends StatefulWidget {
  const DanmakuOverlayMediaKit({
    super.key,
    required this.player,
    required this.danmakus,
    this.enabled = true,
    this.opacity = 0.9,
    this.fontScale = 1.0,
    this.areaRatio = 0.75,
  });

  final BiliPlayer player;
  final List<Danmaku> danmakus;
  final bool enabled;
  final double opacity;
  final double fontScale;

  /// 弹幕最多占据画面高度的比例
  final double areaRatio;

  @override
  State<DanmakuOverlayMediaKit> createState() => _DanmakuOverlayMediaKitState();
}

class _DanmakuOverlayMediaKitState extends State<DanmakuOverlayMediaKit>
    with SingleTickerProviderStateMixin {
  static const double _travelSeconds = 8.0;
  static const double _fixedSeconds = 4.0;

  List<_Prepared> _items = const [];
  List<Danmaku>? _preparedFor;
  Size _preparedSize = Size.zero;
  double _preparedScale = 0;

  /// media_kit 的 position 流约 100~200ms 一次，用 Ticker 插值保证 60fps
  Ticker? _ticker;
  Duration _basePosition = Duration.zero;
  Duration _baseAt = Duration.zero;
  Duration _display = Duration.zero;

  @override
  void initState() {
    super.initState();
    _basePosition = widget.player.position;
    _display = _basePosition;
    _baseAt = _now();
    _ticker = createTicker(_onTick)..start();
    // 监听 media_kit 的位置流，重置插值基准
    widget.player.positionStream.listen((p) {
      if (!mounted) return;
      _basePosition = p;
      _baseAt = _now();
      _display = p;
    });
  }

  @override
  void didUpdateWidget(covariant DanmakuOverlayMediaKit oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.danmakus, widget.danmakus)) {
      _preparedFor = null;
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  Duration _now() => Duration(microseconds: DateTime.now().microsecondsSinceEpoch);

  void _onTick(Duration _) {
    if (!mounted || !widget.enabled) return;
    final playing = widget.player.isPlaying;
    Duration next;
    if (playing) {
      next = _basePosition + (_now() - _baseAt);
      final total = widget.player.duration;
      if (total > Duration.zero && next > total) next = total;
    } else {
      next = widget.player.position;
    }
    if (next != _display) {
      _display = next;
      setState(() {});
    }
  }

  void _prepare(Size size) {
    final danmakus = widget.danmakus;
    if (identical(_preparedFor, danmakus) &&
        _preparedSize == size &&
        _preparedScale == widget.fontScale) {
      return;
    }
    _preparedFor = danmakus;
    _preparedSize = size;
    _preparedScale = widget.fontScale;

    final baseFont = 16.0 * widget.fontScale;
    final lineHeight = baseFont * 1.5;
    final laneHeight = lineHeight + 4;
    final scrollLanes =
        math.max(1, (size.height * widget.areaRatio / laneHeight).floor());
    final fixedLanes = math.max(1, math.min(4, (size.height * 0.4 / laneHeight).floor()));

    final laneFree = List<double>.filled(scrollLanes, 0);
    final topFree = List<double>.filled(fixedLanes, 0);
    final bottomFree = List<double>.filled(fixedLanes, 0);

    final items = <_Prepared>[];
    for (final dm in danmakus) {
      if (dm.text.isEmpty) continue;
      final tp = _layout(dm, baseFont);
      final width = tp.width;

      if (dm.isScroll) {
        var lane = -1;
        for (var i = 0; i < scrollLanes; i++) {
          if (laneFree[i] <= dm.time) {
            lane = i;
            break;
          }
        }
        if (lane == -1) {
          var best = 0;
          for (var i = 1; i < scrollLanes; i++) {
            if (laneFree[i] < laneFree[best]) best = i;
          }
          lane = best;
        }
        final occupy = (width + 40) / (size.width + width) * _travelSeconds;
        laneFree[lane] = dm.time + occupy + 0.35;
        items.add(_Prepared(
          dm: dm,
          painter: tp,
          lane: lane,
          width: width,
          laneHeight: laneHeight,
        ));
      } else if (dm.isTop) {
        var lane = _pickLane(topFree, dm.time);
        topFree[lane] = dm.time + _fixedSeconds;
        items.add(_Prepared(
          dm: dm,
          painter: tp,
          lane: lane,
          width: width,
          laneHeight: laneHeight,
          fixedTop: true,
        ));
      } else if (dm.isBottom) {
        var lane = _pickLane(bottomFree, dm.time);
        bottomFree[lane] = dm.time + _fixedSeconds;
        items.add(_Prepared(
          dm: dm,
          painter: tp,
          lane: lane,
          width: width,
          laneHeight: laneHeight,
          fixedBottom: true,
        ));
      }
    }
    items.sort((a, b) => a.dm.time.compareTo(b.dm.time));
    _items = items;
  }

  int _pickLane(List<double> free, double time) {
    for (var i = 0; i < free.length; i++) {
      if (free[i] <= time) return i;
    }
    var best = 0;
    for (var i = 1; i < free.length; i++) {
      if (free[i] < free[best]) best = i;
    }
    return best;
  }

  TextPainter _layout(Danmaku dm, double fontSize) {
    final color = Color(0xFF000000 | (dm.color & 0xFFFFFF));
    final shadow = Shadow(
      color: Colors.black.withValues(alpha: 0.85),
      blurRadius: 3,
      offset: const Offset(1, 1),
    );
    final tp = TextPainter(
      text: TextSpan(
        text: dm.text,
        style: TextStyle(
          fontSize: fontSize,
          height: 1.2,
          color: color,
          fontWeight: FontWeight.w500,
          shadows: [shadow, shadow],
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    );
    tp.layout(maxWidth: 480);
    return tp;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || widget.danmakus.isEmpty) {
      return const SizedBox.shrink();
    }
    final position = _display.inMilliseconds / 1000.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (size.width <= 0 || size.height <= 0) return const SizedBox.shrink();
        _prepare(size);
        return IgnorePointer(
          child: Opacity(
            opacity: widget.opacity,
            child: CustomPaint(
              size: size,
              painter: _DanmakuPainter(
                items: _items,
                position: position,
                size: size,
                travelSeconds: _travelSeconds,
                fixedSeconds: _fixedSeconds,
                areaRatio: widget.areaRatio,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Prepared {
  _Prepared({
    required this.dm,
    required this.painter,
    required this.lane,
    required this.width,
    required this.laneHeight,
    this.fixedTop = false,
    this.fixedBottom = false,
  });

  final Danmaku dm;
  final TextPainter painter;
  final int lane;
  final double width;
  final double laneHeight;
  final bool fixedTop;
  final bool fixedBottom;
}

class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter({
    required this.items,
    required this.position,
    required this.size,
    required this.travelSeconds,
    required this.fixedSeconds,
    required this.areaRatio,
  });

  final List<_Prepared> items;
  final double position;
  final Size size;
  final double travelSeconds;
  final double fixedSeconds;
  final double areaRatio;

  @override
  void paint(Canvas canvas, Size canvasSize) {
    if (items.isEmpty || position <= 0) return;
    final maxScrollY = canvasSize.height * areaRatio;

    for (final item in items) {
      final elapsed = position - item.dm.time;
      if (item.fixedTop) {
        if (elapsed < 0 || elapsed > fixedSeconds) continue;
        final left = (canvasSize.width - item.width) / 2;
        if (left < 0) continue;
        final top = 6.0 + item.lane * item.laneHeight;
        if (top + item.laneHeight > maxScrollY) continue;
        _paintOne(canvas, item, left, top, _fade(elapsed, fixedSeconds));
      } else if (item.fixedBottom) {
        if (elapsed < 0 || elapsed > fixedSeconds) continue;
        final left = (canvasSize.width - item.width) / 2;
        if (left < 0) continue;
        final top = canvasSize.height - 10.0 - (item.lane + 1) * item.laneHeight;
        if (top < canvasSize.height * (1 - areaRatio) + 10) continue;
        _paintOne(canvas, item, left, top, _fade(elapsed, fixedSeconds));
      } else {
        if (elapsed < 0 || elapsed > travelSeconds) continue;
        final progress = elapsed / travelSeconds;
        final left = canvasSize.width - progress * (canvasSize.width + item.width);
        final top = 6.0 + item.lane * item.laneHeight;
        if (top + item.laneHeight > maxScrollY) continue;
        _paintOne(canvas, item, left, top, 1.0);
      }
    }
  }

  double _fade(double elapsed, double total) {
    const fadeIn = 0.15;
    const fadeOut = 0.4;
    if (elapsed < fadeIn) return (elapsed / fadeIn).clamp(0.0, 1.0);
    final remain = total - elapsed;
    if (remain < fadeOut) return (remain / fadeOut).clamp(0.0, 1.0);
    return 1.0;
  }

  void _paintOne(Canvas canvas, _Prepared item, double left, double top, double alpha) {
    if (alpha >= 0.99) {
      item.painter.paint(canvas, Offset(left, top));
    } else if (alpha > 0.01) {
      canvas.saveLayer(
        Rect.fromLTWH(left - 4, top - 4, item.width + 8, item.laneHeight + 8),
        Paint()..color = Colors.white.withValues(alpha: alpha),
      );
      item.painter.paint(canvas, Offset(left, top));
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _DanmakuPainter old) {
    return old.position != position || !identical(old.items, items) || old.size != size;
  }
}
