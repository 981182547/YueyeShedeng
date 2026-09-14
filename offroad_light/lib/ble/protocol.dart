import 'dart:convert';
import 'dart:typed_data';

/// 通信协议 —— 必须与 ESP32 固件 smart_spotlight_ble.ino 里的定义完全一致。
///
/// 封包: [0xA5][OP][LEN_hi][LEN_lo][payload...]
///
/// 设计要点:通道掩码就是"哪几路正在输出",模式只是个【预设图章】——
/// 切模式的那一刻往 12 路上盖一张掩码,盖完就不管了,之后这 12 位由用户说了算。
/// 模式剩下的唯一作用:射灯那一路要不要按节奏闪。
class Protocol {
  static const serviceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
  static const rxUuid = '6e400002-b5a3-f393-e0a9-e50e24dcca9e'; // App 写入
  static const txUuid = '6e400003-b5a3-f393-e0a9-e50e24dcca9e'; // 设备上报

  static const deviceName = 'OffRoad-Light';
  static const magic = 0xA5;

  // ---- App -> 设备 ----
  static const opText = 0x01; // ASCII 调试命令
  static const opMode = 0x10; // [mode]        切换模式
  static const opChMask = 0x11; // [hi, lo]    一次设置 16 位通道掩码
  static const opCh = 0x12; // [ch, on]        单个通道开关
  // 0x13 原来是 opGroup。整组开关现在由 App 算好整张掩码走 opChMask 下发,
  // 省得"整组怎么算"这条规则在固件和 App 各写一遍、哪天改歪了对不上。
  static const opBright = 0x14; // [duty 0~100] 射灯白光的亮度
  static const opQuery = 0x15; // []           请求上报当前状态

  // ---- 设备 -> App(Notify) ----
  // [mode, maskHi, maskLo, bright, ver]
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

  static Uint8List mode(int m) => frame(opMode, [m & 0xFF]);

  static Uint8List chMask(int mask) =>
      frame(opChMask, [(mask >> 8) & 0xFF, mask & 0xFF]);

  static Uint8List channel(int ch, bool on) =>
      frame(opCh, [ch & 0xFF, on ? 1 : 0]);

  static Uint8List brightness(int duty) =>
      frame(opBright, [duty.clamp(0, 100)]);

  static Uint8List query() => frame(opQuery, const []);
}

/// 灯板主动上报的状态快照。
///
/// 语音、手机两边谁改了状态,设备都会推一帧过来,界面据此实时刷新 ——
/// 所以 App 永远显示设备的真实状态,而不是自己以为的状态。
class DeviceStatus {
  final int mode;

  /// 16 位通道掩码,第 N 位 = CH N【现在亮不亮】。
  /// 每组第 4 位(CH3/7/11/15)恒为 0 —— 那一路没接线。
  final int chMask;

  /// 射灯白光那一路的亮度 0~100。日行灯和氛围灯是固定满亮,不受它影响。
  final int brightness;

  final int version;

  const DeviceStatus({
    required this.mode,
    required this.chMask,
    required this.brightness,
    required this.version,
  });

  /// 解析 0x20 上报包的 payload,长度不够返回 null(丢包/固件版本不匹配)
  static DeviceStatus? parse(List<int> p) {
    if (p.length < 5) return null;
    return DeviceStatus(
      mode: p[0],
      chMask: (p[1] << 8) | p[2],
      brightness: p[3],
      version: p[4],
    );
  }

  @override
  String toString() =>
      'DeviceStatus(mode:$mode mask:0x${chMask.toRadixString(16).padLeft(4, '0')} '
      'bright:$brightness ver:$version)';
}
