import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../theme.dart';

/// 灯在车图上的形状:圆形射灯,或者前杠那种细长灯条
enum LampShape { round, bar }

/// ══════════════════════════════════════════════════════════
/// 通道映射 —— 必须和固件 smart_spotlight_v2.ino 完全一致
///
/// 2.0 一共 8 组灯,编号和车图上标的一致;同一组的左右两只并联在一路上,
/// 永远一起亮灭。每组 3 个功能:白光 / 日行灯 / 氛围灯。8 × 3 = 24 路。
/// 接线板 4 路一组、用前 3 路,一共占 32 路,正好两片 PCA9685:
///
///   编号 组 灯组        分类    白光   日行   氛围   空     板子
///   1    0  前杠灯      主灯    CH0    CH1    CH2    CH3    0x40
///   2    1  A柱直射     主灯    CH4    CH5    CH6    CH7    0x40
///   3    2  A柱侧位     主灯    CH8    CH9    CH10   CH11   0x40
///   4    3  顶灯        主灯    CH12   CH13   CH14   CH15   0x40
///   5    4  前杠内侧    辅助灯  CH16   CH17   CH18   CH19   0x41
///   6    5  前杠外侧    辅助灯  CH20   CH21   CH22   CH23   0x41
///   7    6  右侧灯      辅助灯  CH24   CH25   CH26   CH27   0x41
///   8    7  左侧灯      辅助灯  CH28   CH29   CH30   CH31   0x41
/// ══════════════════════════════════════════════════════════

const int kGroupCount = 8;
const int kChPerGroup = 4; // 接线板一组 4 路
const int kChTotal = kGroupCount * kChPerGroup; // 32

/// 功能号。数值就是它在组内的偏移。
class LampFn {
  static const spot = 0; // 白光(射灯)
  static const drl = 1; // 日行灯
  static const ambient = 2; // 氛围灯(外圈黄光)

  static const all = [spot, drl, ambient];
}

/// 组号 + 功能号 -> 通道号 0~31
int chOf(int group, int fn) => group * kChPerGroup + fn;

/// 掩码里一组占的 3 个位(第 4 位是空通道,不置位)
int groupBits(int group) => 0x7 << (group * kChPerGroup);

/// 24 路全开。空通道那几位(CH3/7/11/…/31)恒为 0。
const int kChMaskAll = 0x77777777;

/// 8 组全选(组掩码,bit g = 第 g 组)
const int kGroupsAll = 0xFF;

/// 开机状态:主灯 1~4 组日行灯亮(CH1/5/9/13),辅助灯全灭。
/// 和固件 applyBootState() 一致,没连上设备时界面就先按这个画。
const int kBootMask = 0x2222;

/// 主灯 / 辅助灯。[groups] 是组掩码,bit g = 第 g 组。
class Section {
  final int id;
  final int groups;

  /// 只有主灯有「微亮」
  final bool hasDim;

  const Section(this.id, this.groups, {this.hasDim = false});

  bool contains(int g) => ((groups >> g) & 1) == 1;

  List<int> get groupIds =>
      [for (var g = 0; g < kGroupCount; g++) if (contains(g)) g];
}

const kSectionMain = Section(0, 0x0F, hasDim: true); // 编号 1~4
const kSectionAux = Section(1, 0xF0); // 编号 5~8
const kSections = [kSectionMain, kSectionAux];

Section sectionOf(int group) => group < 4 ? kSectionMain : kSectionAux;

/// 一个灯在车图上的画点。
///
/// 车图上画着 14 个灯,但只有 8 组 —— 同组的两只并联在一路上,永远一起亮灭。
/// 所以这张表只是"画在哪儿、点哪儿",开关状态一律按 [group] 查。
///
/// [x] [y] 是灯中心在车辆图片上的【相对坐标】(0~1),不是像素。
/// 这样换手机、换分辨率都不用改,图片怎么缩放热区都跟得上。
class Lamp {
  final int id;
  final int group;
  final double x;
  final double y;
  final double size; // 灯的宽度,相对图片宽度
  final LampShape shape;

  /// 点击热区(相对坐标的矩形,左/上/右/下)。
  ///
  /// 故意比灯本身大一圈,手指好点;相邻两组的热区【相接但不重叠】——
  /// A 柱上直射和侧位两只挨着,在手机上只隔几 dp,不这么分区就点不准。
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

/// 灯条画出来的高度 = 宽度 × 这个比例。前杠那几根灯条又细又长。
const double kBarHeightRatio = 0.24;

/// 一组灯 = 车上左右两只(7、8 号各只有一只),共用一路。
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
/// 坐标是照着 2.0 那张红色 Jeep 图(newcar.png,2730×1535)量的:
/// 取每个灯发光部分的像素,圆灯算质心和直径,灯条取外框,再换算成相对坐标。
/// 画出来的圆比量到的灯面大 12%,灯关着时那层暗色才能把原图里亮着的灯盖严。
/// 换图之后重新量一遍这张表就行,其它代码都不用动。
/// ══════════════════════════════════════════════════════════

const String kCarImagePreferred = 'assets/images/newcar.png';
const String kCarImageDir = 'assets/images/';

const List<Lamp> kLamps = [
  // ── 1 前杠灯:保险杠两头那对大圆灯 ──
  Lamp(
    id: 0, group: 0, x: 0.590, y: 0.556, size: 0.041,
    hx0: 0.550, hy0: 0.500, hx1: 0.630, hy1: 0.615,
  ),
  Lamp(
    id: 1, group: 0, x: 0.901, y: 0.549, size: 0.041,
    hx0: 0.860, hy0: 0.490, hx1: 0.945, hy1: 0.610,
  ),
  // ── 2 A柱直射:A 柱上靠里(靠引擎盖)那只 ──
  Lamp(
    id: 2, group: 1, x: 0.450, y: 0.328, size: 0.030,
    hx0: 0.433, hy0: 0.280, hx1: 0.478, hy1: 0.385,
  ),
  Lamp(
    id: 3, group: 1, x: 0.777, y: 0.329, size: 0.036,
    hx0: 0.748, hy0: 0.280, hx1: 0.796, hy1: 0.385,
  ),
  // ── 3 A柱侧位:A 柱上靠外(靠后视镜)那只 ──
  Lamp(
    id: 4, group: 2, x: 0.414, y: 0.328, size: 0.036,
    hx0: 0.385, hy0: 0.280, hx1: 0.433, hy1: 0.385,
  ),
  Lamp(
    id: 5, group: 2, x: 0.811, y: 0.329, size: 0.028,
    hx0: 0.796, hy0: 0.280, hx1: 0.840, hy1: 0.385,
  ),
  // ── 4 顶灯:车顶灯架中间那两只 ──
  Lamp(
    id: 6, group: 3, x: 0.550, y: 0.121, size: 0.032,
    hx0: 0.522, hy0: 0.070, hx1: 0.5705, hy1: 0.175,
  ),
  Lamp(
    id: 7, group: 3, x: 0.591, y: 0.124, size: 0.032,
    hx0: 0.5705, hy0: 0.070, hx1: 0.620, hy1: 0.175,
  ),
  // ── 5 前杠内侧:中网前面上排那两根灯条 ──
  Lamp(
    id: 8, group: 4, x: 0.694, y: 0.505, size: 0.054,
    shape: LampShape.bar,
    hx0: 0.660, hy0: 0.475, hx1: 0.738, hy1: 0.547,
  ),
  Lamp(
    id: 9, group: 4, x: 0.784, y: 0.504, size: 0.050,
    shape: LampShape.bar,
    hx0: 0.748, hy0: 0.475, hx1: 0.825, hy1: 0.547,
  ),
  // ── 6 前杠外侧:防撞杠下排那两根灯条 ──
  //    热区上边界正好和「前杠内侧」的下边界相接
  Lamp(
    id: 10, group: 5, x: 0.723, y: 0.589, size: 0.059,
    shape: LampShape.bar,
    hx0: 0.685, hy0: 0.547, hx1: 0.7565, hy1: 0.625,
  ),
  Lamp(
    id: 11, group: 5, x: 0.790, y: 0.587, size: 0.051,
    shape: LampShape.bar,
    hx0: 0.7565, hy0: 0.547, hx1: 0.830, hy1: 0.625,
  ),
  // ── 7 右侧灯:车顶灯架【图片左端】那只 ——
  //    这张图拍的是车的右侧面,所以图片左边是车的右边 ──
  Lamp(
    id: 12, group: 6, x: 0.413, y: 0.111, size: 0.034,
    hx0: 0.385, hy0: 0.060, hx1: 0.445, hy1: 0.170,
  ),
  // ── 8 左侧灯:车顶灯架【图片右端】那只 ──
  Lamp(
    id: 13, group: 7, x: 0.708, y: 0.131, size: 0.033,
    hx0: 0.678, hy0: 0.080, hx1: 0.740, hy1: 0.185,
  ),
];

/// 组号 0~7 显示成 1~8,正好是车图上标的编号。
const List<LampGroup> kGroups = [
  LampGroup(id: 0),
  LampGroup(id: 1),
  LampGroup(id: 2),
  LampGroup(id: 3),
  LampGroup(id: 4),
  LampGroup(id: 5),
  LampGroup(id: 6),
  LampGroup(id: 7),
];

LampGroup groupById(int id) => kGroups[id];

/// 名字全部走文案表查,不写死在上面那些常量里 ——
/// 坐标表是硬件事实,文字是界面语言,两者分开各管各的。
String groupName(S s, int id) => s.groupName(id);
String groupSubtitle(S s, int id) => s.groupSubtitle(id);
String sectionName(S s, Section sec) =>
    sec.id == kSectionMain.id ? s.sectionMain : s.sectionAux;

String fnName(S s, int fn) => switch (fn) {
      LampFn.spot => s.fnSpot,
      LampFn.drl => s.fnDrl,
      LampFn.ambient => s.fnAmbient,
      _ => '',
    };

/// ══════════════════════════════════════════════════════════
/// 整组动作 = 一个【图章】
///
/// 语音「打开主灯日行」、主页上主灯/辅助灯那两排按钮,都是往几组灯上盖图章:
/// 把这几组的 3 路连同修饰一起重设,每组同一时间只有一种状态,新的替换旧的。
///
///   白光 -> 只开白光      日行 -> 只开日行      氛围 -> 只开氛围
///   爆闪 -> 只开白光+闪   微亮 -> 日行 + 白光 10%   关 -> 3 路全灭
///
/// 盖完就不管了 —— 之后分路控制页那 24 个开关是最高权限。
/// 编号必须和固件的 enum GroupAct 一致。
/// ══════════════════════════════════════════════════════════
class GroupAct {
  static const off = 0;
  static const white = 1;
  static const drl = 2;
  static const ambient = 3;
  static const flash = 4;
  static const dim = 5;
}

/// 从三路开关 + 两个修饰反推这组是哪个图章。
/// 分路页手动改过、对不上任何一种,返回 null。
int? groupActOf(int chMask, int flashMask, int dimMask, int g) {
  final bits = (chMask >> (g * kChPerGroup)) & 0x7;
  final flash = ((flashMask >> g) & 1) == 1;
  final dim = ((dimMask >> g) & 1) == 1;
  const spot = 1 << LampFn.spot;
  const drl = 1 << LampFn.drl;
  const amb = 1 << LampFn.ambient;

  if (bits == 0) return GroupAct.off;
  if (bits == spot && flash) return GroupAct.flash;
  if (bits == (spot | drl) && dim) return GroupAct.dim;
  if (flash || dim) return null;
  if (bits == spot) return GroupAct.white;
  if (bits == drl) return GroupAct.drl;
  if (bits == amb) return GroupAct.ambient;
  return null;
}

class ActInfo {
  final int act;
  final IconData icon;

  /// 按钮选中时的强调色。跟灯实际发什么色大体对应,
  /// 但它只是按钮的辨识色,真正的发光效果由车图那边画。
  final Color color;

  const ActInfo(this.act, this.icon, this.color);
}

const kActWhite = ActInfo(GroupAct.white, Icons.lightbulb_circle, Color(0xFF7FB2FF));
const kActDrl = ActInfo(GroupAct.drl, Icons.wb_twilight, Color(0xFFBFD4E6));
const kActAmbient = ActInfo(GroupAct.ambient, Icons.blur_circular, Color(0xFFFFB84D));
const kActFlash = ActInfo(GroupAct.flash, Icons.flash_on, Color(0xFFFF4D4D));
const kActDim = ActInfo(GroupAct.dim, Icons.brightness_low, Color(0xFF9FB6D9));
const kActOff = ActInfo(GroupAct.off, Icons.power_settings_new, AppColors.textHi);

/// 这一区有哪些按钮。辅助灯没有微亮,那一格空着,让「关」上下对齐。
List<ActInfo?> actSlots(Section sec) => [
      kActWhite,
      kActDrl,
      kActAmbient,
      kActFlash,
      sec.hasDim ? kActDim : null,
      kActOff,
    ];

String actName(S s, int? act) => switch (act) {
      GroupAct.off => s.actOff,
      GroupAct.white => s.actWhite,
      GroupAct.drl => s.actDrl,
      GroupAct.ambient => s.actAmbient,
      GroupAct.flash => s.actFlash,
      GroupAct.dim => s.actDim,
      _ => s.customized,
    };

/// ══════════════════════════════════════════════════════════
/// 娱乐模式:8 组一组一组轮流闪
///
/// 照抄固件的 partyOrder / PARTY_STEP_MS —— 车图上的动画和车上是同一个节奏。
/// ══════════════════════════════════════════════════════════
const List<int> kPartyOrder = [0, 1, 2, 3, 4, 5, 6, 7];
const int kPartyStepMs = 60;
const int kPartyStepsPerGroup = 4; // 每组 亮-灭-亮-灭
const int kPartyCycleMs = kGroupCount * kPartyStepsPerGroup * kPartyStepMs;

/// 一圈里第 [ms] 毫秒亮的是哪一组;正好是灭的那一拍就返回 null
int? partyGroupAt(int ms) {
  final step = (ms ~/ kPartyStepMs) % (kGroupCount * kPartyStepsPerGroup);
  if ((step % kPartyStepsPerGroup).isOdd) return null;
  return kPartyOrder[step ~/ kPartyStepsPerGroup];
}

/// 固件里定死的几个亮度(对应 .ino 里的 DUTY_*)。
///
/// 白光跟手机滑条走;日行灯和氛围灯固定满亮 —— 那些灯珠本身就比射灯暗得多,
/// 再降就看不见了;主灯微亮时白光固定 10%。改了固件的 DUTY_* 记得同步这里。
class FixedDuty {
  static const drl = 100; // DUTY_DRL
  static const ambient = 100; // DUTY_AMBIENT
  static const dim = 10; // DUTY_DIM
}

/// 车图上这一路该画多亮 —— 和 PWM 占空比是两回事。
///
/// 日行灯和氛围灯虽然也给满占空比,但那是【另外一串灯珠】,物理上就比
/// 射灯暗一大截。画面要跟车上看到的一致,所以这里单独打个折。
double fnDisplayScale(int fn) => switch (fn) {
      LampFn.spot => 1.00,
      LampFn.drl => 0.45, // 日行灯:白色,但明显暗一截
      LampFn.ambient => 0.55, // 氛围灯:外圈一圈黄,弱亮
      _ => 0.0,
    };

/// 这一路灯本身是什么颜色 —— 只有氛围灯是黄的
Color fnColor(int fn) =>
    fn == LampFn.ambient ? AppColors.lightYellow : AppColors.lightWhite;
