import 'package:flutter/material.dart';

import '../../api/bili_api.dart';
import '../../models/feed_item.dart';
import '../../widgets/video_card.dart';
import '../../widgets/error_view.dart';
import '../video/video_page.dart';

/// 首页：推荐流双列瀑布流，下拉刷新 + 上拉加载
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with AutomaticKeepAliveClientMixin {
  final _scrollController = ScrollController();
  final List<FeedItem> _items = [];
  final Set<String> _seen = {};

  bool _loading = false;
  bool _initialLoading = true;
  String? _error;
  int _freshIdx = 0;
  bool _hasMore = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _refresh();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 600) {
      _loadMore();
    }
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _hasMore = true;
    });
    try {
      await BiliApi.instance.bootstrap();
      _freshIdx += 1;
      final list = await BiliApi.instance.recommendFeed(freshIdx: _freshIdx);
      if (!mounted) return;
      setState(() {
        _items.clear();
        _seen.clear();
        for (final it in list) {
          if (_seen.add(it.bvid)) _items.add(it);
        }
        _initialLoading = false;
        _error = _items.isEmpty ? '没有拿到内容，试试下拉刷新' : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _initialLoading = false;
        _error = e.toString();
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    try {
      _freshIdx += 1;
      final list = await BiliApi.instance.recommendFeed(freshIdx: _freshIdx);
      if (!mounted) return;
      if (list.isEmpty) {
        setState(() => _hasMore = false);
        return;
      }
      var added = 0;
      setState(() {
        for (final it in list) {
          if (_seen.add(it.bvid)) {
            _items.add(it);
            added++;
          }
        }
      });
      if (added == 0) {
        // 连续重复内容，停止继续加载
        setState(() => _hasMore = false);
      }
    } catch (_) {
      // 加载更多失败时静默，用户可以再滑一次
    } finally {
      if (mounted) setState(() => _loading = false);
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
    super.build(context);
    if (_initialLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _items.isEmpty) {
      return ErrorView(message: _error!, onRetry: _refresh);
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: CustomScrollView(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            sliver: SliverMasonryGrid(
              items: _items,
              onTap: _openVideo,
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: _loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        _hasMore ? '上拉加载更多' : '没有更多了',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 简单的双列瀑布流：用两列 Column 交替分配，高度自适应且无需额外依赖。
class SliverMasonryGrid extends StatelessWidget {
  const SliverMasonryGrid({
    super.key,
    required this.items,
    required this.onTap,
  });

  final List<FeedItem> items;
  final void Function(FeedItem) onTap;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final left = <FeedItem>[];
    final right = <FeedItem>[];
    for (var i = 0; i < items.length; i++) {
      (i.isEven ? left : right).add(items[i]);
    }
    return SliverToBoxAdapter(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              children: [
                for (final it in left)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: VideoCard(item: it, onTap: () => onTap(it)),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              children: [
                for (final it in right)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: VideoCard(item: it, onTap: () => onTap(it)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
