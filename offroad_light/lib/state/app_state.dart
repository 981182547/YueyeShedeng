import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ble/ble_manager.dart';
import '../ble/protocol.dart';
import '../models/lamp.dart';

enum ConnState { disconnected, connecting, connected }

/// 全局状态。
///
/// 【谁说了算】设备是唯一权威:任何一帧 0x20 上报都会无条件覆盖本地状态。
/// 因为改变状态的不只有手机 —— 车上的语音、光敏、雨滴传感器都会改,
/// 手机自己记的那份随时可能是过期的。
///
/// 本地点击时先乐观更新一次界面(消掉蓝牙往返的延迟感),
/// 紧接着设备就会推真实状态回来纠正。指令丢了也不怕:设备每 2 秒兜底报一次。
class AppState extends ChangeNotifier {
  final SharedPreferences prefs;
  AppState(this.prefs);

  static Future<AppState> create() async =>
      AppState(await SharedPreferences.getInstance());

  BleManager? ble;

  ConnState conn = ConnState.disconnected;
  String statusLog = '';

  // ---- 灯光状态(默认值 = 固件的出厂默认:白光常亮、全部灯位打开) ----
  int mode = LightMode.steady;
  int lampMask = 0xFF;
  int brightness = 100;

  /// 用户【选定】的颜色,0=白 1=黄。白/黄那个切换开关显示的是它。
  int userColor = LightColorId.white;

  /// 这一刻【实际输出】的颜色。正常等于 userColor,
  /// 只有自动模式遇上下雨才被设备临时改成黄光 —— 车图上的发光颜色用它。
  int activeColor = LightColorId.white;

  bool night = false;
  bool rain = false;

  /// 是否收到过设备的状态上报。没连上时界面显示的只是上次的记忆值。
  bool synced = false;

  /// 收到过多少帧设备上报。
  ///
  /// 排查"车上用语音改了灯、手机没跟着变"就看它:
  /// 设备每 2 秒会兜底推一帧,所以连着的时候这个数字应该一直在涨。
  /// 不涨 = 上报链路断了,界面显示的是过期状态。
  int reportCount = 0;

  /// Notify 订阅成功了没(订不上就收不到任何上报)
  bool get notifyReady => ble?.notifyReady ?? false;

  /// 灯这一刻是不是黄的(界面配色跟着它走)
  bool get isYellow => activeColor == LightColorId.yellow;

  /// 用户选的是不是黄光(白/黄开关的位置跟着它走)
  bool get pickedYellow => userColor == LightColorId.yellow;

  /// 自动模式下雨滴把颜色抢走了 —— 界面要说明一下为什么和所选的不一样
  bool get colorOverridden => activeColor != userColor;

  bool get isConnected => conn == ConnState.connected;

  // ---- 上次连接的设备,下次打开自动连回去 ----
  String? get savedDeviceId => prefs.getString('device_id');
  void rememberDevice(String id) => prefs.setString('device_id', id);

  void setLog(String msg) {
    statusLog = msg;
    notifyListeners();
  }

  void setConn(ConnState c) {
    conn = c;
    if (c != ConnState.connected) {
      synced = false;
      reportCount = 0;
    }
    notifyListeners();
  }

  /// 收到设备上报:无条件覆盖本地状态。
  void applyStatus(DeviceStatus s) {
    mode = s.mode;
    lampMask = s.lampMask;
    brightness = s.brightness;
    activeColor = s.color;
    userColor = s.userColor;
    night = s.night;
    rain = s.rain;
    synced = true;
    reportCount++;
    notifyListeners();
  }

  /// 处理设备发来的任意封包
  void onDeviceMessage(int op, List<int> payload) {
    if (op == Protocol.opStatus) {
      final s = DeviceStatus.parse(payload);
      if (s != null) applyStatus(s);
    }
  }

  // ---- 灯位查询 ----
  bool isLampOn(int id) => (lampMask & (1 << id)) != 0;

  /// 一组里只要全亮才算这组"开着"。半开状态在界面上单独显示。
  bool isGroupOn(LampGroup g) => g.lampIds.every(isLampOn);
  bool isGroupPartial(LampGroup g) =>
      g.lampIds.any(isLampOn) && !g.lampIds.every(isLampOn);

  int get onCount => kLamps.where((l) => isLampOn(l.id)).length;

  /// 灯位开着,并且当前模式确实在出光 —— 车图上只有这种才画成发光的
  bool isLampLit(int id) => isLampOn(id) && mode != LightMode.off;

  /// 这一刻灯的实际亮度 0~100,车图按它决定光点画多亮。
  ///
  /// 只有常亮模式跟滑条走;日行是固定低亮、自动看光敏、爆闪走节奏表,
  /// 都是固件说了算,这里照着固件的常量算一份。
  int get effectiveDuty => switch (mode) {
        LightMode.off => 0,
        LightMode.steady => brightness,
        LightMode.drl => FixedDuty.drl,
        LightMode.auto => night ? FixedDuty.autoNight : FixedDuty.autoDay,
        LightMode.flash => FixedDuty.flash,
        _ => 0,
      };

  /// 归一化成 0~1,给界面调发光强度用
  double get lightIntensity => (effectiveDuty / 100).clamp(0.0, 1.0);

  // ---- 操作(乐观更新 + 下发) ----

  /// 只切模式,不动颜色
  void setMode(int m) {
    mode = m;
    // 除了自动模式(颜色可能被雨滴抢走),其它模式的颜色就是用户选的那个
    if (m != LightMode.auto) activeColor = userColor;
    notifyListeners();
    ble?.send(Protocol.mode(m));
  }

  /// 只切颜色,不动模式 —— 日行/爆闪/常亮都会立刻换成这个颜色
  void setColor(int c) {
    userColor = c;
    // 自动模式下雨时颜色归传感器管,这里不抢,等设备上报
    if (mode != LightMode.auto) activeColor = c;
    notifyListeners();
    ble?.send(Protocol.color(c));
  }

  void toggleColor() => setColor(
      pickedYellow ? LightColorId.white : LightColorId.yellow);

  void toggleLamp(int id) {
    final on = !isLampOn(id);
    lampMask = on ? (lampMask | (1 << id)) : (lampMask & ~(1 << id));
    notifyListeners();
    ble?.send(Protocol.lamp(id, on));
  }

  void toggleGroup(LampGroup g) {
    // 整组全亮就关掉;否则(全灭或半开)一律点亮,点一下就有反应
    final on = !isGroupOn(g);
    for (final id in g.lampIds) {
      lampMask = on ? (lampMask | (1 << id)) : (lampMask & ~(1 << id));
    }
    notifyListeners();
    ble?.send(Protocol.group(g.id, on));
  }

  void setLampMask(int mask) {
    lampMask = mask & 0xFF;
    notifyListeners();
    ble?.send(Protocol.lampMask(lampMask));
  }

  void allOn() => setLampMask(0xFF);
  void allOff() => setLampMask(0x00);

  void setBrightness(int duty) {
    brightness = duty.clamp(0, 100);
    notifyListeners();
    ble?.send(Protocol.brightness(brightness));
  }

  /// 总开关:关灯 <-> 回到关灯前的那个模式
  void togglePower() {
    if (mode == LightMode.off) {
      setMode(_lastLitMode);
    } else {
      _lastLitMode = mode;
      setMode(LightMode.off);
    }
  }

  int _lastLitMode = LightMode.steady;

  /// 界面重新拉一次设备状态(下拉刷新 / 重连之后)
  void refresh() => ble?.send(Protocol.query());
}
