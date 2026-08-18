import 'package:flutter/material.dart';

/// 灯位在车图上的形状:车顶是横向灯条,其余是圆形射灯
enum LampShape { round, bar }

/// 一个物理灯位。
///
/// [id] 必须和 ESP 固件里的灯位编号完全一致 —— 协议就是靠这个数字对齐的:
///   0 前包围左  1 前包围右   (车图上标「1」)
///   2 立柱下左  3 立柱下右   (车图上标「2」)
///   4 立柱上左  5 立柱上右   (车图上标「3」)
///   6 车顶左    7 车顶右     (车图上标「4」)
///
/// [x] [y] 是灯位中心在车辆图片上的【相对坐标】(0~1),不是像素。
/// 这样换手机、换分辨率都不用改,图片怎么缩放热区都跟得上。
class Lamp {
  final int id;
  final String name;
  final double x;
  final double y;
  final double size; // 相对图片宽度的尺寸
  final LampShape shape;

  /// 点击热区(相对坐标的矩形,左/上/右/下)。
  ///
  /// 故意比灯本身大一圈,把灯周围的空白也算进去,手指好点。
  /// 关键是相邻灯位的热区【上下相接但不重叠】—— 立柱上下那两个灯
  /// 中心只差 0.059,在手机上只隔 12dp,不这么分区就永远点不中下面那个。
  final double hx0, hy0, hx1, hy1;

  const Lamp({
    required this.id,
    required this.name,
    required this.x,
    required this.y,
    required this.size,
    required this.hx0,
    required this.hy0,
    required this.hx1,
    required this.hy1,
    this.shape = LampShape.round,
  });

  double get hitW => hx1 - hx0;
  double get hitH => hy1 - hy0;
}

/// 一组灯 = 车上同一个位置的左右两个灯位。
///
/// 组编号也要和固件对齐:固件里 组 g 控制的是灯位 g*2 和 g*2+1。
class LampGroup {
  final int id;
  final String name;
  final String subtitle;
  final List<int> lampIds;

  const LampGroup({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.lampIds,
  });
}

/// ══════════════════════════════════════════════════════════
/// 车辆图片与灯位坐标
///
/// 坐标是照着那张 Jeep 实拍图量的。如果你换了别的车图,或者发现灯位
/// 跟图对不上,只改下面这一张表就行,其它代码都不用动。
/// ══════════════════════════════════════════════════════════

/// 车图资源路径。
///
/// 首选这个文件名;如果没有,会自动扫 assets/images/ 下的第一张图来用 ——
/// 所以你把那张 Jeep 图丢进 assets/images/ 就行,叫什么名字、什么格式都不影响。
/// 图片的宽高比也是运行时从图片本身读的,不用手填,换图不会让热区偏掉。
const String kCarImagePreferred = 'assets/images/car.png';
const String kCarImageDir = 'assets/images/';

/// 坐标是在 assets/images/car.png(1672x941)上逐个量出来的:
/// 把灯位区域放大 5 倍、叠 0.01 步长的坐标网格，读出灯的外圈范围再取中心。
/// 换图之后重新量一遍这张表就行，其它代码都不用动。
const List<Lamp> kLamps = [
  // ── 1 前包围:保险杠两侧那对大圆灯 ──
  Lamp(
    id: 0, name: '前包围左', x: 0.591, y: 0.584, size: 0.046,
    hx0: 0.553, hy0: 0.491, hx1: 0.632, hy1: 0.659,
  ),
  Lamp(
    id: 1, name: '前包围右', x: 0.898, y: 0.583, size: 0.045,
    hx0: 0.855, hy0: 0.491, hx1: 0.937, hy1: 0.659,
  ),
  // ── 2 立柱下:A 柱上【下面】那对圆灯 ──
  //    热区往下吃掉到引擎盖之间的空白
  Lamp(
    id: 2, name: '立柱下左', x: 0.443, y: 0.368, size: 0.043,
    hx0: 0.414, hy0: 0.340, hx1: 0.472, hy1: 0.430,
  ),
  Lamp(
    id: 3, name: '立柱下右', x: 0.778, y: 0.368, size: 0.033,
    hx0: 0.752, hy0: 0.340, hx1: 0.818, hy1: 0.430,
  ),
  // ── 3 立柱上:A 柱上【上面】那对圆灯 ──
  //    热区往上吃掉到车顶之间的空白,下边界正好和「立柱下」相接
  Lamp(
    id: 4, name: '立柱上左', x: 0.443, y: 0.309, size: 0.043,
    hx0: 0.414, hy0: 0.238, hx1: 0.472, hy1: 0.336,
  ),
  Lamp(
    id: 5, name: '立柱上右', x: 0.778, y: 0.309, size: 0.033,
    hx0: 0.752, hy0: 0.238, hx1: 0.818, hy1: 0.336,
  ),
  // ── 4 车顶:行李架【前梁】上那对短灯条 ──
  //    注意不是顶上那根横跨整个车顶的长灯条，那根没有单独分组
  Lamp(
    id: 6, name: '车顶左', x: 0.463, y: 0.174, size: 0.036,
    shape: LampShape.bar,
    hx0: 0.423, hy0: 0.132, hx1: 0.507, hy1: 0.215,
  ),
  Lamp(
    id: 7, name: '车顶右', x: 0.693, y: 0.179, size: 0.039,
    shape: LampShape.bar,
    hx0: 0.651, hy0: 0.132, hx1: 0.742, hy1: 0.215,
  ),
];

/// 分组顺序特意和车图上标的编号一一对应:
/// 组 0 显示成「1」、组 1 显示成「2」…… 界面上标几,图上就是哪一组。
const List<LampGroup> kGroups = [
  LampGroup(id: 0, name: '前包围', subtitle: '保险杠两侧 · 2 只', lampIds: [0, 1]),
  LampGroup(id: 1, name: '立柱下', subtitle: 'A 柱下 · 2 只', lampIds: [2, 3]),
  LampGroup(id: 2, name: '立柱上', subtitle: 'A 柱上 · 2 只', lampIds: [4, 5]),
  LampGroup(id: 3, name: '车顶', subtitle: '行李架 · 2 只', lampIds: [6, 7]),
];

Lamp lampById(int id) => kLamps.firstWhere((l) => l.id == id);

/// 某个灯位属于哪一组
LampGroup groupOf(int lampId) =>
    kGroups.firstWhere((g) => g.lampIds.contains(lampId));

/// ══════════════════════════════════════════════════════════
/// 工作模式
///
/// 编号必须和固件的 enum SysMode 一致。
/// ══════════════════════════════════════════════════════════
class LightMode {
  static const off = 0;
  static const drl = 1; // 日行
  static const white = 2; // 白光
  static const yellow = 3; // 黄光
  static const auto = 4; // 自动
  static const flash = 5; // 爆闪
}

class ModeInfo {
  final int id;
  final String name;
  final IconData icon;

  /// 界面上这个模式的代表色。自动模式的实际颜色由车上的雨滴传感器决定,
  /// 所以它显示成中性色,真实颜色以设备上报的为准。
  final Color color;

  const ModeInfo(this.id, this.name, this.icon, this.color);
}

const List<ModeInfo> kModes = [
  ModeInfo(LightMode.drl, '日行', Icons.wb_twilight, Color(0xFFBFD4E6)),
  ModeInfo(LightMode.white, '白光', Icons.light_mode, Color(0xFFF2F6FF)),
  ModeInfo(LightMode.yellow, '黄光', Icons.wb_incandescent, Color(0xFFFFC53D)),
  ModeInfo(LightMode.auto, '自动', Icons.auto_mode, Color(0xFF4DD0A0)),
  ModeInfo(LightMode.flash, '爆闪', Icons.flash_on, Color(0xFFFF4D4D)),
];

ModeInfo? modeInfo(int id) {
  for (final m in kModes) {
    if (m.id == id) return m;
  }
  return null;
}

String modeName(int id) => switch (id) {
      LightMode.off => '关灯',
      LightMode.drl => '日行',
      LightMode.white => '白光',
      LightMode.yellow => '黄光',
      LightMode.auto => '自动',
      LightMode.flash => '爆闪',
      _ => '未知',
    };
