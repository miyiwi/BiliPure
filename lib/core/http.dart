import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'wbi.dart';

/// 全局 Cookie 罐：持久化到 SharedPreferences，模拟浏览器的登录态。
class CookieJar {
  CookieJar._();
  static final CookieJar instance = CookieJar._();

  static const _prefsKey = 'bilipure.cookies.v1';

  final Map<String, String> _cookies = {};
  bool _loaded = false;

  /// 允许外部直接设置（例如二维码登录成功后写入 SESSDATA）
  Map<String, String> get cookies => Map.unmodifiable(_cookies);

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        decoded.forEach((k, v) => _cookies[k] = v.toString());
      }
    } catch (_) {
      // 读取失败不阻塞启动
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(_cookies));
    } catch (_) {}
  }

  String? operator [](String key) => _cookies[key];

  bool get isLoggedIn => (_cookies['SESSDATA'] ?? '').isNotEmpty;

  String? get userId => _cookies['DedeUserID'];

  Future<void> setAll(Map<String, String> values) async {
    _cookies.addAll(values);
    await _persist();
  }

  Future<void> remove(String key) async {
    _cookies.remove(key);
    await _persist();
  }

  Future<void> clear() async {
    _cookies.clear();
    await _persist();
  }

  /// 从 Set-Cookie 响应头里吸收 cookie
  void absorb(List<String> setCookies) {
    var changed = false;
    for (final raw in setCookies) {
      final pair = raw.split(';').first;
      final idx = pair.indexOf('=');
      if (idx <= 0) continue;
      final name = pair.substring(0, idx).trim();
      final value = pair.substring(idx + 1).trim();
      if (name.isEmpty) continue;
      if (_cookies[name] != value) {
        _cookies[name] = value;
        changed = true;
      }
    }
    if (changed) unawaited(_persist());
  }

  String get headerValue => _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
}

/// bilibili API 客户端
///
/// - 统一 UA / Referer / Cookie
/// - 自动处理 WBI 签名所需的 imgKey / subKey 缓存
/// - 把 bilibili 的 {code, message, data} 信封拆开
class BiliClient {
  BiliClient._internal() {
    final adapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 15);
        return client;
      },
    );

    _dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 20),
        sendTimeout: const Duration(seconds: 20),
        followRedirects: true,
        validateStatus: (_) => true,
        responseType: ResponseType.plain,
      ),
    );
    _dio.httpClientAdapter = adapter;

    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.headers.putIfAbsent('User-Agent', () => userAgent);
          options.headers.putIfAbsent('Referer', () => referer);
          options.headers.putIfAbsent('Accept', () => 'application/json, text/plain, */*');
          options.headers.putIfAbsent('Accept-Language', () => 'zh-CN,zh;q=0.9');
          options.headers.putIfAbsent('Origin', () => 'https://www.bilibili.com');
          final cookie = jar.headerValue;
          if (cookie.isNotEmpty) options.headers['Cookie'] = cookie;
          handler.next(options);
        },
        onResponse: (response, handler) {
          final raw = response.headers['set-cookie'];
          if (raw != null && raw.isNotEmpty) jar.absorb(raw);
          handler.next(response);
        },
      ),
    );
  }

  static final BiliClient instance = BiliClient._internal();
  factory BiliClient() => instance;

  static const String userAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
  static const String referer = 'https://www.bilibili.com/';

  late final Dio _dio;
  Dio get dio => _dio;

  final CookieJar jar = CookieJar.instance;

  WbiSigner? _wbi;
  DateTime? _wbiFetchedAt;
  bool _bootstrapDone = false;

  /// 初始化：加载本地 cookie、注入 buvid、拉取 WBI key
  Future<void> bootstrap() async {
    if (_bootstrapDone) return;
    await jar.ensureLoaded();
    if ((jar['buvid3'] ?? '').isEmpty) {
      try {
        final spi = await getJson(
          'https://api.bilibili.com/x/frontend/finger/spi',
          withWbi: false,
          retryOnBuvid: false,
        );
        final data = spi['data'];
        if (data is Map) {
          final b3 = data['b_3']?.toString();
          final b4 = data['b_4']?.toString();
          final patch = <String, String>{};
          if (b3 != null && b3.isNotEmpty) patch['buvid3'] = b3;
          if (b4 != null && b4.isNotEmpty) patch['buvid4'] = b4;
          if (patch.isNotEmpty) await jar.setAll(patch);
        }
      } catch (_) {
        // 拿不到就用随机 buvid
      }
    }
    if ((jar['buvid3'] ?? '').isEmpty) {
      await jar.setAll({'buvid3': WbiSigner.randomBuvid3()});
    }
    _bootstrapDone = true;
    await _refreshWbi();
  }

  Future<WbiSigner> _refreshWbi() async {
    final cached = _wbi;
    final fetched = _wbiFetchedAt;
    if (cached != null && fetched != null && DateTime.now().difference(fetched).inHours < 6) {
      return cached;
    }
    final json = await getJson('https://api.bilibili.com/x/web-interface/nav', withWbi: false);
    final data = json['data'];
    String imgUrl = '';
    String subUrl = '';
    if (data is Map) {
      final wbi = data['wbi_img'];
      if (wbi is Map) {
        imgUrl = wbi['img_url']?.toString() ?? '';
        subUrl = wbi['sub_url']?.toString() ?? '';
      }
    }
    if (imgUrl.isEmpty || subUrl.isEmpty) {
      // 兜底：用上一次的 key，或抛错
      if (cached != null) return cached;
      throw BiliException('无法获取 WBI 签名密钥');
    }
    final signer = WbiSigner(
      imgKey: WbiSigner.keyFromUrl(imgUrl),
      subKey: WbiSigner.keyFromUrl(subUrl),
    );
    _wbi = signer;
    _wbiFetchedAt = DateTime.now();
    return signer;
  }

  /// 发请求并拆信封
  ///
  /// [withWbi] 为 true 时自动追加 WBI 签名参数。
  Future<Map<String, dynamic>> getJson(
    String url, {
    Map<String, dynamic>? query,
    bool withWbi = true,
    bool retryOnBuvid = true,
    int retries = 2,
  }) async {
    final params = <String, dynamic>{...?query};

    return _execute(
      url,
      params,
      withWbi: withWbi,
      retryOnBuvid: retryOnBuvid,
      retries: retries,
    );
  }

  Future<Map<String, dynamic>> _execute(
    String url,
    Map<String, dynamic> query, {
    bool withWbi = false,
    bool retryOnBuvid = true,
    int retries = 2,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt <= retries; attempt++) {
      try {
        // 注意：WBI 签名必须在循环内生成。
        // 否则刷新 buvid 后重试的仍是那个失效的 w_rid，重试永远不会成功。
        var requestUrl = url;
        var requestQuery = query;
        if (withWbi) {
          final signer = await _refreshWbi();
          final signed = signer.signQuery(query);
          final sep = url.contains('?') ? '&' : '?';
          requestUrl = '$url$sep$signed';
          requestQuery = const {};
        }

        final resp = await _dio.get<String>(
          requestUrl,
          queryParameters: requestQuery.isEmpty ? null : requestQuery,
        );
        final status = resp.statusCode ?? 0;
        if (status < 200 || status >= 300) {
          throw BiliException('HTTP $status', code: -status);
        }
        final body = resp.data ?? '';
        if (body.isEmpty) throw BiliException('空响应');

        final decoded = jsonDecode(body);
        if (decoded is! Map<String, dynamic>) {
          throw BiliException('响应格式异常');
        }
        final code = decoded['code'];
        if (code is int && code != 0) {
          final msg = decoded['message']?.toString() ?? '未知错误';
          // -412 被风控 / -352 校验失败：刷新 buvid 后重试一次
          if (retryOnBuvid && (code == -412 || code == -352) && attempt < 1) {
            await jar.setAll({'buvid3': WbiSigner.randomBuvid3()});
            _wbi = null;
            _wbiFetchedAt = null;
            await _refreshWbi();
            continue;
          }
          throw BiliException(msg, code: code);
        }
        return decoded;
      } on DioException catch (e) {
        lastError = e;
        if (attempt < retries) {
          await Future<void>.delayed(Duration(milliseconds: 400 * (attempt + 1)));
          continue;
        }
      } on BiliException {
        rethrow;
      } catch (e) {
        lastError = e;
        if (attempt < retries) {
          await Future<void>.delayed(Duration(milliseconds: 400 * (attempt + 1)));
          continue;
        }
      }
    }
    throw BiliException('网络请求失败：${_describe(lastError)}');
  }

  String _describe(Object? e) {
    if (e is DioException) {
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
          return '连接超时';
        case DioExceptionType.receiveTimeout:
          return '响应超时';
        case DioExceptionType.connectionError:
          return '网络不可用';
        default:
          return e.message ?? '未知网络错误';
      }
    }
    return e?.toString() ?? '未知错误';
  }

  /// 拉原始字节（弹幕 XML 是 raw deflate 压缩的）
  Future<List<int>> getBytes(
    String url, {
    Map<String, dynamic>? query,
    Map<String, String>? headers,
  }) async {
    final resp = await _dio.get<List<int>>(
      url,
      queryParameters: query,
      options: Options(
        headers: headers,
        responseType: ResponseType.bytes,
        validateStatus: (_) => true,
      ),
    );
    final status = resp.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw BiliException('HTTP $status', code: -status);
    }
    return resp.data ?? const <int>[];
  }
}

class BiliException implements Exception {
  BiliException(this.message, {this.code});

  final String message;
  final int? code;

  @override
  String toString() => message;
}
