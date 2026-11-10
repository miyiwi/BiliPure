import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/http.dart';
import '../models/danmaku.dart';

/// 弹幕服务
///
/// bilibili 的 /{cid}.xml 返回的是 **raw deflate** 压缩数据（注意：不是 zlib 头，
/// 也不是 gzip），所以必须用 ZLibDecoder(raw: true)。
class DanmakuService {
  DanmakuService._();
  static final DanmakuService instance = DanmakuService._();

  final BiliClient _client = BiliClient();

  final Map<int, List<Danmaku>> _cache = {};
  final Set<int> _loading = {};

  List<Danmaku>? cached(int cid) => _cache[cid];

  /// 拉取某个分 P 的全部弹幕
  Future<List<Danmaku>> fetch(int cid, {bool force = false}) async {
    if (!force) {
      final hit = _cache[cid];
      if (hit != null) return hit;
    }
    if (_loading.contains(cid)) {
      // 已有请求在飞：等它完成
      while (_loading.contains(cid)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      return _cache[cid] ?? const [];
    }

    _loading.add(cid);
    try {
      final bytes = await _client.getBytes(
        'https://comment.bilibili.com/$cid.xml',
        headers: {'Referer': 'https://www.bilibili.com/'},
      );
      final xml = _decode(bytes);
      final list = parseXml(xml);
      list.sort((a, b) => a.time.compareTo(b.time));
      _cache[cid] = list;
      return list;
    } catch (_) {
      _cache[cid] = const [];
      return const [];
    } finally {
      _loading.remove(cid);
    }
  }

  /// bilibili 弹幕 XML 是 raw deflate；但也兼容未压缩 / gzip 的情况
  String _decode(List<int> bytes) {
    if (bytes.isEmpty) return '';
    final u8 = Uint8List.fromList(bytes);
    // 已经是 XML 明文
    if (u8.length > 5 && u8[0] == 0x3C && u8[1] == 0x3F) {
      return utf8.decode(u8, allowMalformed: true);
    }
    // gzip 魔数
    if (u8.length > 2 && u8[0] == 0x1f && u8[1] == 0x8b) {
      try {
        return utf8.decode(gzip.decode(u8), allowMalformed: true);
      } catch (_) {}
    }
    // raw deflate
    try {
      return utf8.decode(ZLibDecoder(raw: true).convert(u8), allowMalformed: true);
    } catch (_) {}
    // 带 zlib 头
    try {
      return utf8.decode(ZLibDecoder().convert(u8), allowMalformed: true);
    } catch (_) {}
    return utf8.decode(u8, allowMalformed: true);
  }

  /// 解析弹幕 XML 中的 `<d p="...">text</d>` 节点
  static List<Danmaku> parseXml(String xml) {
    final out = <Danmaku>[];
    if (xml.isEmpty) return out;
    final re = RegExp(r'<d\s+p="([^"]*)"[^>]*>([\s\S]*?)</d>');
    for (final m in re.allMatches(xml)) {
      final p = m.group(1) ?? '';
      final raw = m.group(2) ?? '';
      final text = _unescape(raw).trim();
      if (text.isEmpty) continue;
      final dm = Danmaku.tryParse(p, text);
      if (dm != null) out.add(dm);
    }
    return out;
  }

  static String _unescape(String s) {
    if (!s.contains('&')) return s;
    return s
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&amp;', '&');
  }
}
