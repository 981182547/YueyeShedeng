import 'dart:convert';
import 'dart:typed_data';

/// 通信协议 —— 必须与 ESP32 固件 smart_spotlight_ble.ino 里的定义完全一致。
///
/// 封包: [0xA5][OP][LEN_hi][LEN_lo][payload...]
///
/// 设计要点:颜色、模式、灯位是三个【互相独立】的维度。
///   颜色 白/黄            —— 灯发什么色
///   模式 常亮/日行/自动/爆闪 —— 灯怎么个亮法
///   灯位 8 位掩码          —— 哪几个灯位参与
/// 切模式不会把颜色弄丢,换颜色也不打断当前模式。
class Protocol {
  static const serviceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
  static const rxUuid = '6e400002-b5a3-f393-e0a9-e50e24dcca9e'; // App 写入
  static const txUuid = '6e400003-b5a3-f393-e0a9-e50e24dcca9e'; // 设备上报

  static const deviceName = 'OffRoad-Light';
  static const magic = 0xA5;

  // ---- App -> 设备 ----
  static const opText = 0x01; // ASCII 调试命令
  static const opMode = 0x10; // [mode]        切换模式
  static const opLampMask = 0x11; // [mask]    一次设置全部 8 个灯位
  static const opLamp = 0x12; // [lampId, on]  单个灯位开关
  static const opGroup = 0x13; // [groupId, on] 整组开关
  static const opBright = 0x14; // [duty 0~100]
  static const opQuery = 0x15; // []           请求上报当前状态
  static const opColor = 0x16; // [color]      0=白光 1=黄光

  // ---- 设备 -> App(Notify) ----
  // [mode, mask, bright, activeColor, night, rain, ver, userColor]
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

  static Uint8List lampMask(int mask) => frame(opLampMask, [mask & 0xFF]);

  static Uint8List lamp(int id, bool on) => frame(opLamp, [id & 0xFF, on ? 1 : 0]);

  static Uint8List group(int id, bool on) => frame(opGroup, [id & 0xFF, on ? 1 : 0]);

  static Uint8List brightness(int duty) =>
      frame(opBright, [duty.clamp(0, 100)]);

  /// 只换颜色,不动模式
  static Uint8List color(int c) => frame(opColor, [c & 0x01]);

  static Uint8List query() => frame(opQuery, const []);
}

/// 灯板主动上报的状态快照。
///
/// 语音、传感器、手机三方谁改了状态,设备都会推一帧过来,界面据此实时刷新 ——
/// 所以 App 永远显示设备的真实状态,而不是自己以为的状态。
class DeviceStatus {
  final int mode;
  final int lampMask;
  final int brightness;

  /// 这一刻【实际输出】的颜色:0=白光 1=黄光。
  /// 自动模式下遇到下雨会被设备临时改成黄光,所以只能由设备告诉我们,不能自己推算。
  /// 界面上灯的发光颜色用它。
  final int color;

  /// 用户【选定】的颜色。白/黄那个切换开关按它显示 ——
  /// 雨天自动转黄的时候,开关仍然停在用户选的那一档,雨停就还原回去。
  final int userColor;

  final bool night; // 光敏:是否夜间
  final bool rain; // 雨滴:是否正在下雨
  final int version;

  const DeviceStatus({
    required this.mode,
    required this.lampMask,
    required this.brightness,
    required this.color,
    required this.userColor,
    required this.night,
    required this.rain,
    required this.version,
  });

  bool get isYellow => color == 1;

  /// 解析 0x20 上报包的 payload,长度不够返回 null(丢包/固件版本不匹配)
  static DeviceStatus? parse(List<int> p) {
    if (p.length < 7) return null;
    return DeviceStatus(
      mode: p[0],
      lampMask: p[1],
      brightness: p[2],
      color: p[3],
      night: p[4] == 1,
      rain: p[5] == 1,
      version: p[6],
      // 旧固件只发 7 个字节,没有这一项时就拿实际颜色顶上
      userColor: p.length >= 8 ? p[7] : p[3],
    );
  }

  @override
  String toString() =>
      'DeviceStatus(mode:$mode mask:0x${lampMask.toRadixString(16)} '
      'bright:$brightness color:${isYellow ? "黄" : "白"} '
      'userColor:${userColor == 1 ? "黄" : "白"} '
      'night:$night rain:$rain)';
}
