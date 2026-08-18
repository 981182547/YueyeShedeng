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

  // ---- 灯光状态(默认值 = 固件的出厂默认:白光、全部灯位打开) ----
  int mode = LightMode.white;
  int lampMask = 0xFF;
  int brightness = 100;

  /// 当前实际输出的颜色,0=白 1=黄。
  /// 自动模式下由车上的雨滴传感器决定,只能由设备告诉我们。
  int activeColor = 0;

  bool night = false;
  bool rain = false;

  /// 是否收到过设备的状态上报。没连上时界面显示的只是上次的记忆值。
  bool synced = false;

  bool get isYellow => activeColor == 1;
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
    if (c != ConnState.connected) synced = false;
    notifyListeners();
  }

  /// 收到设备上报:无条件覆盖本地状态。
  void applyStatus(DeviceStatus s) {
    mode = s.mode;
    lampMask = s.lampMask;
    brightness = s.brightness;
    activeColor = s.color;
    night = s.night;
    rain = s.rain;
    synced = true;
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

  // ---- 操作(乐观更新 + 下发) ----

  void setMode(int m) {
    mode = m;
    // 白光/黄光模式下界面颜色可以立刻确定;自动模式要等设备按雨滴传感器上报
    if (m == LightMode.yellow) activeColor = 1;
    if (m == LightMode.white || m == LightMode.drl) activeColor = 0;
    notifyListeners();
    ble?.send(Protocol.mode(m));
  }

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

  /// 总开关:关灯 <-> 回到上一次的常亮模式
  void togglePower() {
    if (mode == LightMode.off) {
      setMode(_lastLitMode);
    } else {
      _lastLitMode = mode;
      setMode(LightMode.off);
    }
  }

  int _lastLitMode = LightMode.white;

  /// 界面重新拉一次设备状态(下拉刷新 / 重连之后)
  void refresh() => ble?.send(Protocol.query());
}
