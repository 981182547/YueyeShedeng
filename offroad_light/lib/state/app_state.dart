import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ble/ble_manager.dart';
import '../ble/protocol.dart';
import '../i18n/strings.dart';
import '../models/lamp.dart';

enum ConnState { disconnected, connecting, connected }

/// 全局状态。
///
/// 【谁说了算】设备是唯一权威:任何一帧 0x20 上报都会无条件覆盖本地状态。
/// 因为改变状态的不只有手机 —— 车上的语音也会改,手机自己记的那份随时可能是过期的。
///
/// 本地点击时先乐观更新一次界面(消掉蓝牙往返的延迟感),
/// 紧接着设备就会推真实状态回来纠正。指令丢了也不怕:设备每 2 秒兜底报一次。
class AppState extends ChangeNotifier {
  final SharedPreferences prefs;
  AppState(this.prefs);

  static Future<AppState> create() async {
    final st = AppState(await SharedPreferences.getInstance());
    st.loadLang(); // 启动就恢复上次选的语言,免得先闪一下中文再跳成英文
    return st;
  }

  BleManager? ble;

  // ---- 语言 ----
  /// 界面语言,由顶栏那个按钮切换,选择会记住。
  AppLang lang = AppLang.zh;

  /// 当前语言的文案表。界面层一律用 `state.s.xxx` 取文字。
  S get s => S(lang);

  void loadLang() {
    lang = prefs.getString('lang') == 'en' ? AppLang.en : AppLang.zh;
  }

  void setLang(AppLang l) {
    if (lang == l) return;
    lang = l;
    prefs.setString('lang', l == AppLang.en ? 'en' : 'zh');
    notifyListeners();
  }

  /// 顶栏按钮:中文 <-> English 来回切
  void toggleLang() =>
      setLang(lang == AppLang.zh ? AppLang.en : AppLang.zh);

  ConnState conn = ConnState.disconnected;
  String statusLog = '';

  // ---- 灯光状态 ----
  /// 当前模式。固件上电默认是关灯(车子点火不能自己亮),这里跟着默认关。
  int mode = LightMode.off;

  /// 16 位通道掩码,第 N 位 = CH N 的总开关。
  /// 每组第 4 位(CH3/7/11/15)恒为 0 —— 那一路没接线。
  int chMask = kChMaskAll;

  /// 白光模式的亮度。日行灯和氛围灯是固定满亮,不受它影响。
  int brightness = 100;

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

  bool get isConnected => conn == ConnState.connected;

  bool get isOff => mode == LightMode.off;

  /// 当前模式实际驱动的功能通道(关灯时为 null)
  int? get activeFn => activeFnOf(mode);

  /// 车图上该画成黄色还是白色
  bool get isAmbient => isAmbientMode(mode);

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
  void applyStatus(DeviceStatus st) {
    mode = st.mode;
    chMask = st.chMask & kChMaskAll;
    brightness = st.brightness;
    synced = true;
    reportCount++;
    notifyListeners();
  }

  /// 处理设备发来的任意封包
  void onDeviceMessage(int op, List<int> payload) {
    if (op == Protocol.opStatus) {
      final st = DeviceStatus.parse(payload);
      if (st != null) applyStatus(st);
    }
  }

  // ---- 通道 / 灯组查询 ----

  /// 某一路通道的总开关是不是开着
  bool isChOn(int ch) => (chMask & (1 << ch)) != 0;

  /// 一组的 3 路全开才算这组"开着"。半开状态在界面上单独显示。
  bool isGroupOn(LampGroup g) =>
      LampFn.all.every((fn) => isChOn(chOf(g.id, fn)));

  bool isGroupPartial(LampGroup g) {
    final on = LampFn.all.where((fn) => isChOn(chOf(g.id, fn))).length;
    return on > 0 && on < LampFn.all.length;
  }

  /// 开着的组数(只要有一路开着就算)
  int get onGroupCount => kGroups
      .where((g) => LampFn.all.any((fn) => isChOn(chOf(g.id, fn))))
      .length;

  /// 这一组这会儿到底亮不亮 —— 车图上只有这种才画成发光的。
  ///
  /// 要同时满足:有模式在出光,而且【当前模式那一路】的掩码位是开的。
  /// 唯一例外是爆闪:固件那边无视掩码 4 组一起闪,界面得跟着一起闪,
  /// 否则会出现"手机上某组不闪、车上却在闪"的对不上。
  bool isGroupLit(int groupId) {
    if (mode == LightMode.off) return false;
    if (mode == LightMode.flash) return true; // 爆闪无视掩码,全车都闪
    final fn = activeFn;
    if (fn == null) return false;
    return isChOn(chOf(groupId, fn));
  }

  /// 这一刻灯的实际亮度 0~100,车图按它决定光点画多亮。
  ///
  /// 只有白光模式跟滑条走;日行灯和氛围灯是固件定死的满亮,爆闪走节奏表。
  int get effectiveDuty => switch (mode) {
        LightMode.off => 0,
        LightMode.white => brightness,
        LightMode.drl => FixedDuty.drl,
        LightMode.ambient => FixedDuty.ambient,
        LightMode.flash => FixedDuty.flash,
        _ => 0,
      };

  /// 车图上画多亮 0~1。
  ///
  /// 占空比再乘一个【显示折扣】:日行灯和氛围灯虽然也给满占空比,
  /// 但那是另外一串灯珠,物理上就比射灯暗一大截,画面得跟车上看到的一致。
  double get lightIntensity =>
      ((effectiveDuty / 100) * displayScaleOf(mode)).clamp(0.0, 1.0);

  /// 亮度滑条只在白光模式下有意义,其余模式的亮度是固件定死的
  bool get brightnessAdjustable => mode == LightMode.white;

  // ---- 操作(乐观更新 + 下发) ----

  /// 切模式。掩码不动 —— 模式和掩码是两个独立维度。
  void setMode(int m) {
    mode = m;
    notifyListeners();
    ble?.send(Protocol.mode(m));
  }

  /// 单路通道开关(详情页那 12 个开关用)
  void toggleCh(int ch) {
    final on = !isChOn(ch);
    chMask = (on ? (chMask | (1 << ch)) : (chMask & ~(1 << ch))) & kChMaskAll;
    notifyListeners();
    ble?.send(Protocol.channel(ch, on));
  }

  /// 整组开关:一次切这组的 3 路。
  /// 全开就关掉;否则(全灭或半开)一律打开,点一下就有反应。
  void toggleGroup(LampGroup g) {
    final on = !isGroupOn(g);
    final bits = groupBits(g.id);
    chMask = (on ? (chMask | bits) : (chMask & ~bits)) & kChMaskAll;
    notifyListeners();
    ble?.send(Protocol.group(g.id, on));
  }

  void setChMask(int mask) {
    chMask = mask & kChMaskAll;
    notifyListeners();
    ble?.send(Protocol.chMask(chMask));
  }

  void allOn() => setChMask(kChMaskAll);
  void allOff() => setChMask(0);

  DateTime _lastBrightSend = DateTime.fromMillisecondsSinceEpoch(0);

  /// 设置亮度。
  ///
  /// 拖动时这个方法会被连续调用,每次都发一包蓝牙会把写队列堵住、灯反而跟不上手,
  /// 所以下发限流到 120ms 一次。界面自己是每次都刷的,拖起来依旧跟手。
  /// 松手时用 commit 补发一次最终值,免得灯停在限流丢掉的那个中间值上。
  void setBrightness(int duty, {bool commit = false}) {
    final v = duty.clamp(0, 100);
    if (v != brightness) {
      brightness = v;
      notifyListeners();
    }
    final now = DateTime.now();
    if (commit || now.difference(_lastBrightSend).inMilliseconds >= 120) {
      _lastBrightSend = now;
      ble?.send(Protocol.brightness(brightness));
    }
  }

  /// 拖动结束时调用:确保最终值一定发到设备
  void commitBrightness() => setBrightness(brightness, commit: true);

  /// 总开关:关灯 <-> 回到关灯前的那个模式
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
