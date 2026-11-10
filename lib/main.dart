import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api/bili_api.dart';
import 'pages/home/home_page.dart';
import 'pages/mine/mine_page.dart';
import 'pages/popular/popular_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ),
  );
  runApp(const BiliPureApp());
}

class BiliPureApp extends StatelessWidget {
  const BiliPureApp({super.key});

  @override
  Widget build(BuildContext context) {
    const pink = Color(0xFFFB7299);
    return MaterialApp(
      title: 'BiliPure',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: pink,
          brightness: Brightness.light,
        ).copyWith(primary: pink),
        scaffoldBackgroundColor: const Color(0xFFF7F7F8),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF7F7F8),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            color: Color(0xFF18191C),
            fontSize: 19,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      home: const RootShell(),
    );
  }
}

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // 预热：拿 buvid 与 WBI key，避免首页首屏等待
    BiliApi.instance.bootstrap().catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    // 底部 home indicator 的安全间距。Material 3 的 NavigationBar 不会
    // 自动避开它，必须手动补 padding，否则标签会被刘海遮住一半。
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return Scaffold(
      // 顶部安全区：避免内容被刘海 / 状态栏遮挡
      body: SafeArea(
        top: true,
        bottom: false,
        child: IndexedStack(
          index: _index,
          children: const [HomePage(), PopularPage(), MinePage()],
        ),
      ),
      bottomNavigationBar: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          height: 58,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded),
              label: '推荐',
            ),
            NavigationDestination(
              icon: Icon(Icons.local_fire_department_outlined),
              selectedIcon: Icon(Icons.local_fire_department_rounded),
              label: '热门',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline_rounded),
              selectedIcon: Icon(Icons.person_rounded),
              label: '我的',
            ),
          ],
        ),
      ),
    );
  }
}
