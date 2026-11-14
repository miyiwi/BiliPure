import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../api/bili_api.dart';
import '../../core/format.dart';
import '../../models/comment.dart';
import '../../models/danmaku.dart';
import '../../models/feed_item.dart';
import '../../models/play_info.dart';
import '../../models/video_detail.dart';
import '../../services/bili_player.dart';
import '../../services/danmaku_service.dart';
import '../../widgets/danmaku_overlay_media_kit.dart';
import '../../widgets/error_view.dart';
import '../../widgets/video_card.dart';
import '../space/space_page.dart';

/// 视频播放页
///
/// 布局参照官方客户端截图：
/// - 播放器在上，控制栏在底部（播放/下一集/弹幕/输入框/倍速/清晰度）
/// - 右上有「关注/收藏/投币/点赞/分享/更多」入口
/// - 下方是「简介 / 评论」Tab
/// - 暂停时可上下滑动收缩为顶部小窗，展开不超过视频原始高度
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
  late final BiliPlayer _player;
  VideoDetail? _detail;
  PlayInfo? _playInfo;
  List<Danmaku> _danmakus = const [];
  List<FeedItem> _related = const [];
  List<String> _tags = const [];

  StreamSubscription<bool>? _playingSub;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<bool>? _bufferingSub;

  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _buffering = false;

  bool _loading = true;
  String? _error;
  int _currentCid = 0;
  int _currentPageIndex = 0;
  int _selectedQuality = 64;
  double _rate = 1.0;

  bool _danmakuOn = true;
  bool _showControls = true;
  Timer? _hideTimer;

  double _playerHeight = 0;
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

  bool _fullscreen = false;

  Timer? _longPressTimer;
  bool _longPressFired = false;
  DateTime _lastTap = DateTime.fromMillisecondsSinceEpoch(0);

  late TabController _tabController;

  static const double _miniHeight = 56;

  @override
  void initState() {
    super.initState();
    ensureMediaKitInitialized();
    _player = BiliPlayer();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (!mounted) return;
      setState(() {});
      if (_tabController.index == 1 && !_commentsLoaded) {
        _loadComments(reset: true);
      }
    });

    _playingSub = _player.playingStream.listen((v) {
      if (!mounted) return;
      setState(() => _playing = v);
    });
    _posSub = _player.positionStream.listen((p) {
      if (!mounted) return;
      setState(() => _position = p);
    });
    _durSub = _player.durationStream.listen((d) {
      if (!mounted) return;
      setState(() => _duration = d);
    });
    _bufferingSub = _player.bufferingStream.listen((b) {
      if (!mounted) return;
      setState(() => _buffering = b);
    });

    _currentCid = widget.cid ?? 0;
    _load();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _longPressTimer?.cancel();
    _playingSub?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _bufferingSub?.cancel();
    _tabController.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    _player.dispose();
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
    // 优先要 DASH：media_kit 能合并音视频轨，清晰度上限更高
    PlayInfo info;
    try {
      info = await BiliApi.instance.playUrl(
        bvid: widget.bvid,
        cid: cid,
        qn: _selectedQuality,
        preferDash: true,
      );
      if (!info.isPlayable) throw Exception('DASH 不可用');
    } catch (_) {
      // 退回整段 mp4
      info = await BiliApi.instance.playUrl(
        bvid: widget.bvid,
        cid: cid,
        qn: _selectedQuality,
      );
    }
    if (!mounted) return;
    setState(() {
      _playInfo = info;
      _selectedQuality = info.quality;
    });
    await _openMedia(info);
    if (!mounted) return;
    setState(() => _loading = false);
    unawaited(_loadDanmaku(cid));
  }

  Future<void> _openMedia(PlayInfo info) async {
    if (info.isDash && info.dashVideoUrl.isNotEmpty) {
      await _player.open(
        videoUrl: info.dashVideoUrl,
        audioUrl: info.dashAudioUrl.isEmpty ? null : info.dashAudioUrl,
      );
    } else if (info.urls.isNotEmpty) {
      await _player.open(videoUrl: info.urls.first);
    } else {
      throw Exception('播放地址为空');
    }
    await _player.setRate(_rate);
  }

  Future<void> _loadDanmaku(int cid) async {
    final list = await DanmakuService.instance.fetch(cid);
    if (!mounted) return;
    setState(() => _danmakus = list);
  }

  // ------------------------------------------------------------- 手势

  void _togglePlay() {
    _player.playOrPause();
    setState(() => _showControls = true);
    if (_playing) {
      _hideTimer?.cancel();
    } else {
      _scheduleHide();
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (!_playing) return;
      setState(() => _showControls = false);
    });
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
    Future<void>.delayed(const Duration(milliseconds: 60), () {
      _longPressFired = false;
    });
  }

  double _naturalHeight(double videoRatio, double width) {
    final safeRatio = videoRatio <= 0 ? 16 / 9 : videoRatio;
    return width / safeRatio;
  }

  void _onVerticalDragUpdate(DragUpdateDetails d, double natural) {
    if (_playing) return;
    if (_playerHeight <= 0) _playerHeight = natural;
    final upper = math.max(_miniHeight, natural).toDouble();
    setState(() {
      _playerHeight = (_playerHeight - d.delta.dy).clamp(_miniHeight, upper).toDouble();
    });
  }

  void _onVerticalDragEnd(DragEndDetails d, double natural) {
    if (_playing || _playerHeight <= 0) return;
    final v = d.primaryVelocity ?? 0;
    if (v < -300) {
      _animateTo(_miniHeight, natural);
    } else if (v > 300) {
      _animateTo(natural, natural);
    } else {
      final mid = (_miniHeight + natural) / 2;
      _animateTo(_playerHeight < mid ? _miniHeight : natural, natural);
    }
  }

  void _animateTo(double target, double natural) {
    final from = _playerHeight;
    final upper = math.max(_miniHeight, natural).toDouble();
    final to = target.clamp(_miniHeight, upper).toDouble();
    final start = DateTime.now();
    const dur = Duration(milliseconds: 180);
    setState(() => _collapsing = true);
    Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final t = DateTime.now().difference(start).inMilliseconds / dur.inMilliseconds;
      if (t >= 1) {
        timer.cancel();
        setState(() {
          _playerHeight = to;
          _collapsing = false;
        });
        return;
      }
      final e = 1 - math.pow(1 - t, 3);
      setState(() => _playerHeight = from + (to - from) * e);
    });
  }

  // ------------------------------------------------------------- 交互

  Future<void> _tripleAction() async {
    if (_interacting) return;
    _interacting = true;
    try {
      final api = BiliApi.instance;
      final done = <String>[];

      final like = await api.like(widget.bvid, liked: true, aid: _detail?.aid ?? 0);
      if (like.ok) {
        if (!_liked) setState(() => _likedCount += 1);
        setState(() => _liked = true);
        done.add('点赞');
      }
      if (_coinCount < 2) {
        final coin = await api.coin(widget.bvid, multiply: 1);
        if (coin.ok) {
          setState(() => _coinCount += 1);
          done.add('投币');
        }
      }
      if (!_faved && (_detail?.aid ?? 0) > 0) {
        final fav = await api.favorite(_detail!.aid);
        if (fav.ok) {
          setState(() {
            _faved = true;
            _favCount += 1;
          });
          done.add('收藏');
        }
      }
      if (!mounted) return;
      if (done.isEmpty) {
        final canWrite = await BiliApi.instance.canWrite();
        _toast(canWrite ? '操作未完成，请稍后重试' : '登录后即可一键三连');
      } else {
        _toast('已${done.join('、')}');
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
    final target = !_liked;
    final r = await BiliApi.instance.like(
      widget.bvid,
      liked: target,
      aid: _detail?.aid ?? 0,
    );
    if (!mounted) return;
    if (r.ok) {
      setState(() {
        _liked = target;
        _likedCount = (_likedCount + (target ? 1 : -1)).clamp(0, 1 << 30);
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
    final pos = _position;
    final wasPlaying = _playing;
    setState(() {
      _selectedQuality = qn;
      _loading = true;
    });
    try {
      final info = await BiliApi.instance.playUrl(
        bvid: widget.bvid,
        cid: _currentCid,
        qn: qn,
        preferDash: true,
      );
      if (!mounted) return;
      setState(() => _playInfo = info);
      await _openMedia(info);
      if (pos > Duration.zero) {
        await _player.seek(pos);
        if (wasPlaying) await _player.play();
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
      await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  void _showRateSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black87,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('倍速', style: TextStyle(color: Colors.white70)),
            ),
            for (final r in kPlaybackRates)
              ListTile(
                dense: true,
                title: Text(
                  rateLabel(r),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: r == _rate ? const Color(0xFFFB7299) : Colors.white,
                  ),
                ),
                onTap: () async {
                  await _player.setRate(r);
                  if (mounted) setState(() => _rate = r);
                  if (context.mounted) Navigator.pop(context);
                },
              ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------- 构建

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.black,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _fullscreen ? _buildFullscreen() : _buildNormal(),
      ),
    );
  }

  /// 视频宽高比
  ///
  /// media_kit 把宽高比放在 player.state.videoParams.aspect，
  /// 拿不到时按 16:9 兜底。
  double get _videoRatio {
    final a = _player.player.state.videoParams.aspect;
    if (a != null && a > 0) return a;
    return 16 / 9;
  }

  Widget _buildFullscreen() {
    return GestureDetector(
      onTapUp: (_) => _onTapUp(),
      onLongPressStart: (_) => _onLongPressStart(),
      onLongPressEnd: (_) => _onLongPressEnd(),
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(child: _buildVideo()),
            DanmakuOverlayMediaKit(
              player: _player,
              danmakus: _danmakus,
              enabled: _danmakuOn,
            ),
            if (_showControls) _buildControls(fullscreen: true),
          ],
        ),
      ),
    );
  }

  Widget _buildVideo() {
    return Video(
      controller: _player.controller,
      controls: NoVideoControls,
      fit: BoxFit.contain,
    );
  }

  Widget _buildNormal() {
    final width = MediaQuery.sizeOf(context).width;
    final natural = _naturalHeight(_videoRatio, width);
    if (_playerHeight <= 0) _playerHeight = natural;
    final upper = math.max(_miniHeight, natural).toDouble();
    _playerHeight = _playerHeight.clamp(_miniHeight, upper).toDouble();
    final mini = _playerHeight <= _miniHeight + 0.5;

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTapUp: (_) => _onTapUp(),
            onLongPressStart: (_) => _onLongPressStart(),
            onLongPressEnd: (_) => _onLongPressEnd(),
            onVerticalDragUpdate: (d) => _onVerticalDragUpdate(d, natural),
            onVerticalDragEnd: (d) => _onVerticalDragEnd(d, natural),
            child: AnimatedContainer(
              duration: _collapsing ? Duration.zero : const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              height: _playerHeight,
              width: double.infinity,
              color: Colors.black,
              child: (_playing || !mini) ? _buildPlayerSurface(mini: mini) : _buildMiniBar(),
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildMiniBar() {
    final title = _detail?.title ?? widget.title;
    final width = MediaQuery.sizeOf(context).width;
    final natural = _naturalHeight(_videoRatio, width);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _animateTo(natural, natural),
      onVerticalDragUpdate: (d) => _onVerticalDragUpdate(d, natural),
      onVerticalDragEnd: (d) => _onVerticalDragEnd(d, natural),
      child: Container(
        color: Colors.black,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              icon: Icon(
                _playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
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

  Widget _buildPlayerSurface({bool mini = false}) {
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(child: _buildVideo()),
          DanmakuOverlayMediaKit(
            player: _player,
            danmakus: _danmakus,
            enabled: _danmakuOn,
          ),
          if (_showControls) _buildControls(fullscreen: false),
          if (_error != null && _detail == null)
            Container(
              color: Colors.black54,
              child: ErrorView(message: _error!, onRetry: _load),
            ),
          if (!_playing && !mini)
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
    );
  }

  /// 控制栏：完全对照官方截图
  /// 顶栏：返回 / 标题 / 点赞 / 评论 / 收藏 / 投币 / 分享 / 更多
  /// 底栏：播放 / 下一集 / 弹幕开关 / 弹幕输入框 / 倍速 / 清晰度
  Widget _buildControls({required bool fullscreen}) {
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
                  Colors.black.withValues(alpha: 0.6),
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
                _topAction(
                  icon: _liked ? Icons.thumb_up_alt : Icons.thumb_up_alt_outlined,
                  label: formatCount(_likedCount),
                  onTap: _toggleLike,
                ),
                _topAction(
                  icon: Icons.chat_bubble_outline,
                  label: formatCount(_commentTotal),
                  onTap: () => _tabController.animateTo(1),
                ),
                _topAction(
                  icon: _faved ? Icons.star : Icons.star_border,
                  label: formatCount(_favCount),
                  onTap: _toggleFav,
                ),
                _topAction(
                  icon: _coinCount > 0
                      ? Icons.monetization_on
                      : Icons.monetization_on_outlined,
                  label: _coinCount > 0 ? '$_coinCount' : '',
                  onTap: _addCoin,
                ),
                _topAction(
                  icon: Icons.ios_share,
                  label: '',
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
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(6, 12, 6, 4),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.75),
                  Colors.transparent,
                ],
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 进度条
                Row(
                  children: [
                    Text(
                      formatPlayerTime(_position),
                      style: const TextStyle(color: Colors.white, fontSize: 10.5),
                    ),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 2,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                          activeTrackColor: Colors.white,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: Colors.white,
                        ),
                        child: Slider(
                          value: _duration.inMilliseconds == 0
                              ? 0
                              : (_position.inMilliseconds / _duration.inMilliseconds)
                                  .clamp(0.0, 1.0),
                          onChanged: (x) => _player.seek(_duration * x),
                          onChangeStart: (_) => _hideTimer?.cancel(),
                          onChangeEnd: (_) => _scheduleHide(),
                        ),
                      ),
                    ),
                    Text(
                      formatPlayerTime(_duration),
                      style: const TextStyle(color: Colors.white, fontSize: 10.5),
                    ),
                  ],
                ),
                // 底部功能条
                Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        _playing ? Icons.pause : Icons.play_arrow,
                        color: Colors.white,
                        size: 26,
                      ),
                      onPressed: _togglePlay,
                    ),
                    IconButton(
                      tooltip: '下一个分P',
                      icon: const Icon(Icons.skip_next, color: Colors.white, size: 22),
                      onPressed: () {
                        final pages = _detail?.pages ?? const [];
                        if (_currentPageIndex < pages.length - 1) {
                          _switchPage(_currentPageIndex + 1);
                        }
                      },
                    ),
                    IconButton(
                      tooltip: _danmakuOn ? '关闭弹幕' : '开启弹幕',
                      icon: Icon(
                        _danmakuOn ? Icons.subtitles : Icons.subtitles_off,
                        color: _danmakuOn ? Colors.white : Colors.white38,
                        size: 20,
                      ),
                      onPressed: () => setState(() => _danmakuOn = !_danmakuOn),
                    ),
                    const SizedBox(width: 4),
                    // 弹幕输入框（占位，点开提示）
                    Expanded(
                      child: GestureDetector(
                        onTap: () => _toast('发送弹幕功能开发中'),
                        child: Container(
                          height: 30,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(15),
                          ),
                          alignment: Alignment.centerLeft,
                          child: Text(
                            _danmakuOn ? '发个弹幕见证当下' : '弹幕功能关闭',
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 11.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    TextButton(
                      onPressed: _showRateSheet,
                      child: Text(
                        rateLabel(_rate),
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ),
                    PopupMenuButton<int>(
                      tooltip: '清晰度',
                      color: Colors.black87,
                      onSelected: _switchQuality,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          PlayInfo.nameOf(_selectedQuality),
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ),
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
              ],
            ),
          ),
        ),
        if (_buffering)
          const Center(
            child: SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(color: Colors.white70, strokeWidth: 2),
            ),
          ),
      ],
    );
  }

  Widget _topAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 18),
            if (label.isNotEmpty)
              Text(label, style: const TextStyle(color: Colors.white, fontSize: 8.5)),
          ],
        ),
      ),
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
          _buildOwnerRow(detail),
          _buildTitleRow(detail),
          _buildStatRow(detail),
          _buildActionRow(detail),
          TabBar(
            controller: _tabController,
            labelColor: const Color(0xFFFB7299),
            unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
            indicatorColor: const Color(0xFFFB7299),
            indicatorSize: TabBarIndicatorSize.label,
            labelStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
            unselectedLabelStyle: const TextStyle(fontSize: 13.5),
            tabs: const [Tab(text: '简介'), Tab(text: '评论')],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [_buildIntroTab(detail), _buildCommentTab()],
            ),
          ),
        ],
      ),
    );
  }

  /// UP 主行：头像 + 昵称 + 粉丝数 + 关注按钮（对照截图）
  Widget _buildOwnerRow(VideoDetail detail) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
      child: Row(
        children: [
          InkWell(
            onTap: _openSpace,
            child: Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  backgroundImage:
                      detail.ownerFace.isEmpty ? null : NetworkImage(detail.ownerFace),
                  child: detail.ownerFace.isEmpty
                      ? const Icon(Icons.person, size: 16)
                      : null,
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      detail.ownerName,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      '${formatCount(detail.view)} 播放',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Spacer(),
          // 关注按钮（粉色胶囊，对照截图）
          SizedBox(
            height: 30,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFB7299),
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
              ),
              onPressed: () => _toast('关注功能开发中'),
              child: const Text('+ 关注', style: TextStyle(fontSize: 12.5)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTitleRow(VideoDetail detail) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              detail.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
          ),
          const Icon(Icons.keyboard_arrow_down, size: 18),
        ],
      ),
    );
  }

  /// 播放量 / 弹幕 / 日期 / 正在看
  Widget _buildStatRow(VideoDetail detail) {
    final theme = Theme.of(context);
    final s = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontSize: 10.5,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      child: Row(
        children: [
          Icon(Icons.play_circle_outline, size: 12, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 3),
          Text(formatCount(detail.view), style: s),
          const SizedBox(width: 12),
          Icon(Icons.subtitles_outlined, size: 12, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 3),
          Text(formatCount(detail.danmakuCount), style: s),
          const SizedBox(width: 12),
          Text(_formatDate(detail.pubdate), style: s),
        ],
      ),
    );
  }

  String _formatDate(int unix) {
    if (unix <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(unix * 1000);
    return '${t.year}年${t.month}月${t.day}日';
  }

  /// 点赞 / 不喜欢 / 投币 / 收藏 / 分享（对照截图的圆形图标行）
  Widget _buildActionRow(VideoDetail detail) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _roundAction(
            icon: _liked ? Icons.thumb_up : Icons.thumb_up_outlined,
            label: formatCount(_likedCount),
            onTap: _toggleLike,
          ),
          _roundAction(
            icon: Icons.thumb_down_outlined,
            label: '不喜欢',
            onTap: () => _toast('感谢反馈'),
          ),
          _roundAction(
            icon: _coinCount > 0 ? Icons.monetization_on : Icons.monetization_on_outlined,
            label: _coinCount > 0 ? '$_coinCount/2' : formatCount(0),
            onTap: _addCoin,
          ),
          _roundAction(
            icon: _faved ? Icons.star : Icons.star_border,
            label: formatCount(_favCount),
            onTap: _toggleFav,
          ),
          _roundAction(
            icon: Icons.reply,
            label: formatCount(detail.share),
            onTap: () {
              Clipboard.setData(
                ClipboardData(text: 'https://www.bilibili.com/video/${widget.bvid}'),
              );
              _toast('链接已复制');
            },
          ),
        ],
      ),
    );
  }

  Widget _roundAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 24, color: theme.colorScheme.onSurface),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
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
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                detail.desc.trim().isEmpty ? '该视频没有简介' : detail.desc.trim(),
                style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
              ),
              if (_tags.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tag in _tags)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
            padding: const EdgeInsets.fromLTRB(14, 2, 14, 4),
            child: Text(
              '相关推荐',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
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
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
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
                        onPressed:
                            _commentLoading ? null : () => _loadComments(reset: false),
                        child: Text(
                          _commentLoading ? '加载中…' : '查看更多评论',
                          style: const TextStyle(fontSize: 12),
                        ),
                      )
                    : Text('没有更多了', style: theme.textTheme.labelSmall),
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
      padding: const EdgeInsets.fromLTRB(14, 9, 14, 9),
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
                          style: const TextStyle(fontSize: 9, color: Color(0xFFFB7299)),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(c.content, style: theme.textTheme.bodySmall?.copyWith(height: 1.45)),
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
