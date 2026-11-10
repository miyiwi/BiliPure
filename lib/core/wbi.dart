import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// WBI 签名（bilibili web 接口防爬参数）
///
/// 算法来源：https://github.com/SocialSisterYi/bilibili-API-collect
/// 步骤：
///   1. 取 nav 接口返回的 wbi_img.img_url / sub_url 文件名（去掉扩展名）作为 imgKey / subKey
///   2. 用固定的混排表把 imgKey + subKey 重排，截取前 32 位得到 mixinKey
///   3. 参数加 wts 后按 key 升序排列，过滤 value 中的 !'()* 字符
///   4. w_rid = md5(query + mixinKey)
class WbiSigner {
  WbiSigner({required this.imgKey, required this.subKey});

  final String imgKey;
  final String subKey;

  static const List<int> _mixinKeyEncTab = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, //
    33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61,
    26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36,
    20, 34, 44, 52,
  ];

  /// 从完整 URL 中提取 key，例如
  /// https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png -> 7cd0849...
  static String keyFromUrl(String url) {
    final name = url.split('/').last;
    final dot = name.indexOf('.');
    return dot == -1 ? name : name.substring(0, dot);
  }

  static String mixinKeyOf(String imgKey, String subKey) {
    final raw = imgKey + subKey;
    final buf = StringBuffer();
    for (final i in _mixinKeyEncTab) {
      if (i < raw.length) buf.write(raw[i]);
    }
    final s = buf.toString();
    return s.length > 32 ? s.substring(0, 32) : s;
  }

  /// 返回已签名的 query string（含 wts / w_rid）
  String signQuery(Map<String, dynamic> params) {
    final wts = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    final all = <String, String>{
      for (final e in params.entries)
        if (e.value != null) e.key: e.value.toString(),
      'wts': wts,
    };
    final keys = all.keys.toList()..sort();
    final query = keys
        .map((k) => '${Uri.encodeComponent(k)}=${Uri.encodeComponent(_clean(all[k]!))}')
        .join('&');
    final wRid = md5.convert(utf8.encode(query + mixinKeyOf(imgKey, subKey))).toString();
    return '$query&w_rid=$wRid';
  }

  String _clean(String v) => v.replaceAll(RegExp(r"[!'()*]"), '');

  /// 生成一个稳定的随机 buvid（无登录态时用来避免被风控）
  static String randomBuvid3() {
    const hex = '0123456789ABCDEF';
    final rnd = Random();
    final buf = StringBuffer();
    for (var i = 0; i < 32; i++) {
      buf.write(hex[rnd.nextInt(16)]);
    }
    buf.write('infoc');
    return buf.toString();
  }
}
