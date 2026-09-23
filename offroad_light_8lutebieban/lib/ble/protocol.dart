import 'dart:convert';
import 'dart:typed_data';

/// 通信协议 —— 必须与 ESP32 固件 smart_spotlight_v2.ino 里的定义完全一致。
///
/// 封包: [0xA5][OP][LEN_hi][LEN_lo][payload...]
///
/// 设计要点:通道掩码就是"哪几路正在输出";整组命令(主灯/辅助灯按钮、语音)
/// 只是往几组灯上盖一张【图章】,盖完就不管了,之后 24 路由用户说了算。
class Protocol {
  static const serviceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
  static const rxUuid = '6e400002-b5a3-f393-e0a9-e50e24dcca9e'; // App 写入
  static const txUuid = '6e400003-b5a3-f393-e0a9-e50e24dcca9e'; // 设备上报

  static const deviceName = 'OffRoad-Light';
  static const magic = 0xA5;

  /// 这个 App 要求的固件协议版本,必须和固件里的 FW_VERSION 一致。20 = 2.0。
  ///
  /// 4 组版固件是 3,两条产品线的版本号故意岔开 —— 烧错了固件,
  /// 界面会直接报版本不匹配,而不是拿着别的格式的数据瞎显示。
  /// 改了封包格式【或者改了状态的语义】两边就都要 +1。
  static const fwVersion = 20;

  // ---- App -> 设备 ----
  static const opText = 0x01; // ASCII 调试命令
  static const opChMask = 0x11; // [b3,b2,b1,b0]      一次设置 32 位通道掩码
  static const opCh = 0x12; // [ch, on]               单个通道开关
  static const opBright = 0x14; // [duty 0~100]       白光亮度
  static const opQuery = 0x15; // []                  请求上报当前状态
  static const opGroupSet = 0x16; // [groups, action] 给这几组盖图章(bit g = 组 g)
  static const opParty = 0x17; // [on]                娱乐模式开/关

  // ---- 设备 -> App(Notify) ----
  // [party, flashMask, dimMask, bright, ver, m3, m2, m1, m0, boards]
  static const opStatus = 0x20;

  static Uint8List frame(int op, List<int> payload) {
    final len = payload.length;
    final out = Uint8List(4 + len);
    out[0] = magic;
    out[1] = op;
    out[2] = (len >> 8) & 0xFF;
    out[3] = len & 0xFF;
    out.setRange(4, 4 + len, payload);
    return out;
  }

  static Uint8List text(String cmd) => frame(opText, ascii.encode(cmd));

  static Uint8List chMask(int mask) => frame(opChMask, [
        (mask >> 24) & 0xFF,
        (mask >> 16) & 0xFF,
        (mask >> 8) & 0xFF,
        mask & 0xFF,
      ]);

  static Uint8List channel(int ch, bool on) =>
      frame(opCh, [ch & 0xFF, on ? 1 : 0]);

  static Uint8List brightness(int duty) =>
      frame(opBright, [duty.clamp(0, 100)]);

  static Uint8List query() => frame(opQuery, const []);

  static Uint8List groupSet(int groups, int act) =>
      frame(opGroupSet, [groups & 0xFF, act & 0xFF]);

  static Uint8List party(bool on) => frame(opParty, [on ? 1 : 0]);
}

/// 灯板主动上报的状态快照。
///
/// 语音、手机两边谁改了状态,设备都会推一帧过来,界面据此实时刷新 ——
/// 所以 App 永远显示设备的真实状态,而不是自己以为的状态。
class DeviceStatus {
  /// 娱乐模式开着没有。它是盖在上面显示的,底下的状态照样在 [chMask] 里。
  final bool party;

  /// 这几组的白光在爆闪(bit g = 第 g 组)
  final int flashMask;

  /// 这几组的白光只出 10%(主灯微亮)
  final int dimMask;

  /// 白光的亮度 0~100。日行灯和氛围灯是固定满亮,不受它影响。
  final int brightness;

  final int version;

  /// 32 位通道掩码,第 N 位 = CH N【现在亮不亮】。
  final int chMask;

  /// 哪片 PCA9685 在线:bit0 = 0x40 主灯板,bit1 = 0x41 辅助灯板。
  /// 只接一片的车,另一片那 4 组在界面上是灰的。
  final int boards;

  const DeviceStatus({
    required this.party,
    required this.flashMask,
    required this.dimMask,
    required this.brightness,
    required this.version,
    required this.chMask,
    required this.boards,
  });

  /// 解析 0x20 上报包的 payload,长度不够返回 null(丢包)。
  ///
  /// 版本号在第 4 个字节,和 4 组版固件的状态包是同一个位置 ——
  /// 所以就算连上的是 4 组版固件(只有 5 个字节),也能读出它的版本号,
  /// 界面直接报不匹配,不会拿那几个字节去刷界面。
  static DeviceStatus? parse(List<int> p) {
    if (p.length < 5) return null;
    final ver = p[4];
    if (p.length < 9) {
      return DeviceStatus(
        party: false,
        flashMask: 0,
        dimMask: 0,
        brightness: 0,
        version: ver,
        chMask: 0,
        boards: 0x03,
      );
    }
    return DeviceStatus(
      party: p[0] != 0,
      flashMask: p[1],
      dimMask: p[2],
      brightness: p[3],
      version: ver,
      chMask: (p[5] << 24) | (p[6] << 16) | (p[7] << 8) | p[8],
      // 早期的 2.0 固件没有这个字节,当成两片都在
      boards: p.length >= 10 ? p[9] & 0x03 : 0x03,
    );
  }

  @override
  String toString() =>
      'DeviceStatus(mask:0x${chMask.toRadixString(16).padLeft(8, '0')} '
      'flash:0x${flashMask.toRadixString(16)} dim:0x${dimMask.toRadixString(16)} '
      'party:$party bright:$brightness ver:$version boards:$boards)';
}
