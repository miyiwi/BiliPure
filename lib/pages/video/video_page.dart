import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../api/bili_api.dart';
import '../../core/format.dart';
import '../../models/comment.dart';
import '../../models/danmaku.dart';
import '../../models/feed_item.dart';
import '../../models/play_info.dart';
import '../../models/video_detail.dart';
import '../../services/danmaku_service.dart';
import '../../widgets/danmaku_overlay.dart';
import '../../widgets/error_view.dart';
import '../../widgets/video_card.dart';
import '../space/space_page.dart';

/// 视频播放页
///
/// 结构对齐官方客户端：
/// - 顶部播放器，暂停时全屏任意位置上下滑动即可收缩为「顶部小窗」
/// - 展开高度以视频原始比例高度为上限，永远不会超过
/// - 下半部分是「简介 / 评论」两个 Tab
///   简介页放视频简介、标签、相关推荐；评论页单独承载评论列表
class VideoPage extends StatefulWidget {
  const VideoPage({
    super.key,
    required this.bvid,
    this.cid,
    this.title = '',
    this.cover = '',
  });

  final String bvid;
  final int? cid;
  final String title;
  final String cover;

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> with SingleTickerProviderStateMixin {
  VideoPlayerController? _controller;
  VideoDetail? _detail;
  PlayInfo? _playInfo;
  List<Danmaku> _danmakus = const [];
  List<FeedItem> _related = const [];
  List<String> _tags = const [];

  bool _loading = true;
  String? _error;
  int _currentCid = 0;
  int _currentPageIndex = 0;
  int _selectedQuality = 64;

  bool _danmakuOn = true;
  bool _showControls = true;
  Timer? _hideTimer;

  /// 播放器高度。0 表示还没按视频比例算过。
  double _playerHeight = 0;

  /// 收缩动画用
  bool _collapsing = false;

  // 三连状态
  bool _liked = false;
  int _likedCount = 0;
  int _coinCount = 0;
  bool _faved = false;
  int _favCount = 0;
  bool _interacting = false;

  // 评论
  List<Comment> _comments = const [];
  int _commentTotal = 0;
  int _commentPage = 1;
  bool _commentLoading = false;
  bool _commentHasMore = true;
  bool _commentsLoaded = false;

  // 全屏
  bool _fullscreen = false;

  // 手势
  Timer? _longPressTimer;
  bool _longPressFired = false;
  DateTime _lastTap = DateTime.fromMillisecondsSinceEpoch(0);

  late TabController _tabController;

  /// 播放器收缩后的高度（顶部小窗）
  static const double _miniHeight = 56;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (!mounted) return;
      setState(() {});
      // 切到评论页才去拉评论，避免浪费请求
      if (_tabController.index == 1 && !_commentsLoaded) {
        _loadComments(reset: true);
      }
    });
    _currentCid = widget.cid ?? 0;
    _load();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _longPressTimer?.cancel();
    _tabController.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    _controller?.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- 数据

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await BiliApi.instance.videoDetail(widget.bvid);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _likedCount = detail.like;
        _favCount = detail.favorite;
      });
      if (_currentCid == 0) {
        _currentCid = detail.firstPage.cid;
        _currentPageIndex = 0;
      } else {
        final idx = detail.pages.indexWhere((p) => p.cid == _currentCid);
        if (idx >= 0) _currentPageIndex = idx;
      }
      await _loadPlay(_currentCid);
      if (!mounted) return;
      unawaited(_loadRelated());
      unawaited(_loadTags());
      unawaited(_loadInteractionState());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _loadRelated() async {
    try {
      final list = await BiliApi.instance.related(widget.bvid);
      if (!mounted) return;
      setState(() => _related = list);
    } catch (_) {}
  }

  Future<void> _loadTags() async {
    final tags = await BiliApi.instance.tags(widget.bvid);
    if (!mounted) return;
    setState(() => _tags = tags);
  }

  Future<void> _loadInteractionState() async {
    final api = BiliApi.instance;
    final liked = await api.hasLike(widget.bvid);
    final coins = await api.coinCount(widget.bvid);
    final aid = _detail?.aid ?? 0;
    final faved = aid > 0 ? await api.hasFav(aid) : false;
    if (!mounted) return;
    setState(() {
      _liked = liked;
      _coinCount = coins;
      _faved = faved;
    });
  }

  Future<void> _loadPlay(int cid) async {
    if (cid <= 0) throw Exception('找不到视频分 P');
    final info = await BiliApi.instance.playUrl(
      bvid: widget.bvid,
      cid: cid,
      qn: _selectedQuality,
    );
    if (!mounted) return;
    setState(() {
      _playInfo = info;
      _selectedQuality = info.quality;
    });
    await _startPlayer(info);
    if (!mounted) return;
    setState(() => _loading = false);
    unawaited(_loadDanmaku(cid));
  }

  Future<void> _loadDanmaku(int cid) async {
    final list = await DanmakuService.instance.fetch(cid);
    if (!mounted) return;
    setState(() => _danmakus = list);
  }

  Future<void> _startPlayer(PlayInfo info) async {
    final old = _controller;
    _controller = null;
    await old?.dispose();

    if (info.urls.isEmpty) {
      if (info.isDash) {
        throw Exception('该视频仅提供 DASH 分离流，当前版本暂不支持');
      }
      throw Exception('播放地址为空');
    }

    final uri = Uri.parse(info.urls.first);
    final controller = VideoPlayerController.networkUrl(
      uri,
      httpHeaders: const {
        // CDN 会校验 UA，缺省 UA 会返回 403
        'Referer': 'https://www.bilibili.com/',
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
            'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
      },
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
    );
    await controller.initialize();
    // 监听器必须 setState，否则暂停后按钮图标不会更新
    controller.addListener(_onPlayerTick);
    await controller.play();
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() {
      _controller = controller;
      _playerHeight = 0; // 重新按比例算
    });
    _scheduleHide();
  }

  void _onPlayerTick() {
    if (!mounted) return;
    final c = _controller;
    if (c == null) return;
    setState(() {});
    if (c.value.isCompleted) {
      _hideTimer?.cancel();
      if (!_showControls) setState(() => _showControls = true);
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (_controller?.value.isPlaying != true) return;
      setState(() => _showControls = false);
    });
  }

  /// 视频原始比例下的自然高度（展开上限）
  double _naturalHeight(double videoRatio, double width) {
    final safeRatio = videoRatio <= 0 ? 16 / 9 : videoRatio;
    return width / safeRatio;
  }

  // ------------------------------------------------------------- 手势

  void _togglePlay() {
    final c = _controller;
    if (c == null) return;
    if (c.value.isPlaying) {
      c.pause();
      setState(() => _showControls = true);
      _hideTimer?.cancel();
    } else {
      c.play();
      _scheduleHide();
    }
    setState(() {});
  }

  void _onTapUp() {
    if (_longPressFired) {
      _longPressFired = false;
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastTap) < const Duration(milliseconds: 260)) {
      _lastTap = DateTime.fromMillisecondsSinceEpoch(0);
      _togglePlay();
      return;
    }
    _lastTap = now;
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHide();
  }

  void _onLongPressStart() {
    _longPressFired = true;
    _longPressTimer?.cancel();
    _longPressTimer = Timer(const Duration(milliseconds: 550), () {
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      _tripleAction();
    });
  }

  void _onLongPressEnd() {
    _longPressTimer?.cancel();
    if (mounted) {
      Future<void>.delayed(const Duration(milliseconds: 60), () {
        _longPressFired = false;
      });
    }
  }

  /// 暂停时上下滑动收缩 / 展开播放器
  ///
  /// 官方行为：暂停状态下在页面任意位置竖向滑动都能收缩，
  /// 展开高度不超过视频原始比例高度。
  void _onVerticalDragStart(DragStartDetails d, double natural) {
    // 播放中不响应收缩，避免误触
    if (_controller?.value.isPlaying == true) return;
    // 展开上限永远不超过视频原始比例高度
    if (_playerHeight <= 0) _playerHeight = natural;
  }

  void _onVerticalDragUpdate(DragUpdateDetails d, double natural) {
    if (_controller?.value.isPlaying == true) return;
    if (_playerHeight <= 0) _playerHeight = natural;
    final next = (_playerHeight - d.delta.dy);
    final upper = math.max(_miniHeight, natural).toDouble();
    setState(() {
      _playerHeight = next.clamp(_miniHeight, upper).toDouble();
    });
  }

  void _onVerticalDragEnd(DragEndDetails d, double natural) {
    if (_controller?.value.isPlaying == true) return;
    if (_playerHeight <= 0) return;
    final velocity = d.primaryVelocity ?? 0;
    // 快速上滑 → 直接收成小窗；快速下滑 → 展开
    if (velocity < -300) {
      _animateTo(_miniHeight, natural);
    } else if (velocity > 300) {
      _animateTo(natural, natural);
    } else {
      // 松手时按位置吸附
      final mid = (_miniHeight + natural) / 2;
      _animateTo(_playerHeight < mid ? _miniHeight : natural, natural);
    }
  }

  void _animateTo(double target, double natural) {
    final from = _playerHeight;
    // math.max 返回 num，这里显式转成 double
    final upper = math.max(_miniHeight, natural).toDouble();
    final clamped = target.clamp(_miniHeight, upper).toDouble();
    final start = DateTime.now();
    const duration = Duration(milliseconds: 180);
    setState(() => _collapsing = true);
    Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final t = DateTime.now().difference(start).inMilliseconds / duration.inMilliseconds;
      if (t >= 1) {
        timer.cancel();
        setState(() {
          _playerHeight = clamped;
          _collapsing = false;
        });
        return;
      }
      // easeOutCubic
      final e = 1 - math.pow(1 - t, 3);
      setState(() => _playerHeight = from + (clamped - from) * e);
    });
  }

  // ------------------------------------------------------------- 三连

  Future<void> _tripleAction() async {
    if (_interacting) return;
    _interacting = true;
    try {
      final api = BiliApi.instance;
      final results = <String>[];

      final like = await api.like(widget.bvid, liked: true, aid: _detail?.aid ?? 0);
      if (like.ok) {
        if (!_liked) setState(() => _likedCount += 1);
        setState(() => _liked = true);
        results.add('点赞');
      }

      if (_coinCount < 2) {
        final coin = await api.coin(widget.bvid, multiply: 1);
        if (coin.ok) {
          setState(() => _coinCount += 1);
          results.add('投币');
        }
      }

      if (!_faved && (_detail?.aid ?? 0) > 0) {
        final fav = await api.favorite(_detail!.aid);
        if (fav.ok) {
          setState(() {
            _faved = true;
            _favCount += 1;
          });
          results.add('收藏');
        }
      }

      if (!mounted) return;
      if (results.isEmpty) {
        final canWrite = await BiliApi.instance.canWrite();
        _toast(canWrite ? '操作未完成，请稍后重试' : '请先扫码登录');
      } else {
        _toast('已${results.join('、')}');
      }
    } finally {
      _interacting = false;
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _toggleLike() async {
    final api = BiliApi.instance;
    final target = !_liked;
    final r = await api.like(widget.bvid, liked: target, aid: _detail?.aid ?? 0);
    if (!mounted) return;
    if (r.ok) {
      setState(() {
        _liked = target;
        _likedCount += target ? 1 : -1;
        if (_likedCount < 0) _likedCount = 0;
      });
    } else {
      _toast(r.message ?? '操作失败');
    }
  }

  Future<void> _addCoin() async {
    final r = await BiliApi.instance.coin(widget.bvid, multiply: 1);
    if (!mounted) return;
    if (r.ok) {
      setState(() => _coinCount = (_coinCount + 1).clamp(0, 2));
      _toast('投币成功');
    } else {
      _toast(r.message ?? '投币失败');
    }
  }

  Future<void> _toggleFav() async {
    final aid = _detail?.aid ?? 0;
    if (aid <= 0) return;
    if (_faved) {
      _toast('已收藏');
      return;
    }
    final r = await BiliApi.instance.favorite(aid);
    if (!mounted) return;
    if (r.ok) {
      setState(() {
        _faved = true;
        _favCount += 1;
      });
      _toast('收藏成功');
    } else {
      _toast(r.message ?? '收藏失败');
    }
  }

  Future<void> _loadComments({required bool reset}) async {
    if (_commentLoading) return;
    if (!reset && !_commentHasMore) return;
    setState(() => _commentLoading = true);
    try {
      final page = reset ? 1 : _commentPage + 1;
      final result = await BiliApi.instance.comments(
        aid: _detail?.aid ?? 0,
        page: page,
      );
      if (!mounted) return;
      setState(() {
        if (reset) {
          _comments = result.comments;
          _commentPage = 1;
        } else {
          _comments = [..._comments, ...result.comments];
          _commentPage = page;
        }
        _commentTotal = result.total;
        _commentHasMore = result.hasMore;
        _commentsLoaded = true;
      });
    } catch (_) {
    } finally {
      if (mounted) setState(() => _commentLoading = false);
    }
  }

  Future<void> _switchPage(int index) async {
    final detail = _detail;
    if (detail == null || index < 0 || index >= detail.pages.length) return;
    final page = detail.pages[index];
    if (page.cid == _currentCid) return;
    setState(() {
      _currentPageIndex = index;
      _currentCid = page.cid;
      _loading = true;
      _danmakus = const [];
    });
    try {
      await _loadPlay(page.cid);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _switchQuality(int qn) async {
    if (qn == _selectedQuality) return;
    final pos = _controller?.value.position ?? Duration.zero;
    final wasPlaying = _controller?.value.isPlaying ?? false;
    setState(() {
      _selectedQuality = qn;
      _loading = true;
    });
    try {
      final info = await BiliApi.instance.playUrl(
        bvid: widget.bvid,
        cid: _currentCid,
        qn: qn,
      );
      if (!mounted) return;
      setState(() => _playInfo = info);
      await _startPlayer(info);
      final c = _controller;
      if (c != null && pos > Duration.zero) {
        await c.seekTo(pos);
        if (wasPlaying) await c.play();
      }
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _openVideo(FeedItem item) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VideoPage(
          bvid: item.bvid,
          cid: item.cid > 0 ? item.cid : null,
          title: item.title,
          cover: item.cover,
        ),
      ),
    );
  }

  void _openSpace() {
    final d = _detail;
    if (d == null || d.ownerMid <= 0) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SpacePage(
          mid: d.ownerMid,
          name: d.ownerName,
          face: d.ownerFace,
        ),
      ),
    );
  }

  Future<void> _toggleFullscreen() async {
    setState(() => _fullscreen = !_fullscreen);
    if (_fullscreen) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  // ------------------------------------------------------------- 构建

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final videoRatio =
        c != null && c.value.isInitialized && c.value.aspectRatio > 0
            ? c.value.aspectRatio
            : 16 / 9;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      // 播放页黑底，状态栏图标必须白色
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.black,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _fullscreen
            ? _buildFullscreen(c, videoRatio)
            : _buildNormal(c, videoRatio),
      ),
    );
  }

  Widget _buildFullscreen(VideoPlayerController? c, double ratio) {
    return GestureDetector(
      onTapUp: (_) => _onTapUp(),
      onLongPressStart: (_) => _onLongPressStart(),
      onLongPressEnd: (_) => _onLongPressEnd(),
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: c != null && c.value.isInitialized
                  ? AspectRatio(aspectRatio: ratio, child: VideoPlayer(c))
                  : const CircularProgressIndicator(color: Colors.white),
            ),
            if (c != null && c.value.isInitialized)
              DanmakuOverlay(
                controller: c,
                danmakus: _danmakus,
                enabled: _danmakuOn,
              ),
            if (_showControls && c != null && c.value.isInitialized)
              _buildControls(c, fullscreen: true),
          ],
        ),
      ),
    );
  }

  Widget _buildNormal(VideoPlayerController? c, double ratio) {
    final width = MediaQuery.sizeOf(context).width;
    // 展开上限 = 视频原始比例高度，绝不会超过
    final natural = _naturalHeight(ratio, width);
    if (_playerHeight <= 0) _playerHeight = natural;
    _playerHeight =
        _playerHeight.clamp(_miniHeight, math.max(_miniHeight, natural));

    final mini = _playerHeight <= _miniHeight + 0.5;

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onVerticalDragStart: (d) => _onVerticalDragStart(d, natural),
            onVerticalDragUpdate: (d) => _onVerticalDragUpdate(d, natural),
            onVerticalDragEnd: (d) => _onVerticalDragEnd(d, natural),
            child: AnimatedContainer(
              duration: _collapsing ? Duration.zero : const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              height: _playerHeight,
              width: double.infinity,
              color: Colors.black,
              child: (_controller?.value.isPlaying ?? false) || !mini
                  ? _buildPlayerSurface(c, ratio, mini: mini)
                  : _buildMiniBar(),
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  /// 收缩成小窗时，播放器只保留一条细栏
  Widget _buildMiniBar() {
    final c = _controller;
    final title = _detail?.title ?? widget.title;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _animateTo(
        _naturalHeight(
          c != null && c.value.isInitialized ? c.value.aspectRatio : 16 / 9,
          MediaQuery.sizeOf(context).width,
        ),
        _naturalHeight(
          c != null && c.value.isInitialized ? c.value.aspectRatio : 16 / 9,
          MediaQuery.sizeOf(context).width,
        ),
      ),
      onVerticalDragStart: (d) {
        final natural = _naturalHeight(
          c != null && c.value.isInitialized ? c.value.aspectRatio : 16 / 9,
          MediaQuery.sizeOf(context).width,
        );
        _onVerticalDragStart(d, natural);
      },
      onVerticalDragUpdate: (d) {
        final natural = _naturalHeight(
          c != null && c.value.isInitialized ? c.value.aspectRatio : 16 / 9,
          MediaQuery.sizeOf(context).width,
        );
        _onVerticalDragUpdate(d, natural);
      },
      onVerticalDragEnd: (d) {
        final natural = _naturalHeight(
          c != null && c.value.isInitialized ? c.value.aspectRatio : 16 / 9,
          MediaQuery.sizeOf(context).width,
        );
        _onVerticalDragEnd(d, natural);
      },
      child: Container(
        color: Colors.black,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              icon: Icon(
                c?.value.isPlaying == true
                    ? Icons.pause_circle_filled
                    : Icons.play_circle_fill,
                color: Colors.white,
                size: 24,
              ),
              onPressed: _togglePlay,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 12.5),
              ),
            ),
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              icon: Icon(
                _danmakuOn ? Icons.subtitles : Icons.subtitles_off,
                color: Colors.white70,
                size: 18,
              ),
              onPressed: () => setState(() => _danmakuOn = !_danmakuOn),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayerSurface(VideoPlayerController? c, double ratio, {bool mini = false}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (_) => _onTapUp(),
      onLongPressStart: (_) => _onLongPressStart(),
      onLongPressEnd: (_) => _onLongPressEnd(),
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: c != null && c.value.isInitialized
                  ? AspectRatio(aspectRatio: ratio, child: VideoPlayer(c))
                  : const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
            ),
            if (c != null && c.value.isInitialized)
              DanmakuOverlay(
                controller: c,
                danmakus: _danmakus,
                enabled: _danmakuOn,
              ),
            if (_showControls && c != null && c.value.isInitialized)
              _buildControls(c, fullscreen: false),
            if (_error != null && c == null)
              Container(
                color: Colors.black54,
                child: ErrorView(message: _error!, onRetry: _load),
              ),
            if (c != null && c.value.isInitialized && !c.value.isPlaying)
              Center(
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white70,
                      size: 40,
                    ),
                  ),
                ),
              ),
            // 收缩提示：暂停时右下角显示一个上拉小图标
            if (c != null && c.value.isInitialized && !c.value.isPlaying && !mini)
              const Positioned(
                right: 8,
                bottom: 34,
                child: IgnorePointer(
                  child: Icon(
                    Icons.keyboard_arrow_up_rounded,
                    color: Colors.white38,
                    size: 18,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildControls(VideoPlayerController c, {required bool fullscreen}) {
    final v = c.value;
    return Stack(
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.62),
                  Colors.transparent,
                ],
              ),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(
                    fullscreen ? Icons.fullscreen_exit : Icons.arrow_back_ios_new,
                    color: Colors.white,
                    size: 20,
                  ),
                  onPressed: () {
                    if (fullscreen) {
                      _toggleFullscreen();
                    } else {
                      Navigator.of(context).maybePop();
                    }
                  },
                ),
                Expanded(
                  child: Text(
                    _detail?.title ?? widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
                IconButton(
                  icon: Icon(
                    _danmakuOn ? Icons.subtitles : Icons.subtitles_off,
                    color: Colors.white,
                    size: 20,
                  ),
                  onPressed: () => setState(() => _danmakuOn = !_danmakuOn),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(4, 14, 4, 2),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.72),
                  Colors.transparent,
                ],
              ),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(
                    v.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 26,
                  ),
                  onPressed: _togglePlay,
                ),
                Text(
                  formatPlayerTime(v.position),
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2.5,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                      activeTrackColor: const Color(0xFFFB7299),
                      inactiveTrackColor: Colors.white24,
                      thumbColor: Colors.white,
                    ),
                    child: Slider(
                      value: v.duration.inMilliseconds == 0
                          ? 0
                          : (v.position.inMilliseconds / v.duration.inMilliseconds)
                              .clamp(0.0, 1.0),
                      onChanged: (x) => c.seekTo(v.duration * x),
                      onChangeStart: (_) => _hideTimer?.cancel(),
                      onChangeEnd: (_) => _scheduleHide(),
                    ),
                  ),
                ),
                Text(
                  formatPlayerTime(v.duration),
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
                PopupMenuButton<int>(
                  tooltip: '清晰度',
                  color: Colors.black87,
                  icon: const Icon(Icons.hd_outlined, color: Colors.white, size: 20),
                  onSelected: _switchQuality,
                  itemBuilder: (context) {
                    final accepts = _playInfo?.acceptQuality ?? const <int>[];
                    final qs = accepts.isEmpty ? const [64] : accepts;
                    return [
                      for (final q in qs)
                        PopupMenuItem<int>(
                          value: q,
                          child: Text(
                            PlayInfo.nameOf(q),
                            style: TextStyle(
                              color: q == _selectedQuality
                                  ? const Color(0xFFFB7299)
                                  : Colors.white,
                              fontSize: 13,
                            ),
                          ),
                        ),
                    ];
                  },
                ),
                IconButton(
                  icon: Icon(
                    fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                    color: Colors.white,
                    size: 20,
                  ),
                  onPressed: _toggleFullscreen,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBody() {
    final detail = _detail;
    if (_loading && detail == null) {
      return const ColoredBox(
        color: Colors.white,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null && detail == null) {
      return ColoredBox(
        color: Colors.white,
        child: ErrorView(message: _error!, onRetry: _load),
      );
    }
    if (detail == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Container(
      color: theme.scaffoldBackgroundColor,
      child: Column(
        children: [
          _buildInfoCard(detail),
          _buildActionBar(detail),
          TabBar(
            controller: _tabController,
            labelColor: theme.colorScheme.onSurface,
            unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
            indicatorColor: const Color(0xFFFB7299),
            indicatorSize: TabBarIndicatorSize.label,
            labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            unselectedLabelStyle: const TextStyle(fontSize: 13),
            tabs: [
              const Tab(text: '简介'),
              Tab(text: '评论 ${_commentTotal > 0 ? formatCount(_commentTotal) : ''}'.trim()),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildIntroTab(detail),
                _buildCommentTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCard(VideoDetail detail) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            detail.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                '${formatCount(detail.view)} 播放 · ${formatCount(detail.danmakuCount)} 弹幕',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                formatRelativeTime(detail.pubdate),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 操作栏：UP 主 + 点赞/投币/收藏/分享
  Widget _buildActionBar(VideoDetail detail) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: _openSpace,
              borderRadius: BorderRadius.circular(20),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 15,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    backgroundImage:
                        detail.ownerFace.isEmpty ? null : NetworkImage(detail.ownerFace),
                    child: detail.ownerFace.isEmpty
                        ? const Icon(Icons.person, size: 15)
                        : null,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      detail.ownerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 14),
                ],
              ),
            ),
          ),
          _actionButton(
            icon: _liked ? Icons.thumb_up_alt : Icons.thumb_up_alt_outlined,
            label: formatCount(_likedCount),
            active: _liked,
            onTap: _toggleLike,
          ),
          _actionButton(
            icon: _coinCount > 0
                ? Icons.monetization_on
                : Icons.monetization_on_outlined,
            label: _coinCount > 0 ? '$_coinCount/2' : '投币',
            active: _coinCount > 0,
            onTap: _addCoin,
          ),
          _actionButton(
            icon: _faved ? Icons.star : Icons.star_border,
            label: formatCount(_favCount),
            active: _faved,
            onTap: _toggleFav,
          ),
          _actionButton(
            icon: Icons.ios_share,
            label: '分享',
            active: false,
            onTap: () {
              Clipboard.setData(
                ClipboardData(
                  text: 'https://www.bilibili.com/video/${widget.bvid}',
                ),
              );
              _toast('链接已复制');
            },
          ),
        ],
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    final color = active
        ? const Color(0xFFFB7299)
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 19, color: color),
            const SizedBox(height: 1),
            Text(label, style: TextStyle(fontSize: 9.5, color: color)),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------- 简介 Tab

  Widget _buildIntroTab(VideoDetail detail) {
    final theme = Theme.of(context);
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        if (detail.pages.length > 1) _buildPageSelector(detail),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (detail.desc.trim().isNotEmpty)
                Text(
                  detail.desc.trim(),
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
                )
              else
                Text(
                  '该视频没有简介',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              if (_tags.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tag in _tags)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          tag,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const Divider(height: 14, thickness: 0.5),
        if (_related.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
            child: Text(
              '相关推荐',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Column(
              children: [
                for (final item in _related.take(20))
                  VideoTile(item: item, onTap: () => _openVideo(item)),
              ],
            ),
          ),
        ],
        SizedBox(height: 20 + MediaQuery.viewPaddingOf(context).bottom),
      ],
    );
  }

  Widget _buildPageSelector(VideoDetail detail) {
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        itemCount: detail.pages.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final selected = i == _currentPageIndex;
          return ChoiceChip(
            label: Text(
              detail.pages[i].label,
              style: TextStyle(
                fontSize: 11,
                color: selected ? Colors.white : null,
              ),
            ),
            selected: selected,
            showCheckmark: false,
            selectedColor: const Color(0xFFFB7299),
            visualDensity: VisualDensity.compact,
            onSelected: (_) => _switchPage(i),
          );
        },
      ),
    );
  }

  // --------------------------------------------------------- 评论 Tab

  Widget _buildCommentTab() {
    final theme = Theme.of(context);
    if (_comments.isEmpty && _commentLoading) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_comments.isEmpty) {
      return Center(
        child: Text(
          _commentsLoaded ? '还没有评论' : '加载中…',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _loadComments(reset: true),
      child: ListView.builder(
        padding: EdgeInsets.zero,
        itemCount: _comments.length + 1,
        itemBuilder: (context, i) {
          if (i == _comments.length) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Center(
                child: _commentHasMore
                    ? TextButton(
                        onPressed: _commentLoading
                            ? null
                            : () => _loadComments(reset: false),
                        child: Text(
                          _commentLoading ? '加载中…' : '查看更多评论',
                          style: const TextStyle(fontSize: 12),
                        ),
                      )
                    : Text(
                        '没有更多了',
                        style: theme.textTheme.labelSmall,
                      ),
              ),
            );
          }
          return _commentTile(_comments[i]);
        },
      ),
    );
  }

  Widget _commentTile(Comment c) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 9, 16, 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 15,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            backgroundImage: c.avatar.isEmpty ? null : NetworkImage(c.avatar),
            child: c.avatar.isEmpty ? const Icon(Icons.person, size: 14) : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        c.author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (c.level > 0) ...[
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 3,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFB7299).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          'Lv${c.level}',
                          style: const TextStyle(
                            fontSize: 9,
                            color: Color(0xFFFB7299),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  c.content,
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      formatRelativeTime(c.ctime),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 10,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Icon(
                      Icons.thumb_up_outlined,
                      size: 11,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 2),
                    Text(
                      formatCount(c.like),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 10,
                      ),
                    ),
                    if (c.replyCount > 0) ...[
                      const SizedBox(width: 12),
                      Text(
                        '${c.replyCount} 回复',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
