import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../api/bili_api.dart';
import '../../core/format.dart';
import '../../models/space.dart';
import '../../widgets/error_view.dart';
import '../../widgets/video_card.dart';
import '../video/video_page.dart';

/// UP 主个人空间
class SpacePage extends StatefulWidget {
  const SpacePage({
    super.key,
    required this.mid,
    this.name = '',
    this.face = '',
  });

  final int mid;
  final String name;
  final String face;

  @override
  State<SpacePage> createState() => _SpacePageState();
}

class _SpacePageState extends State<SpacePage> {
  UpProfile? _profile;
  final List<SpaceVideo> _videos = [];

  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  int _page = 1;

  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 500) _loadVideos();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _hasMore = true;
      _page = 1;
    });
    try {
      final profile = await BiliApi.instance.upProfile(widget.mid);
      final videos = await BiliApi.instance.upVideos(widget.mid, page: 1);
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _videos
          ..clear()
          ..addAll(videos);
        _loading = false;
        _hasMore = videos.isNotEmpty;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _loadVideos() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final next = _page + 1;
      final list = await BiliApi.instance.upVideos(widget.mid, page: next);
      if (!mounted) return;
      setState(() {
        if (list.isEmpty) {
          _hasMore = false;
        } else {
          _videos.addAll(list);
          _page = next;
        }
      });
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _open(SpaceVideo v) {
    final p = _profile;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VideoPage(
          bvid: v.bvid,
          title: v.title,
          cover: v.cover,
        ),
      ),
    );
    // 避免未使用变量告警
    p?.name;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(),
        body: ErrorView(message: _error!, onRetry: _load),
      );
    }
    final p = _profile;
    return Scaffold(
      appBar: AppBar(
        title: Text(p?.name ?? widget.name),
        centerTitle: false,
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (p != null)
              SliverToBoxAdapter(
                child: Column(
                  children: [
                    // 头图
                    SizedBox(
                      height: 110,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (p.banner.isNotEmpty)
                            CachedNetworkImage(
                              imageUrl: p.banner,
                              fit: BoxFit.cover,
                              errorWidget: (_, _, _) => Container(
                                color: theme.colorScheme.surfaceContainerHighest,
                              ),
                            )
                          else
                            Container(
                              color: theme.colorScheme.surfaceContainerHighest,
                            ),
                          Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.transparent,
                                  theme.scaffoldBackgroundColor,
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Transform.translate(
                      offset: const Offset(0, -30),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            CircleAvatar(
                              radius: 32,
                              backgroundColor: Colors.white,
                              backgroundImage: p.face.isEmpty
                                  ? null
                                  : NetworkImage(p.face),
                              child: p.face.isEmpty
                                  ? const Icon(Icons.person, size: 30)
                                  : null,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          p.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.titleMedium
                                              ?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      if (p.level > 0) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 4,
                                            vertical: 1,
                                          ),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFFB7299)
                                                .withValues(alpha: 0.15),
                                            borderRadius:
                                                BorderRadius.circular(3),
                                          ),
                                          child: Text(
                                            'Lv${p.level}',
                                            style: const TextStyle(
                                              fontSize: 9,
                                              color: Color(0xFFFB7299),
                                            ),
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
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (p.sign.isNotEmpty)
                            Text(
                              p.sign,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              _stat(formatCount(p.fans), '粉丝'),
                              const SizedBox(width: 24),
                              _stat(formatCount(p.archives), '投稿'),
                              const SizedBox(width: 24),
                              _stat(formatCount(p.likes), '获赞'),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1, thickness: 0.5),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Row(
                        children: [
                          Text(
                            '投稿',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              sliver: SliverList.builder(
                itemCount: _videos.length,
                itemBuilder: (context, i) {
                  final v = _videos[i];
                  final item = v.toFeedItem(
                    ownerName: p?.name ?? widget.name,
                    ownerFace: p?.face ?? widget.face,
                    ownerMid: p!.mid,
                  );
                  return VideoTile(item: item, onTap: () => _open(v));
                },
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  0,
                  14,
                  0,
                  20 + MediaQuery.viewPaddingOf(context).bottom,
                ),
                child: Center(
                  child: _loadingMore
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          _videos.isEmpty
                              ? '还没有投稿'
                              : (_hasMore ? '上拉加载更多' : '没有更多了'),
                          style: theme.textTheme.labelSmall,
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(String value, String label) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 3),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
