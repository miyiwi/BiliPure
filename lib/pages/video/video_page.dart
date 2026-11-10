import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../api/bili_api.dart';
import '../../core/format.dart';
import '../../models/danmaku.dart';
import '../../models/feed_item.dart';
import '../../models/play_info.dart';
import '../../models/video_detail.dart';
import '../../services/danmaku_service.dart';
import '../../widgets/danmaku_overlay.dart';
import '../../widgets/error_view.dart';
import '../../widgets/video_card.dart';

/// 视频播放页：播放器 + 弹幕 + 简介 + 相关推荐
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

class _VideoPageState extends State<VideoPage> {
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

  @override
  void initState() {
    super.initState();
    _currentCid = widget.cid ?? 0;
    _load();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await BiliApi.instance.videoDetail(widget.bvid);
      if (!mounted) return;
      _detail = detail;
      if (_currentCid == 0) {
        _currentCid = detail.firstPage.cid;
        _currentPageIndex = 0;
      } else {
        final idx = detail.pages.indexWhere((p) => p.cid == _currentCid);
        if (idx >= 0) _currentPageIndex = idx;
      }
      await _loadPlay(_currentCid);
      if (!mounted) return;
      // 相关推荐不阻塞播放
      unawaited(_loadRelated());
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
      // 只拿到 DASH 分离流（音视频分开）时，单实例播放器无法播放
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
    controller.addListener(_onPlayerTick);
    await controller.play();
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() => _controller = controller);
  }

  void _onPlayerTick() {
    final c = _controller;
    if (c == null || !mounted) return;
    final v = c.value;
    if (v.hasError) return;
    if (v.isCompleted && _showControls) {
      _scheduleHide();
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

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHide();
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
      // 切清晰度后恢复播放进度
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildPlayerArea(),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayerArea() {
    final c = _controller;
    final ratio = c != null && c.value.isInitialized
        ? c.value.aspectRatio
        : (16 / 9);
    return Container(
      color: Colors.black,
      width: double.infinity,
      child: AspectRatio(
        aspectRatio: ratio <= 0 ? 16 / 9 : ratio,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (c != null && c.value.isInitialized)
              Center(
                child: AspectRatio(
                  aspectRatio: c.value.aspectRatio,
                  child: VideoPlayer(c),
                ),
              )
            else
              const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            if (c != null && c.value.isInitialized)
              DanmakuOverlay(
                controller: c,
                danmakus: _danmakus,
                enabled: _danmakuOn,
              ),
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
              ),
            ),
            if (_showControls && c != null && c.value.isInitialized)
              _buildControls(c),
            if (_error != null && c == null)
              Container(
                color: Colors.black54,
                child: ErrorView(message: _error!, onRetry: _load),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildControls(VideoPlayerController c) {
    final v = c.value;
    return Stack(
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
                  icon: const Icon(
                    Icons.arrow_back_ios_new,
                    color: Colors.white,
                    size: 20,
                  ),
                  onPressed: () => Navigator.of(context).maybePop(),
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
            padding: const EdgeInsets.fromLTRB(6, 16, 6, 4),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.7),
                  Colors.transparent,
                ],
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        v.isPlaying ? Icons.pause : Icons.play_arrow,
                        color: Colors.white,
                      ),
                      onPressed: () {
                        if (v.isPlaying) {
                          c.pause();
                        } else {
                          c.play();
                        }
                        _scheduleHide();
                      },
                    ),
                    Text(
                      formatPlayerTime(v.position),
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 2.5,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 12,
                          ),
                          activeTrackColor: const Color(0xFFFB7299),
                          inactiveTrackColor: Colors.white24,
                          thumbColor: Colors.white,
                        ),
                        child: Slider(
                          value: v.duration.inMilliseconds == 0
                              ? 0
                              : (v.position.inMilliseconds /
                                        v.duration.inMilliseconds)
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
                      icon: const Icon(
                        Icons.hd_outlined,
                        color: Colors.white,
                        size: 20,
                      ),
                      onSelected: _switchQuality,
                      itemBuilder: (context) {
                        final accepts =
                            _playInfo?.acceptQuality ?? const <int>[];
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
                  ],
                ),
                if (v.isBuffering)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 2),
                    child: Text(
                      '缓冲中…',
                      style: TextStyle(color: Colors.white54, fontSize: 10),
                    ),
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
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          if (detail != null) _buildInfoCard(detail),
          if (detail != null && detail.pages.length > 1)
            _buildPageSelector(detail),
          if (_related.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 20, 16, 4),
              child: Text('相关推荐', style: TextStyle(fontWeight: FontWeight.w600)),
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
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _buildInfoCard(VideoDetail detail) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
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
          const SizedBox(height: 8),
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
          const SizedBox(height: 12),
          Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundImage: detail.ownerFace.isEmpty
                    ? null
                    : NetworkImage(detail.ownerFace),
                child: detail.ownerFace.isEmpty
                    ? const Icon(Icons.person, size: 16)
                    : null,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  detail.ownerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              _statChip(Icons.thumb_up_alt_outlined, detail.like),
              const SizedBox(width: 12),
              _statChip(Icons.star_border, detail.favorite),
            ],
          ),
          if (detail.desc.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
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

  Widget _statChip(IconData icon, int value) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 3),
        Text(
          formatCount(value),
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildPageSelector(VideoDetail detail) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
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
}
