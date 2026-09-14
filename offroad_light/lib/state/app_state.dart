import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ble/ble_manager.dart';
import '../ble/protocol.dart';
import '../i18n/strings.dart';
import '../models/lamp.dart';
import '../theme.dart';

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

  /// 16 位通道掩码,第 N 位 = CH N【现在亮不亮】。
  /// 它没有别的含义 —— 不是"允许亮",就是"亮着"。
  /// 每组第 4 位(CH3/7/11/15)恒为 0 —— 那一路没接线。
  ///
  /// 开机默认关灯,关灯的图章就是全灭,所以初值是 0。
  int chMask = 0;

  /// 射灯白光那一路的亮度。日行灯和氛围灯是固定满亮,不受它影响。
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

  /// 当前模式盖的是哪个功能通道(关灯时为 null)
  int? get activeFn => activeFnOf(mode);

  /// 一路灯都没亮
  bool get allDark => chMask == 0;

  /// 用户在分路控制页动过手,现在的通道状态已经和模式的图章不一样了。
  /// 界面上要标出来,否则"选着白光却亮着黄的"会让人以为是 bug。
  bool get customized => chMask != modePattern(mode);

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

  /// 这一组某一路亮不亮
  bool isGroupFnOn(int groupId, int fn) => isChOn(chOf(groupId, fn));

  /// 这一组有没有任意一路亮着
  bool isGroupLit(int groupId) =>
      LampFn.all.any((fn) => isChOn(chOf(groupId, fn)));

  /// 亮着的组数(只要有一路亮就算)
  int get onGroupCount =>
      kGroups.where((g) => isGroupLit(g.id)).length;

  /// 这一路这会儿出多少亮度 0~100 —— 按【功能】算,跟当前什么模式无关。
  ///
  /// 只有射灯那一路跟滑条走;日行灯和氛围灯是固件定死的满亮。
  /// 所以在白光模式下手动点一路氛围灯,它照样按氛围灯自己的亮度亮。
  int fnDuty(int fn) => switch (fn) {
        LampFn.spot => brightness,
        LampFn.drl => FixedDuty.drl,
        LampFn.ambient => FixedDuty.ambient,
        _ => 0,
      };

  /// 车图上这一路画多亮 0~1。
  ///
  /// 占空比再乘一个【显示折扣】:日行灯和氛围灯虽然也给满占空比,
  /// 但那是另外一串灯珠,物理上就比射灯暗一大截,画面得跟车上看到的一致。
  double fnIntensity(int fn) =>
      ((fnDuty(fn) / 100) * fnDisplayScale(fn)).clamp(0.0, 1.0);

  /// 亮度滑条只管射灯那一路。没有一路射灯亮着时就没什么可调的,置灰。
  bool get brightnessAdjustable =>
      kGroups.any((g) => isChOn(chOf(g.id, LampFn.spot)));

  /// 这一组该染成什么色 —— 看它【实际亮着的是哪一路】,不看模式。
  ///
  /// 分路控制页是最高权限,完全可能出现"白光模式下某组只留了氛围灯"。
  /// 白光优先:射灯或日行灯亮着就是白的,只剩氛围灯才是黄的。
  Color groupLitColor(int groupId) {
    if (isGroupFnOn(groupId, LampFn.spot) ||
        isGroupFnOn(groupId, LampFn.drl)) {
      return AppColors.lightWhite;
    }
    if (isGroupFnOn(groupId, LampFn.ambient)) return AppColors.lightYellow;
    return AppColors.lightWhite; // 全灭,取个默认值,反正不会画出来
  }

  /// 整车这会儿是什么色,顶上那个状态点用它
  Color get litColor {
    final anyWhite = kGroups.any((g) =>
        isGroupFnOn(g.id, LampFn.spot) || isGroupFnOn(g.id, LampFn.drl));
    if (anyWhite) return AppColors.lightWhite;
    final anyAmber = kGroups.any((g) => isGroupFnOn(g.id, LampFn.ambient));
    return anyAmber ? AppColors.lightYellow : AppColors.lightWhite;
  }

  // ---- 操作(乐观更新 + 下发) ----

  /// 切模式 = 往 12 路上盖一张图章,盖完模式就不管了。
  ///
  /// 就算已经是这个模式也照盖一次 —— 用户在分路控制页手动改花了之后,
  /// 再点一下当前模式就能一键复位,这是唯一的复位入口。
  void setMode(int m) {
    mode = m;
    chMask = modePattern(m);
    notifyListeners();
    ble?.send(Protocol.mode(m));
  }

  /// 单路通道开关(分路控制页那 12 个开关用)。
  /// 这是最高权限:直接开关这一路的输出,不受当前模式约束。
  void toggleCh(int ch) {
    final on = !isChOn(ch);
    chMask = (on ? (chMask | (1 << ch)) : (chMask & ~(1 << ch))) & kChMaskAll;
    notifyListeners();
    ble?.send(Protocol.channel(ch, on));
  }

  /// 整组开关(主页车图和组卡片用)。
  ///
  /// 这组有任意一路亮着 -> 整组熄掉;
  /// 一路都不亮       -> 点亮【当前模式那一路】,而不是三路全开 ——
  ///                     白光模式下点一组,要的是这组的射灯,不是连日行灯一起。
  ///
  /// 算好整张掩码再下发,不走单独的"整组"指令 ——
  /// 免得这条规则在固件和 App 各写一遍,哪天改歪了两边对不上。
  void toggleGroup(LampGroup g) {
    final bits = groupBits(g.id);
    if (isGroupLit(g.id)) {
      setChMask(chMask & ~bits);
    } else {
      final fn = activeFn;
      // 关灯模式下没有"当前那一路",默认给射灯 —— 点一下总得有反应
      setChMask(chMask | (1 << chOf(g.id, fn ?? LampFn.spot)));
    }
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

  /// 总开关:全灭 <-> 回到熄灯前的那个模式。
  ///
  /// 判据是【有没有灯亮着】而不是模式是不是关灯——
  /// 分路控制页可以在关灯模式下手动点亮某一路,那时候按一下也该能全灭。
  void togglePower() {
    if (allDark) {
      setMode(_lastLitMode);
    } else {
      if (mode != LightMode.off) _lastLitMode = mode;
      setMode(LightMode.off);
    }
  }

  int _lastLitMode = LightMode.white;

  /// 界面重新拉一次设备状态(下拉刷新 / 重连之后)
  void refresh() => ble?.send(Protocol.query());
}
