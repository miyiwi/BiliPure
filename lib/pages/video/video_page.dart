import 'dart:async';

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
/// 布局参考 bilibili 原版：
/// - 停止播放时播放器区域可以上下拖动收缩（竖屏视频不再霸占大半屏）
/// - 双击暂停/继续，长按三连
/// - 全屏播放
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

  bool _loading = true;
  String? _error;
  int _currentCid = 0;
  int _currentPageIndex = 0;
  int _selectedQuality = 64;

  bool _danmakuOn = true;
  bool _showControls = true;
  Timer? _hideTimer;

  /// 播放器区域高度（可上下拖动收缩）
  double _playerHeight = 0;
  double _maxPlayerHeight = 0;
  final double _minPlayerHeight = 120;

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

  // 全屏
  bool _fullscreen = false;

  // 长按三连
  Timer? _longPressTimer;
  bool _longPressFired = false;

  /// 双击检测
  DateTime _lastTap = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _currentCid = widget.cid ?? 0;
    _load();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _longPressTimer?.cancel();
    // 退出时恢复竖屏
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    _controller?.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- 数据加载

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
      unawaited(_loadInteractionState());
      unawaited(_loadComments(reset: true));
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

  Future<void> _loadInteractionState() async {
    final api = BiliApi.instance;
    final liked = await api.hasLike(widget.bvid);
    final coins = await api.coinCount(widget.bvid);
    final aid = _detail?.aid ?? 0;
    final faved = aid > 0 ? await api.hasFav(aid) : false;
    if (!mounted) return;
    setState(() {
      _liked = liked;
      if (liked) _likedCount = _detail?.like ?? _likedCount;
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
    // 关键：监听器必须触发 setState，否则暂停后按钮图标不会更新，
    // 这也是「播放暂停键有问题」的直接原因。
    controller.addListener(_onPlayerTick);
    await controller.play();
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() {
      _controller = controller;
      _playerHeight = 0; // 重新按视频比例算
    });
    _scheduleHide();
  }

  void _onPlayerTick() {
    if (!mounted) return;
    final c = _controller;
    if (c == null) return;
    final v = c.value;
    // 播放/暂停状态变化需要重绘控制栏
    setState(() {});
    if (v.isCompleted) {
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

  // ------------------------------------------------------------- 交互

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

  /// 单击：显示/隐藏控制栏 + 延迟判定双击
  void _onTapUp() {
    if (_longPressFired) {
      _longPressFired = false;
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastTap) < const Duration(milliseconds: 260)) {
      // 双击：暂停/继续
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
      // 长按结束后重置标记，让下一次单击正常工作
      Future<void>.delayed(const Duration(milliseconds: 60), () {
        _longPressFired = false;
      });
    }
  }

  /// 长按三连：点赞 + 投币 + 收藏
  Future<void> _tripleAction() async {
    if (_interacting) return;
    _interacting = true;
    try {
      final api = BiliApi.instance;
      final results = <String>[];

      final like = await api.like(widget.bvid, liked: true, aid: _detail?.aid ?? 0);
      if (like.ok) {
        setState(() {
          _liked = true;
          _likedCount += 1;
        });
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
    final api = BiliApi.instance;
    final r = await api.coin(widget.bvid, multiply: 1);
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
    final api = BiliApi.instance;
    if (_faved) {
      _toast('已收藏');
      return;
    }
    final r = await api.favorite(aid);
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
    final videoRatio = c != null && c.value.isInitialized && c.value.aspectRatio > 0
        ? c.value.aspectRatio
        : 16 / 9;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      // 播放页是黑底，状态栏图标必须是白色
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.black,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _fullscreen ? _buildFullscreen(c, videoRatio) : _buildNormal(c, videoRatio),
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
    // 计算播放器高度上下限
    final screenH = MediaQuery.sizeOf(context).height;
    final maxH = screenH * 0.62;
    // 按视频真实比例算高度，竖屏视频取较小值，避免霸屏
    final naturalH = MediaQuery.sizeOf(context).width / (ratio <= 0 ? 16 / 9 : ratio);
    _maxPlayerHeight = maxH;
    final natural = naturalH.clamp(120.0, maxH);
    if (_playerHeight <= 0) _playerHeight = natural;
    _playerHeight = _playerHeight.clamp(_minPlayerHeight, _maxPlayerHeight);

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          GestureDetector(
            onVerticalDragUpdate: (d) {
              setState(() {
                _playerHeight = (_playerHeight + d.delta.dy)
                    .clamp(_minPlayerHeight, _maxPlayerHeight);
              });
            },
            onVerticalDragEnd: (_) {},
            child: SizedBox(
              height: _playerHeight,
              width: double.infinity,
              child: _buildPlayerSurface(c, ratio),
            ),
          ),
          // 拖动把手，提示可以收缩
          GestureDetector(
            onVerticalDragUpdate: (d) {
              setState(() {
                _playerHeight = (_playerHeight - d.delta.dy)
                    .clamp(_minPlayerHeight, _maxPlayerHeight);
              });
            },
            onTap: () {
              // 点一下在「自然高度」和「最小高度」之间切换
              setState(() {
                _playerHeight = _playerHeight > _minPlayerHeight + 60
                    ? _minPlayerHeight
                    : natural.clamp(_minPlayerHeight, _maxPlayerHeight);
              });
            },
            child: Container(
              height: 16,
              color: Colors.black,
              alignment: Alignment.center,
              child: Container(
                width: 42,
                height: 3.5,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildPlayerSurface(VideoPlayerController? c, double ratio) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (_) => _onTapUp(),
      onLongPressStart: (_) => _onLongPressStart(),
      onLongPressEnd: (_) => _onLongPressEnd(),
      onDoubleTap: null, // 双击由 _onTapUp 里的时间窗判定，避免与单击冲突
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
            // 暂停时显示大播放按钮，提示可点击
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
                  // 用 v.isPlaying 实时状态，暂停后图标会立刻变成播放
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
    final theme = Theme.of(context);
    return Container(
      color: theme.scaffoldBackgroundColor,
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          if (detail != null) _buildInfoCard(detail),
          if (detail != null) _buildActionBar(detail),
          if (detail != null && detail.pages.length > 1) _buildPageSelector(detail),
          const Divider(height: 12, thickness: 0.5),
          _buildComments(),
          if (_related.isNotEmpty) ...[
            const Divider(height: 12, thickness: 0.5),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Text(
                '相关推荐',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  for (final item in _related.take(20))
                    VideoTile(item: item, onTap: () => _openVideo(item)),
                ],
              ),
            ),
          ],
          SizedBox(height: 24 + MediaQuery.viewPaddingOf(context).bottom),
        ],
      ),
    );
  }

  Widget _buildInfoCard(VideoDetail detail) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            detail.title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                '${formatCount(detail.view)} 播放',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${formatCount(detail.danmakuCount)} 弹幕',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                formatRelativeTime(detail.pubdate),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          if (detail.desc.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              detail.desc.trim(),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 点赞 / 投币 / 收藏 / UP 主
  Widget _buildActionBar(VideoDetail detail) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: _openSpace,
              borderRadius: BorderRadius.circular(20),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    backgroundImage:
                        detail.ownerFace.isEmpty ? null : NetworkImage(detail.ownerFace),
                    child: detail.ownerFace.isEmpty
                        ? const Icon(Icons.person, size: 16)
                        : null,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      detail.ownerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 16),
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
              Clipboard.setData(ClipboardData(
                text: 'https://www.bilibili.com/video/${widget.bvid}',
              ));
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
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 10, color: color)),
          ],
        ),
      ),
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

  Widget _buildComments() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Row(
            children: [
              Text(
                '评论',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                formatCount(_commentTotal),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        if (_comments.isEmpty && _commentLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (_comments.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Text(
              '还没有评论',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else ...[
          for (final c in _comments) _commentTile(c),
          if (_commentHasMore)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Center(
                child: TextButton(
                  onPressed: _commentLoading
                      ? null
                      : () => _loadComments(reset: false),
                  child: Text(
                    _commentLoading ? '加载中…' : '查看更多评论',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }

  Widget _commentTile(Comment c) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
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
                        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
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
