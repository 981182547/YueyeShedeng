import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ble/ble_manager.dart';
import 'screens/home_screen.dart';
import 'state/app_state.dart';
import 'theme.dart';

/// 全局 messenger:BLE 的日志在任何页面都能弹出提示
final messengerKey = GlobalKey<ScaffoldMessengerState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  final state = await AppState.create();
  runApp(SpotlightApp(state: state));
}

class SpotlightApp extends StatefulWidget {
  final AppState state;
  const SpotlightApp({super.key, required this.state});

  @override
  State<SpotlightApp> createState() => _SpotlightAppState();
}

class _SpotlightAppState extends State<SpotlightApp> {
  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();

    state.ble = BleManager(
      onState: (c) {
        state.setConn(switch (c) {
          Conn.connected => ConnState.connected,
          Conn.disconnected => ConnState.disconnected,
          _ => ConnState.connecting,
        });
      },
      onLog: (msg) {
        state.setLog(msg);
        _toast(msg);
      },
      onRemember: state.rememberDevice,
      // 设备主动上报的状态在这里落到界面上
      onDeviceMessage: state.onDeviceMessage,
    );

    // 记得上次连的设备就自动连回去,不用每次都手动挑
    WidgetsBinding.instance.addPostFrameCallback((_) {
      state.ble?.tryAutoConnect(state.savedDeviceId);
    });
  }

  void _toast(String msg) {
    final m = messengerKey.currentState;
    if (m == null) return;
    m.clearSnackBars();
    m.showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 13)),
        backgroundColor: AppColors.surfaceHi,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(12),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  void dispose() {
    state.ble?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SPOTLIGHT',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: messengerKey,
      theme: buildTheme(),
      home: AppScope(
        state: state,
        child: HomeScreen(state: state),
      ),
    );
  }
}
