import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../api/bili_api.dart';
import '../../widgets/error_view.dart';

/// 我的：登录状态 + 扫码登录
class MinePage extends StatefulWidget {
  const MinePage({super.key});

  @override
  State<MinePage> createState() => _MinePageState();
}

class _MinePageState extends State<MinePage>
    with AutomaticKeepAliveClientMixin {
  Map<String, dynamic>? _nav;
  bool _loading = true;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadNav();
  }

  Future<void> _loadNav() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await BiliApi.instance.bootstrap();
      final nav = await BiliApi.instance.navInfo();
      if (!mounted) return;
      setState(() {
        _nav = nav;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  bool get _isLogin => _nav?['isLogin'] == true;

  Future<void> _openLogin() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const LoginPage()),
    );
    if (ok == true) {
      await _loadNav();
    }
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定要清除本地登录信息吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await BiliApi.instance.logout();
    await _loadNav();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ErrorView(message: _error!, onRetry: _loadNav);
    }

    final uname = _nav?['uname']?.toString() ?? '';
    final face = _nav?['face']?.toString() ?? '';
    final level = _nav?['level_info']?['current_level'];
    final coins = _nav?['money'];
    final vip = _nav?['vipStatus'] == 1;

    return RefreshIndicator(
      onRefresh: _loadNav,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
        children: [
          if (_isLogin) ...[
            Center(
              child: CircleAvatar(
                radius: 38,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                backgroundImage: face.isEmpty ? null : NetworkImage(face),
                child: face.isEmpty ? const Icon(Icons.person, size: 36) : null,
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                uname.isEmpty ? '哔哩哔哩用户' : uname,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (vip)
              const Center(
                child: Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    '大会员',
                    style: TextStyle(
                      color: Color(0xFFFB7299),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 20),
            Row(
              children: [
                _StatBox(label: '等级', value: 'Lv${level ?? 0}'),
                _StatBox(label: '硬币', value: '${coins ?? 0}'),
              ],
            ),
            const SizedBox(height: 24),
            OutlinedButton(
              onPressed: _logout,
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
              child: const Text('退出登录'),
            ),
          ] else ...[
            Center(
              child: CircleAvatar(
                radius: 38,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                child: const Icon(Icons.person_outline, size: 40),
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                '未登录',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Center(
              child: Text(
                '登录后可观看高清视频',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 22),
            FilledButton(
              onPressed: _openLogin,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFFB7299),
                minimumSize: const Size.fromHeight(44),
              ),
              child: const Text('扫码登录'),
            ),
          ],
          const SizedBox(height: 32),
          const Divider(),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.info_outline),
            title: Text('关于 BiliPure'),
            subtitle: Text('第三方哔哩哔哩客户端 · 仅用于学习交流'),
          ),
        ],
      ),
    );
  }
}

class _StatBox extends StatelessWidget {
  const _StatBox({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 扫码登录页：生成二维码 + 轮询状态
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  QrLoginSession? _session;
  QrLoginStatus _status = QrLoginStatus.pending;
  String? _error;
  Timer? _poller;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _generate();
  }

  @override
  void dispose() {
    _poller?.cancel();
    super.dispose();
  }

  Future<void> _generate() async {
    _poller?.cancel();
    setState(() {
      _busy = true;
      _error = null;
      _status = QrLoginStatus.pending;
    });
    try {
      final session = await BiliApi.instance.qrLoginGenerate();
      if (!mounted) return;
      if (session.key.isEmpty || session.url.isEmpty) {
        throw Exception('二维码生成失败');
      }
      setState(() {
        _session = session;
        _busy = false;
      });
      _startPolling(session);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  void _startPolling(QrLoginSession session) {
    _poller?.cancel();
    _poller = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      try {
        final result = await BiliApi.instance.qrLoginPoll(session.key);
        if (!mounted) return;
        setState(() => _status = result.status);
        switch (result.status) {
          case QrLoginStatus.success:
            timer.cancel();
            // 等 cookie 落盘
            await Future<void>.delayed(const Duration(milliseconds: 300));
            if (mounted) Navigator.of(context).pop(true);
            break;
          case QrLoginStatus.expired:
            timer.cancel();
            break;
          default:
            break;
        }
      } catch (_) {
        // 轮询失败忽略，下个周期继续
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('扫码登录')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_busy)
                const CircularProgressIndicator()
              else if (_error != null)
                ErrorView(message: _error!, onRetry: _generate)
              else if (_session != null) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.06),
                        blurRadius: 16,
                      ),
                    ],
                  ),
                  child: QrImageView(
                    data: _session!.url,
                    size: 210,
                    backgroundColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  _status == QrLoginStatus.expired
                      ? '二维码已过期'
                      : _status == QrLoginStatus.scanned
                          ? '已扫码，请在手机上确认'
                          : '请使用哔哩哔哩 App 扫码',
                  style: theme.textTheme.bodyMedium,
                ),
                if (_status == QrLoginStatus.expired) ...[
                  const SizedBox(height: 16),
                  FilledButton.tonal(
                    onPressed: _generate,
                    child: const Text('刷新二维码'),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
