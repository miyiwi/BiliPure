import 'package:flutter/material.dart';

import '../../api/bili_api.dart';
import '../../models/feed_item.dart';
import '../../widgets/error_view.dart';
import '../../widgets/video_card.dart';
import '../video/video_page.dart';

/// 热门页：单列大卡片
class PopularPage extends StatefulWidget {
  const PopularPage({super.key});

  @override
  State<PopularPage> createState() => _PopularPageState();
}

class _PopularPageState extends State<PopularPage>
    with AutomaticKeepAliveClientMixin {
  final _scrollController = ScrollController();
  final List<FeedItem> _items = [];
  final Set<String> _seen = {};

  bool _loading = false;
  bool _initialLoading = true;
  bool _hasMore = true;
  String? _error;
  int _page = 0;

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
    if (pos.pixels >= pos.maxScrollExtent - 600) _loadMore();
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _hasMore = true;
    });
    try {
      final list = await BiliApi.instance.popular(page: 1);
      if (!mounted) return;
      setState(() {
        _items.clear();
        _seen.clear();
        for (final it in list) {
          if (_seen.add(it.bvid)) _items.add(it);
        }
        _page = 1;
        _initialLoading = false;
        _error = _items.isEmpty ? '暂时没有热门内容' : null;
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
      final next = _page + 1;
      final list = await BiliApi.instance.popular(page: next);
      if (!mounted) return;
      if (list.isEmpty) {
        setState(() => _hasMore = false);
        return;
      }
      setState(() {
        _page = next;
        for (final it in list) {
          if (_seen.add(it.bvid)) _items.add(it);
        }
      });
    } catch (_) {
      // 静默失败，用户可以再滑一次
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _open(FeedItem item) {
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
      child: ListView.separated(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
        itemCount: _items.length + 1,
        separatorBuilder: (_, _) => const Divider(height: 12, thickness: 0.5),
        itemBuilder: (context, i) {
          if (i == _items.length) {
            return Padding(
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
            );
          }
          return VideoTile(item: _items[i], onTap: () => _open(_items[i]));
        },
      ),
    );
  }
}
