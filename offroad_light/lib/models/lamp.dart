import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../theme.dart';

/// 灯在车图上的形状:车顶是横向灯条,其余是圆形射灯
enum LampShape { round, bar }

/// ══════════════════════════════════════════════════════════
/// 通道映射 —— 必须和固件 smart_spotlight_ble.ino 完全一致
///
/// 车上 4 组灯,左右两只并联受同一路控制(点左边点右边都是一起亮)。
/// 每组 3 个功能:射灯白光 / 日行灯 / 氛围灯。4 × 3 = 12 路。
/// 接线板 4 路一组,所以按【每组占 4 路、用前 3 路】排,第 4 路空着。
///
///   组  位置      射灯白   日行灯   氛围灯   空
///   0   前包围     CH0     CH1     CH2     CH3
///   1   立柱下     CH4     CH5     CH6     CH7
///   2   立柱上     CH8     CH9     CH10    CH11
///   3   车顶       CH12    CH13    CH14    CH15
/// ══════════════════════════════════════════════════════════

const int kGroupCount = 4;
const int kChPerGroup = 4; // 接线板一组 4 路
const int kChTotal = kGroupCount * kChPerGroup; // 16

/// 功能号。数值就是它在组内的偏移。
class LampFn {
  static const spot = 0; // 射灯白光
  static const drl = 1; // 日行灯
  static const ambient = 2; // 氛围灯(外圈黄光)

  static const all = [spot, drl, ambient];
}

/// 组号 + 功能号 -> PCA9685 通道号
int chOf(int group, int fn) => group * kChPerGroup + fn;

/// 掩码里一组占的 3 个位(第 4 位是空通道,不置位)
int groupBits(int group) => 0x7 << (group * kChPerGroup);

/// 12 路全开。空通道那 4 位(CH3/7/11/15)恒为 0。
const int kChMaskAll = 0x7777;

/// 一个灯在车图上的画点。
///
/// 注意:车图上画着 8 个灯(每组左右各一只),但它们【不是 8 个独立控制单元】——
/// 同组的两只并联在一路上,永远一起亮灭。所以这张表只是"画在哪儿、点哪儿",
/// 开关状态一律按 [group] 查。
///
/// [x] [y] 是灯中心在车辆图片上的【相对坐标】(0~1),不是像素。
/// 这样换手机、换分辨率都不用改,图片怎么缩放热区都跟得上。
class Lamp {
  final int id;
  final int group;
  final double x;
  final double y;
  final double size; // 相对图片宽度的尺寸
  final LampShape shape;

  /// 点击热区(相对坐标的矩形,左/上/右/下)。
  ///
  /// 故意比灯本身大一圈,把灯周围的空白也算进去,手指好点。
  /// 关键是相邻灯的热区【上下相接但不重叠】—— 立柱上下那两个灯
  /// 中心只差 0.059,在手机上只隔 12dp,不这么分区就永远点不中下面那个。
  final double hx0, hy0, hx1, hy1;

  const Lamp({
    required this.id,
    required this.group,
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

/// 一组灯 = 车上同一排的左右两只,共用一路 PWM。
class LampGroup {
  final int id;
  const LampGroup({required this.id});

  int get spotCh => chOf(id, LampFn.spot);
  int get drlCh => chOf(id, LampFn.drl);
  int get ambientCh => chOf(id, LampFn.ambient);
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
  // ── 组 0 前包围:保险杠两侧那对大圆灯 ──
  Lamp(
    id: 0, group: 0, x: 0.591, y: 0.584, size: 0.046,
    hx0: 0.553, hy0: 0.491, hx1: 0.632, hy1: 0.659,
  ),
  Lamp(
    id: 1, group: 0, x: 0.898, y: 0.583, size: 0.045,
    hx0: 0.855, hy0: 0.491, hx1: 0.937, hy1: 0.659,
  ),
  // ── 组 1 立柱下:A 柱上【下面】那对圆灯 ──
  //    热区往下吃掉到引擎盖之间的空白
  Lamp(
    id: 2, group: 1, x: 0.443, y: 0.368, size: 0.043,
    hx0: 0.414, hy0: 0.340, hx1: 0.472, hy1: 0.430,
  ),
  Lamp(
    id: 3, group: 1, x: 0.778, y: 0.368, size: 0.033,
    hx0: 0.752, hy0: 0.340, hx1: 0.818, hy1: 0.430,
  ),
  // ── 组 2 立柱上:A 柱上【上面】那对圆灯 ──
  //    热区往上吃掉到车顶之间的空白,下边界正好和「立柱下」相接
  Lamp(
    id: 4, group: 2, x: 0.443, y: 0.309, size: 0.043,
    hx0: 0.414, hy0: 0.238, hx1: 0.472, hy1: 0.336,
  ),
  Lamp(
    id: 5, group: 2, x: 0.778, y: 0.309, size: 0.033,
    hx0: 0.752, hy0: 0.238, hx1: 0.818, hy1: 0.336,
  ),
  // ── 组 3 车顶:行李架【前梁】上那对短灯条 ──
  //    注意不是顶上那根横跨整个车顶的长灯条，那根没有单独分组
  Lamp(
    id: 6, group: 3, x: 0.463, y: 0.174, size: 0.036,
    shape: LampShape.bar,
    hx0: 0.423, hy0: 0.132, hx1: 0.507, hy1: 0.215,
  ),
  Lamp(
    id: 7, group: 3, x: 0.693, y: 0.179, size: 0.039,
    shape: LampShape.bar,
    hx0: 0.651, hy0: 0.132, hx1: 0.742, hy1: 0.215,
  ),
];

/// 分组顺序特意和车图上标的编号一一对应:
/// 组 0 显示成「1」、组 1 显示成「2」…… 界面上标几,图上就是哪一组。
const List<LampGroup> kGroups = [
  LampGroup(id: 0),
  LampGroup(id: 1),
  LampGroup(id: 2),
  LampGroup(id: 3),
];

LampGroup groupById(int id) => kGroups[id];

/// 名字全部走文案表查,不写死在上面那些常量里 ——
/// 坐标表是硬件事实,文字是界面语言,两者分开各管各的。
String groupName(S s, int id) => switch (id) {
      0 => s.groupBumper,
      1 => s.groupPillarLow,
      2 => s.groupPillarHigh,
      3 => s.groupRoof,
      _ => '',
    };

String groupSubtitle(S s, int id) => switch (id) {
      0 => s.subBumper,
      1 => s.subPillarLow,
      2 => s.subPillarHigh,
      3 => s.subRoof,
      _ => '',
    };

String fnName(S s, int fn) => switch (fn) {
      LampFn.spot => s.fnSpot,
      LampFn.drl => s.fnDrl,
      LampFn.ambient => s.fnAmbient,
      _ => '',
    };

/// ══════════════════════════════════════════════════════════
/// 模式 —— 选了哪个模式就亮哪一路灯,互斥
///
/// 没有独立的"颜色"维度了:白光就是射灯那一路,氛围灯就是外圈黄光那一路。
/// 【黄光不爆闪】是结构上保证的 —— 爆闪只驱动射灯白光,氛围灯通道恒 0。
/// 编号必须和固件的 enum SysMode 一致。
/// ══════════════════════════════════════════════════════════

class LightMode {
  static const off = 0; // 关灯(上电默认)
  static const white = 1; // 白光:射灯白,亮度跟滑条
  static const drl = 2; // 日行灯
  static const ambient = 3; // 氛围灯:外圈那圈黄光
  static const flash = 4; // 爆闪:射灯白按节奏闪,无视掩码
}

/// 每个模式实际驱动的是哪个功能通道。关灯时没有。
int? activeFnOf(int mode) => switch (mode) {
      LightMode.white => LampFn.spot,
      LightMode.drl => LampFn.drl,
      LightMode.ambient => LampFn.ambient,
      LightMode.flash => LampFn.spot,
      _ => null,
    };

/// 固件里定死的几个亮度档(对应 .ino 里的 DUTY_*)。
///
/// 只有白光模式用得上滑条:日行灯和氛围灯是固定满亮 —— 那些灯珠本身
/// 就比射灯暗得多,再降就基本看不见了。改了固件的 DUTY_* 记得同步这里。
class FixedDuty {
  static const drl = 100; // DUTY_DRL
  static const ambient = 100; // DUTY_AMBIENT
  static const flash = 100;
}

/// 车图上这个模式该画多亮 —— 和 PWM 占空比是两回事。
///
/// 日行灯和氛围灯虽然都给满占空比,但那是【另外一串灯珠】,物理上就比
/// 射灯暗一大截。画面要跟车上看到的一致,所以这里单独打个折。
double displayScaleOf(int mode) => switch (mode) {
      LightMode.white => 1.00,
      LightMode.flash => 1.00,
      LightMode.drl => 0.45, // 日行灯:白色,但明显暗一截
      LightMode.ambient => 0.55, // 氛围灯:外圈一圈黄,弱亮
      _ => 0.0,
    };

/// 这个模式画出来是什么颜色
bool isAmbientMode(int mode) => mode == LightMode.ambient;

/// 当前模式下灯是什么色 —— 只有氛围灯是黄的,射灯和日行灯都是白的
Color lightColorOf(int mode) =>
    isAmbientMode(mode) ? AppColors.lightYellow : AppColors.lightWhite;

class ModeInfo {
  final int id;
  final IconData icon;

  /// 按钮选中时的强调色。跟灯实际发什么色大体对应,
  /// 但它只是按钮的辨识色,真正的发光效果由车图那边画。
  final Color color;

  const ModeInfo(this.id, this.icon, this.color);
}

const List<ModeInfo> kModes = [
  ModeInfo(LightMode.white, Icons.lightbulb_circle, Color(0xFF7FB2FF)),
  ModeInfo(LightMode.drl, Icons.wb_twilight, Color(0xFFBFD4E6)),
  ModeInfo(LightMode.ambient, Icons.blur_circular, Color(0xFFFFB84D)),
  ModeInfo(LightMode.flash, Icons.flash_on, Color(0xFFFF4D4D)),
];

ModeInfo? modeInfo(int id) {
  for (final m in kModes) {
    if (m.id == id) return m;
  }
  return null;
}

String modeName(S s, int id) => switch (id) {
      LightMode.off => s.modeOff,
      LightMode.white => s.modeWhite,
      LightMode.drl => s.modeDrl,
      LightMode.ambient => s.modeAmbient,
      LightMode.flash => s.modeFlash,
      _ => s.modeUnknown,
    };

String modeHint(S s, int id) => switch (id) {
      LightMode.white => s.hintWhite,
      LightMode.drl => s.hintDrl,
      LightMode.ambient => s.hintAmbient,
      LightMode.flash => s.hintFlash,
      _ => '',
    };
