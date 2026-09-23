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
  /// 32 位通道掩码,第 N 位 = CH N【现在亮不亮】。
  /// 它没有别的含义 —— 不是"允许亮",就是"亮着"。
  ///
  /// 初值就是固件的开机状态:主灯 1~4 组日行灯亮,辅助灯全灭。
  int chMask = kBootMask;

  /// 这几组的白光在爆闪(bit g = 第 g 组)
  int flashMask = 0;

  /// 这几组的白光只出 10%(主灯微亮)
  int dimMask = 0;

  /// 娱乐模式。它是盖在上面显示的:底下的 [chMask] 一直没动,退出就原样恢复。
  bool party = false;

  /// 白光的亮度。日行灯和氛围灯是固定满亮,不受它影响。
  int brightness = 100;

  /// 是否收到过设备的状态上报。没连上时界面显示的只是开机默认值。
  bool synced = false;

  /// 设备报上来的固件协议版本。还没收到过上报时是 null。
  int? deviceVersion;

  /// 固件和 App 不是同一版 —— 界面上要拦一下。
  ///
  /// 最常见的就是 2.0 的 App 连上了 4 组版的固件:能连上、状态也在刷,
  /// 但同样几个字节在两版里含义不一样,显示出来的东西全是错的。
  bool get versionMismatch =>
      deviceVersion != null && deviceVersion != Protocol.fwVersion;

  /// 收到过多少帧设备上报。
  ///
  /// 排查"车上用语音改了灯、手机没跟着变"就看它:
  /// 设备每 2 秒会兜底推一帧,所以连着的时候这个数字应该一直在涨。
  /// 不涨 = 上报链路断了,界面显示的是过期状态。
  int reportCount = 0;

  /// Notify 订阅成功了没(订不上就收不到任何上报)
  bool get notifyReady => ble?.notifyReady ?? false;

  bool get isConnected => conn == ConnState.connected;

  /// 一路灯都没亮。娱乐模式开着也算亮着。
  bool get allDark => chMask == 0 && !party;

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
      deviceVersion = null; // 换设备可能换固件版本,别沿用上一台的
    }
    notifyListeners();
  }

  /// 收到设备上报:无条件覆盖本地状态。
  ///
  /// 版本对不上就【只记版本、不覆盖状态】—— 别的格式的字节按这版解出来
  /// 是没有意义的数字,拿它去刷界面只会让人以为是 App 坏了。
  /// 界面那边会顶一条横幅出来提示重烧固件。
  void applyStatus(DeviceStatus st) {
    deviceVersion = st.version;
    if (versionMismatch) {
      notifyListeners();
      return;
    }
    chMask = st.chMask & kChMaskAll;
    flashMask = st.flashMask & kGroupsAll;
    dimMask = st.dimMask & kGroupsAll;
    party = st.party;
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

  /// 某一路通道是不是开着
  bool isChOn(int ch) => (chMask & (1 << ch)) != 0;

  /// 这一组某一路亮不亮
  bool isGroupFnOn(int groupId, int fn) => isChOn(chOf(groupId, fn));

  /// 这一组有没有任意一路亮着
  bool isGroupLit(int groupId) =>
      LampFn.all.any((fn) => isChOn(chOf(groupId, fn)));

  bool isGroupFlashing(int groupId) => ((flashMask >> groupId) & 1) == 1;
  bool isGroupDim(int groupId) => ((dimMask >> groupId) & 1) == 1;

  /// 亮着的组数(只要有一路亮就算)
  int get onGroupCount => kGroups.where((g) => isGroupLit(g.id)).length;

  /// 这组现在是哪个图章;分路页手动改过、对不上任何一种就是 null
  int? groupAct(int groupId) =>
      groupActOf(chMask, flashMask, dimMask, groupId);

  /// 主灯/辅助灯这一区是不是统一在某个图章上:是就返回它,各组不一样就是 null。
  /// 主页那两排按钮靠它决定高亮哪一个。
  int? sectionAct(Section sec) {
    int? act;
    for (final g in sec.groupIds) {
      final a = groupAct(g);
      if (a == null) return null;
      if (act == null) {
        act = a;
      } else if (act != a) {
        return null;
      }
    }
    return act;
  }

  /// 有没有哪组被分路页手动改过(对不上任何图章)
  bool get anyCustom => kGroups.any((g) => groupAct(g.id) == null);

  /// 这一组的这一路这会儿出多少亮度 0~100。
  ///
  /// 白光跟滑条走,微亮的组固定 10%;日行灯和氛围灯是固件定死的满亮。
  int fnDuty(int groupId, int fn) => switch (fn) {
        LampFn.spot => isGroupDim(groupId) ? FixedDuty.dim : brightness,
        LampFn.drl => FixedDuty.drl,
        LampFn.ambient => FixedDuty.ambient,
        _ => 0,
      };

  /// 车图上这一路画多亮 0~1。
  ///
  /// 占空比再乘一个【显示折扣】:日行灯和氛围灯虽然也给满占空比,
  /// 但那是另外一串灯珠,物理上就比射灯暗一大截,画面得跟车上看到的一致。
  double fnIntensity(int groupId, int fn) =>
      ((fnDuty(groupId, fn) / 100) * fnDisplayScale(fn)).clamp(0.0, 1.0);

  /// 亮度滑条只管白光常亮的组 —— 爆闪固定满亮、微亮固定 10%,都不跟滑条。
  /// 一组这样的都没有,就没什么可调的,置灰。
  bool get brightnessAdjustable =>
      !party &&
      kGroups.any((g) =>
          isGroupFnOn(g.id, LampFn.spot) &&
          !isGroupFlashing(g.id) &&
          !isGroupDim(g.id));

  /// 这一组该染成什么色 —— 看它【实际亮着的是哪一路】。
  /// 白光优先:白光或日行灯亮着就是白的,只剩氛围灯才是黄的。
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
    if (party) return AppColors.lightWhite;
    final anyWhite = kGroups.any((g) =>
        isGroupFnOn(g.id, LampFn.spot) || isGroupFnOn(g.id, LampFn.drl));
    if (anyWhite) return AppColors.lightWhite;
    final anyAmber = kGroups.any((g) => isGroupFnOn(g.id, LampFn.ambient));
    return anyAmber ? AppColors.lightYellow : AppColors.lightWhite;
  }

  // ---- 操作(乐观更新 + 下发) ----

  /// 给这几组盖图章(bit g = 第 g 组)。
  ///
  /// 就算已经是这个状态也照盖一次 —— 分路页手动改花了之后,
  /// 再点一下同一个按钮就能一键复位。
  void applyGroups(int groups, int act) {
    _stamp(groups, act);
    notifyListeners();
    ble?.send(Protocol.groupSet(groups, act));
  }

  void applySection(Section sec, int act) => applyGroups(sec.groups, act);

  /// 和固件 applyGroups() 同一套规则,先按它乐观更新界面
  void _stamp(int groups, int act) {
    party = false; // 任何灯光命令都先退出娱乐模式
    for (var g = 0; g < kGroupCount; g++) {
      if (((groups >> g) & 1) == 0) continue;
      final gb = 1 << g;
      chMask &= ~groupBits(g);
      flashMask &= ~gb;
      dimMask &= ~gb;
      final spot = 1 << chOf(g, LampFn.spot);
      switch (act) {
        case GroupAct.white:
          chMask |= spot;
        case GroupAct.drl:
          chMask |= 1 << chOf(g, LampFn.drl);
        case GroupAct.ambient:
          chMask |= 1 << chOf(g, LampFn.ambient);
        case GroupAct.flash:
          chMask |= spot;
          flashMask |= gb;
        case GroupAct.dim:
          chMask |= spot | (1 << chOf(g, LampFn.drl));
          dimMask |= gb;
      }
    }
  }

  /// 娱乐模式开关。关掉之后底下原来的状态原样恢复。
  void setParty(bool on) {
    party = on;
    notifyListeners();
    ble?.send(Protocol.party(on));
  }

  void toggleParty() => setParty(!party);

  /// 换掩码的统一规则,和固件 applyMask() 一致:
  /// 先退出娱乐模式;白光被关掉的组,爆闪/微亮的修饰一起清掉 ——
  /// 修饰说的是"白光怎么亮",白光都灭了它就没意义了。
  void _setMask(int mask) {
    party = false;
    chMask = mask & kChMaskAll;
    for (var g = 0; g < kGroupCount; g++) {
      if (!isGroupFnOn(g, LampFn.spot)) {
        flashMask &= ~(1 << g);
        dimMask &= ~(1 << g);
      }
    }
  }

  /// 单路通道开关(分路控制页那 24 个开关用)。
  /// 这是最高权限:直接开关这一路的输出。
  void toggleCh(int ch) {
    final on = !isChOn(ch);
    _setMask(on ? (chMask | (1 << ch)) : (chMask & ~(1 << ch)));
    notifyListeners();
    ble?.send(Protocol.channel(ch, on));
  }

  void setChMask(int mask) {
    _setMask(mask);
    notifyListeners();
    ble?.send(Protocol.chMask(chMask));
  }

  void allOn() => setChMask(kChMaskAll);
  void allOff() => setChMask(0);

  /// 整组开关(车图和组卡片用)。
  ///
  /// 这组亮着 -> 整组关掉;
  /// 灭着     -> 跟同一区(主灯/辅助灯)里其它亮着的组保持一致,
  ///             一个亮着的都没有就开白光 —— 点一下总得有反应。
  void toggleGroup(LampGroup g) {
    if (isGroupLit(g.id) && !party) {
      applyGroups(1 << g.id, GroupAct.off);
      return;
    }
    var act = GroupAct.white;
    for (final other in sectionOf(g.id).groupIds) {
      final a = groupAct(other);
      if (other != g.id && a != null && a != GroupAct.off) {
        act = a;
        break;
      }
    }
    applyGroups(1 << g.id, act);
  }

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

  /// 总开关:有灯亮着(或者在娱乐模式)就全关;全灭的时候回到开机那个样子 ——
  /// 主灯日行、辅助灯灭,和车子点火时一样。
  void togglePower() {
    if (allDark) {
      applySection(kSectionMain, GroupAct.drl);
    } else {
      applyGroups(kGroupsAll, GroupAct.off);
    }
  }

  /// 界面重新拉一次设备状态(下拉刷新 / 重连之后)
  void refresh() => ble?.send(Protocol.query());
}
