import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle, AssetManifest;

import '../i18n/strings.dart';
import '../models/lamp.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// 调坐标时打开它,会把每个灯的点击热区用青色框画出来,
/// 一眼就能看出热区有没有盖住灯、相邻的有没有重叠。发版前记得关掉。
const bool kShowHitAreas = false;

/// 一组灯这会儿三路各自亮不亮 + 各自多亮。
///
/// 三路可以【同时】亮 —— 分路控制页是最高权限,用户完全可以在白光之外
/// 再单独点一路氛围灯。所以不能按状态选一种画法,得三路叠着画:
///
///   白光   -> 实心白、强光晕
///   日行灯 -> 也是白的,但整体暗一截
///   氛围灯 -> 灯的区域【里面画一圈黄环】,中间不填,弱亮
class LampLit {
  final double spot; // 白光的亮度 0~1,0 = 不亮
  final double drl;
  final double ambient;

  const LampLit({required this.spot, required this.drl, required this.ambient});

  static const dark = LampLit(spot: 0, drl: 0, ambient: 0);

  /// 灯芯画成实心白:白光和日行灯都是白的,谁亮取谁(白光更亮就用白光)
  double get solid => spot > drl ? spot : drl;
  bool get anySolid => solid > 0;
  bool get hasRing => ambient > 0;
  bool get any => anySolid || hasRing;
}

/// 光点上标什么数字
enum LampLabel {
  none,

  /// 标所属【组】的编号 1~8,和车图上标注的编号一致
  group,
}

/// 车辆实拍图 + 灯组热区。
///
/// 图片按原始比例铺满,灯用【相对坐标】叠在上面,所以任何屏幕尺寸下
/// 光点都长在车上正确的位置。坐标表在 models/lamp.dart。
///
/// 车图上有 14 个灯,但只有 8 组 —— 同一组的左右两只并联在一路上,
/// 点哪边都是整组一起亮,这跟车上实际的接线是一致的。
///
/// 这张图里的灯本身是亮着拍的,所以【灭着的灯要盖一层暗色】,
/// 不然界面上看起来永远是亮的。
class CarView extends StatefulWidget {
  final AppState state;

  /// 点了某一组灯
  final void Function(int groupId) onTapGroup;

  /// 高亮显示某一组(在组卡片上按住时用)
  final int? highlightGroup;

  /// 光点上标什么数字
  final LampLabel labelMode;

  const CarView({
    super.key,
    required this.state,
    required this.onTapGroup,
    this.highlightGroup,
    this.labelMode = LampLabel.none,
  });

  @override
  State<CarView> createState() => _CarViewState();
}

class _CarViewState extends State<CarView> with TickerProviderStateMixin {
  /// 图片路径 + 真实宽高比。宽高比必须等图片解码出来才知道,
  /// 在这之前先用 16:9 占位,避免布局跳一下。
  String? _asset;
  double _aspect = 16 / 9;
  bool _loading = true;

  /// 爆闪动画。一轮 550ms,和固件 flashPattern 那张表的总时长一致,
  /// 所以手机上看到的闪法跟车上真实的闪法是对得上的。
  late final AnimationController _flash = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 550),
  );

  /// 娱乐模式动画。一圈的时长和固件一样:8 组 × 4 拍 × 60ms。
  late final AnimationController _party = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: kPartyCycleMs),
  );

  /// 照抄固件的节奏表:三连闪 + 间隔
  double _flashLevel(double t) {
    final ms = t * 550;
    if (ms < 50) return 1;
    if (ms < 100) return 0;
    if (ms < 150) return 1;
    if (ms < 200) return 0;
    if (ms < 250) return 1;
    return 0;
  }

  @override
  void initState() {
    super.initState();
    _resolveImage();
  }

  @override
  void dispose() {
    _flash.dispose();
    _party.dispose();
    super.dispose();
  }

  /// 找出该用哪张图,并读出它的真实尺寸
  Future<void> _resolveImage() async {
    String? path;
    try {
      // 先看首选文件在不在
      await rootBundle.load(kCarImagePreferred);
      path = kCarImagePreferred;
    } catch (_) {
      // 不在就扫目录,拿第一张图片文件
      try {
        final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
        final imgs = manifest
            .listAssets()
            .where((k) => k.startsWith(kCarImageDir))
            .where((k) {
              final l = k.toLowerCase();
              return l.endsWith('.png') ||
                  l.endsWith('.jpg') ||
                  l.endsWith('.jpeg') ||
                  l.endsWith('.webp');
            })
            .toList()
          ..sort();
        if (imgs.isNotEmpty) path = imgs.first;
      } catch (_) {}
    }

    if (path == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    // 解码出真实宽高比,热区才不会偏
    final completer = Completer<ui.Image>();
    final stream = AssetImage(path).resolve(const ImageConfiguration());
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!completer.isCompleted) completer.complete(info.image);
        stream.removeListener(listener);
      },
      onError: (e, s) {
        if (!completer.isCompleted) completer.completeError(e);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);

    try {
      final img = await completer.future;
      if (!mounted) return;
      setState(() {
        _asset = path;
        _aspect = img.width / img.height;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 动画只在需要的时候跑,不用的时候停掉,不白耗电
  void _run(AnimationController c, bool on) {
    if (on && !c.isAnimating) {
      c.repeat();
    } else if (!on && c.isAnimating) {
      c.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return AspectRatio(
        aspectRatio: _aspect,
        child: const Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (_asset == null) return _MissingImageHint(s: widget.state.s);

    final st = widget.state;

    // 娱乐模式盖在最上面:开着的时候底下的爆闪不用画
    final partying = st.party;
    final flashing = st.flashMask != 0 && !partying;
    _run(_flash, flashing);
    _run(_party, partying);

    return AspectRatio(
      aspectRatio: _aspect,
      // A 柱上直射和侧位两组挨得太近,在手机上只隔几 dp。
      // 套一层缩放:两指放大之后就能精确点到想要的那一组。
      // scale=1 时 InteractiveViewer 不吃拖动手势,页面照样能正常上下滚。
      child: InteractiveViewer(
        maxScale: 4,
        child: LayoutBuilder(
          builder: (context, c) {
            final w = c.maxWidth;
            final h = c.maxHeight;

            return AnimatedBuilder(
              animation: Listenable.merge([_flash, _party]),
              builder: (context, _) {
                // 爆闪只作用在白光那一路 —— 和固件一样,日行灯和氛围灯就算
                // 同时开着也是常亮不闪。
                final flashLevel = flashing ? _flashLevel(_flash.value) : 1.0;

                // 娱乐模式这一拍亮的是哪一组(灭的那一拍是 null)。
                // 只在接了的组之间轮,和固件一致
                final partyGroup = partying
                    ? partyGroupAt(
                        (_party.value * kPartyCycleMs).floor(), st.partyOrder)
                    : null;

                LampLit litOf(int g) {
                  // 这组的板子没接:车上根本没这盏灯,一直画成灭的
                  if (!st.isGroupPresent(g)) return LampLit.dark;
                  if (partying) {
                    return g == partyGroup
                        ? const LampLit(spot: 1, drl: 0, ambient: 0)
                        : LampLit.dark;
                  }
                  final spotLevel = st.isGroupFlashing(g) ? flashLevel : 1.0;
                  return LampLit(
                    spot: st.isGroupFnOn(g, LampFn.spot)
                        ? st.fnIntensity(g, LampFn.spot) * spotLevel
                        : 0,
                    drl: st.isGroupFnOn(g, LampFn.drl)
                        ? st.fnIntensity(g, LampFn.drl)
                        : 0,
                    ambient: st.isGroupFnOn(g, LampFn.ambient)
                        ? st.fnIntensity(g, LampFn.ambient)
                        : 0,
                  );
                }

                return Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.asset(_asset!, fit: BoxFit.contain),

                    // 光点:只负责画,不接收点击
                    for (final l in kLamps)
                      _LampDot(
                        lamp: l,
                        boxW: w,
                        boxH: h,
                        lit: litOf(l.group),
                        // 这一组还有没有通道开着(决定灭着时的描边深浅)
                        on: st.isGroupPresent(l.group) &&
                            (partying || st.isGroupLit(l.group)),
                        // 爆闪和娱乐模式要硬切,不能走渐变动画
                        instant: partying || st.isGroupFlashing(l.group),
                        highlighted: widget.highlightGroup == l.group,
                        label: switch (widget.labelMode) {
                          LampLabel.none => null,
                          // 组号从 1 开始，正好是车图上标的那个编号
                          LampLabel.group => '${l.group + 1}',
                        },
                      ),

                    // 点击热区:铺在光点之上,用的是比灯大一圈的矩形。
                    // 和光点分开画是有原因的 —— 热区中心不等于灯的中心
                    // (A 柱上两只挨着的灯,热区在中线切开),两者重合反而点不准。
                    // 没接的板子上的灯不给热区,点了也没用
                    for (final l in kLamps)
                      if (st.isGroupPresent(l.group))
                        Positioned(
                          left: l.hx0 * w,
                          top: l.hy0 * h,
                          width: l.hitW * w,
                          height: l.hitH * h,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => widget.onTapGroup(l.group),
                            child: kShowHitAreas
                                ? Container(
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: const Color(0xFF00E5FF),
                                        width: 1,
                                      ),
                                    ),
                                  )
                                : null,
                          ),
                        ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}

/// 单个灯的发光点。纯视觉,点击由上面那层热区负责。
///
/// 三路是叠着画的:实心灯芯(白光/日行灯)打底,黄环(氛围灯)盖在上面。
/// 所以"白光 + 氛围灯同时开"看起来就是一个亮白灯芯外面套一圈黄环,
/// 和车上真实的样子一致。
class _LampDot extends StatelessWidget {
  final Lamp lamp;
  final double boxW;
  final double boxH;
  final LampLit lit;
  final bool on; // 这一组还有通道开着(灭着时描边亮一点)
  final bool instant; // true = 不走渐变(爆闪 / 娱乐模式)
  final bool highlighted;
  final String? label;

  const _LampDot({
    required this.lamp,
    required this.boxW,
    required this.boxH,
    required this.lit,
    required this.on,
    required this.instant,
    required this.highlighted,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    // size 就是灯的宽度(相对图片宽度)。灯条按 kBarHeightRatio 压扁,
    // 圆灯宽高一致。这样坐标表里的 size 和图上量到的尺寸是同一个意思。
    final d = lamp.size * boxW;
    final isBar = lamp.shape == LampShape.bar;
    final w = d;
    final h = isBar ? d * kBarHeightRatio : d;

    return Positioned(
      left: lamp.x * boxW - w / 2,
      top: lamp.y * boxH - h / 2,
      width: w,
      height: h,
      child: IgnorePointer(
        child: Center(
          child: AnimatedContainer(
            duration: Duration(milliseconds: instant ? 0 : 220),
            width: w,
            height: h,
            decoration: _outerDeco(d, isBar, h),
            alignment: Alignment.center,
            child: lit.hasRing ? _ring(d, isBar, w, h) : _labelText(),
          ),
        ),
      ),
    );
  }

  /// 灯芯 = 白光/日行灯那两路。氛围灯不填灯芯,保持暗底,
  /// 黄环才显得是"围着灯的一圈"。
  ///
  /// 暗底要够不透明:这张车图里的灯本来就是亮着拍的,
  /// 盖浅了原图的亮光会透出来,灯关着看起来也像开着。
  BoxDecoration _outerDeco(double d, bool isBar, double h) {
    final v = lit.solid; // 白光这一路的亮度 0~1

    return BoxDecoration(
      shape: isBar ? BoxShape.rectangle : BoxShape.circle,
      borderRadius: isBar ? BorderRadius.circular(h / 2) : null,
      // 亮度低时压暗,但不压到看不见
      color: lit.anySolid
          ? AppColors.lightWhite.withValues(alpha: 0.30 + 0.65 * v)
          : const Color(0xFF0B0D11).withValues(alpha: 0.9),
      border: Border.all(
        color: lit.anySolid
            ? AppColors.lightWhite
            : (highlighted
                ? AppColors.accent
                : Colors.white.withValues(alpha: on ? 0.55 : 0.22)),
        width: highlighted ? 2.0 : 1.2,
      ),
      // 光晕整体跟着亮度缩放:调暗时不只是变淡,散开的范围也收小。
      // 氛围灯的光晕由里面那圈环自己带,这里不重复画。
      boxShadow: lit.anySolid
          ? [
              BoxShadow(
                color: AppColors.lightWhite.withValues(alpha: 0.78 * v),
                blurRadius: d * (0.45 + 0.65 * v),
                spreadRadius: d * 0.30 * v,
              ),
              BoxShadow(
                color: AppColors.lightWhite.withValues(alpha: 0.38 * v),
                blurRadius: d * (0.9 + 1.7 * v),
                spreadRadius: d * 0.78 * v,
              ),
            ]
          : (highlighted && !lit.any
              ? [
                  BoxShadow(
                    color: AppColors.accent.withValues(alpha: 0.5),
                    blurRadius: 12,
                    spreadRadius: 2,
                  )
                ]
              : null),
    );
  }

  /// 氛围灯:在灯的区域里面画一圈黄环,中间空着。
  ///
  /// 车上那圈氛围灯就是围着射灯一圈的灯带,画成实心就跟白光分不出来了。
  Widget _ring(double d, bool isBar, double w, double h) {
    final v = lit.ambient;
    final rw = w * 0.74;
    final rh = isBar ? h * 0.62 : h * 0.74;
    final stroke = (d * 0.10).clamp(1.6, 4.0);

    return Container(
      width: rw,
      height: rh,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: isBar ? BoxShape.rectangle : BoxShape.circle,
        borderRadius: isBar ? BorderRadius.circular(rh / 2) : null,
        border: Border.all(
          color: AppColors.lightYellow
              .withValues(alpha: (0.45 + 0.55 * v).clamp(0.0, 1.0)),
          width: stroke,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.lightYellow.withValues(alpha: 0.55 * v),
            blurRadius: d * (0.30 + 0.45 * v),
            spreadRadius: d * 0.10 * v,
          ),
        ],
      ),
      child: _labelText(),
    );
  }

  Widget? _labelText() => label == null
      ? null
      : Text(
          label!,
          style: TextStyle(
            fontSize: (lamp.size * boxW * 0.5).clamp(8.0, 13.0),
            height: 1,
            fontWeight: FontWeight.w700,
            // 灯芯亮起来时很白,黑字才看得清;
            // 只有黄环或者全灭时中间是暗的,用白字。
            color: lit.anySolid ? Colors.black87 : Colors.white70,
          ),
        );
}

/// 图片还没放进去时的提示。不画假车,直接告诉你该干什么。
class _MissingImageHint extends StatelessWidget {
  final S s;
  const _MissingImageHint({required this.s});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        padding: const EdgeInsets.all(20),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.image_outlined,
                  size: 40, color: AppColors.textLo),
              const SizedBox(height: 12),
              Text(
                s.noCarImage,
                style: const TextStyle(
                  color: AppColors.textHi,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                s.noCarImageHint,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.textLo,
                  fontSize: 12.5,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
