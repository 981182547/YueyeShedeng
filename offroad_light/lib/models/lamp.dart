import 'package:flutter/material.dart';

/// 灯位在车图上的形状:车顶是横向灯条,其余是圆形射灯
enum LampShape { round, bar }

/// 一个物理灯位。
///
/// [id] 必须和 ESP 固件里的灯位编号完全一致 —— 协议就是靠这个数字对齐的:
///   0 车顶左    1 车顶右    2 立柱左  3 立柱右
///   4 前包围左  5 前包围右  6 侧边左  7 侧边右
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

  const Lamp({
    required this.id,
    required this.name,
    required this.x,
    required this.y,
    required this.size,
    this.shape = LampShape.round,
  });
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

const List<Lamp> kLamps = [
  // ── 车顶:行李架前端两个横向灯条 ──
  Lamp(id: 0, name: '车顶左', x: 0.427, y: 0.158, size: 0.055, shape: LampShape.bar),
  Lamp(id: 1, name: '车顶右', x: 0.697, y: 0.187, size: 0.042, shape: LampShape.bar),
  // ── 立柱:A 柱上的两个圆形射灯 ──
  Lamp(id: 2, name: '立柱左', x: 0.450, y: 0.366, size: 0.040),
  Lamp(id: 3, name: '立柱右', x: 0.783, y: 0.358, size: 0.036),
  // ── 前包围:中网里的两个小射灯 ──
  Lamp(id: 4, name: '前包围左', x: 0.714, y: 0.515, size: 0.030),
  Lamp(id: 5, name: '前包围右', x: 0.792, y: 0.515, size: 0.030),
  // ── 侧边:翼子板两侧的圆形射灯 ──
  Lamp(id: 6, name: '侧边左', x: 0.588, y: 0.593, size: 0.042),
  Lamp(id: 7, name: '侧边右', x: 0.896, y: 0.590, size: 0.040),
];

const List<LampGroup> kGroups = [
  LampGroup(id: 0, name: '车顶', subtitle: '行李架 · 2 只', lampIds: [0, 1]),
  LampGroup(id: 1, name: '立柱', subtitle: 'A 柱 · 2 只', lampIds: [2, 3]),
  LampGroup(id: 2, name: '前包围', subtitle: '中网 · 2 只', lampIds: [4, 5]),
  LampGroup(id: 3, name: '侧边', subtitle: '翼子板 · 2 只', lampIds: [6, 7]),
];

Lamp lampById(int id) => kLamps.firstWhere((l) => l.id == id);

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
