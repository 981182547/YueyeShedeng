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

/// 灯这会儿该画成什么样。
///
/// 三种画法对应车上三串不同的灯珠,看起来必须是三个样子,
/// 不然手机上分不出现在开的到底是哪一路。
enum LampStyle {
  /// 不亮
  dark,

  /// 射灯白光 / 爆闪:实心白、强光晕、向前射出光束
  spot,

  /// 日行灯:也是白的,但整体暗一截,不射光束
  drl,

  /// 氛围灯:灯的区域【里面画一圈黄环】,中间不填,弱亮,不射光束
  ring,
}

LampStyle styleOf(int mode) => switch (mode) {
      LightMode.white => LampStyle.spot,
      LightMode.flash => LampStyle.spot,
      LightMode.drl => LampStyle.drl,
      LightMode.ambient => LampStyle.ring,
      _ => LampStyle.dark,
    };

/// 光点上标什么数字
enum LampLabel {
  none,

  /// 标所属【组】的编号 1~4,和车图上标注的编号一致
  group,
}

/// 车辆实拍图 + 灯组热区。
///
/// 图片按原始比例铺满,灯用【相对坐标】叠在上面,所以任何屏幕尺寸下
/// 光点都长在车上正确的位置。坐标表在 models/lamp.dart。
///
/// 注意车图上画着 8 个灯,但只有 4 组 —— 同一排的左右两只并联在一路上,
/// 点哪边都是整排一起亮,这跟车上实际的接线是一致的。
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

class _CarViewState extends State<CarView> with SingleTickerProviderStateMixin {
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
    final style = styleOf(st.mode);
    // 氛围灯是黄的,射灯和日行灯都是白的
    final glow = style == LampStyle.ring
        ? AppColors.lightYellow
        : AppColors.lightWhite;

    // 爆闪模式下才跑动画,其它模式停掉,不白耗电
    final flashing = st.mode == LightMode.flash;
    if (flashing && !_flash.isAnimating) {
      _flash.repeat();
    } else if (!flashing && _flash.isAnimating) {
      _flash.stop();
    }

    // 只有射灯那一路才往前射光束 —— 日行灯和氛围灯是示廓用的,
    // 本来就不该有一道打出去的光柱。
    final castsBeam = style == LampStyle.spot;

    return AspectRatio(
      aspectRatio: _aspect,
      // 立柱上下那两组灯挨得太近,在手机上只隔十几 dp。
      // 套一层缩放:两指放大之后就能精确点到想要的那一组。
      // scale=1 时 InteractiveViewer 不吃拖动手势,页面照样能正常上下滚。
      child: InteractiveViewer(
        maxScale: 4,
        child: LayoutBuilder(
          builder: (context, c) {
          final w = c.maxWidth;
          final h = c.maxHeight;

          // 点亮的灯坐标,交给光束层去画
          final beams = <Offset>[];
          final beamSizes = <double>[];
          if (castsBeam) {
            for (final l in kLamps) {
              if (st.isGroupLit(l.group)) {
                beams.add(Offset(l.x * w, l.y * h));
                beamSizes.add(l.size * w);
              }
            }
          }

          return AnimatedBuilder(
            animation: _flash,
            builder: (context, _) {
              // 非爆闪时恒为 1(常亮);爆闪时按节奏表在 1 和 0 之间跳
              final level = flashing ? _flashLevel(_flash.value) : 1.0;
              // 当前亮度(0~1):已经把日行灯/氛围灯的显示折扣算进去了
              final intensity = st.lightIntensity;

              return Stack(
                fit: StackFit.expand,
                children: [
                  Image.asset(_asset!, fit: BoxFit.contain),

                  // 光束层:车头朝左,所以光往左前方射
                  if (beams.isNotEmpty && level > 0 && intensity > 0)
                    IgnorePointer(
                      child: CustomPaint(
                        painter: _BeamPainter(
                          origins: beams,
                          sizes: beamSizes,
                          color: glow,
                          flashing: flashing,
                          intensity: intensity,
                        ),
                      ),
                    ),

                  // 光点:只负责画,不接收点击
                  for (final l in kLamps)
                    _LampDot(
                      lamp: l,
                      boxW: w,
                      boxH: h,
                      // 爆闪灭的那一拍,灯也跟着暗下去
                      style: (st.isGroupLit(l.group) && level > 0)
                          ? style
                          : LampStyle.dark,
                      // 这一组还有没有通道是开着的(决定灭着时的描边深浅)
                      on: LampFn.all
                          .any((fn) => st.isChOn(chOf(l.group, fn))),
                      glow: glow,
                      intensity: intensity,
                      instant: flashing, // 爆闪要硬切,不能走渐变动画
                      highlighted: widget.highlightGroup == l.group,
                      label: switch (widget.labelMode) {
                        LampLabel.none => null,
                        // 组号从 1 开始，正好是车图上标的那个编号
                        LampLabel.group => '${l.group + 1}',
                      },
                    ),

                  // 点击热区:铺在光点之上,用的是比灯大一圈的矩形。
                  // 和光点分开画是有原因的 —— 热区中心不等于灯的中心
                  // (立柱上灯的热区往上扩,下灯往下扩),两者重合反而点不准。
                  for (final l in kLamps)
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
class _LampDot extends StatelessWidget {
  final Lamp lamp;
  final double boxW;
  final double boxH;
  final LampStyle style; // 这会儿画成什么样
  final bool on; // 这一组还有通道开着(灭着时描边亮一点)
  final Color glow;
  final double intensity; // 当前亮度 0~1，决定光点多亮、光晕多大
  final bool instant; // true = 不走渐变(爆闪)
  final bool highlighted;
  final String? label;

  const _LampDot({
    required this.lamp,
    required this.boxW,
    required this.boxH,
    required this.style,
    required this.on,
    required this.glow,
    required this.intensity,
    required this.instant,
    required this.highlighted,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    // size 就是灯的宽度(相对图片宽度)。横条灯压扁到 0.42 倍高，
    // 圆灯宽高一致。这样坐标表里的 size 和图上量到的尺寸是同一个意思。
    final d = lamp.size * boxW;
    final isBar = lamp.shape == LampShape.bar;
    final w = d;
    final h = isBar ? d * 0.42 : d;

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
            child: style == LampStyle.ring
                ? _ring(d, isBar, w, h)
                : _labelText(d),
          ),
        ),
      ),
    );
  }

  bool get _lit => style != LampStyle.dark;

  /// 灯体本身。氛围灯模式下灯体不发光 —— 亮的是里面那圈环。
  BoxDecoration _outerDeco(double d, bool isBar, double h) {
    final solid = style == LampStyle.spot || style == LampStyle.drl;

    return BoxDecoration(
      shape: isBar ? BoxShape.rectangle : BoxShape.circle,
      borderRadius: isBar ? BorderRadius.circular(h / 2) : null,
      // 灯芯:亮度低时压暗,但不压到看不见。
      // 氛围灯不填灯芯,保持暗底,黄环才显得是"外面一圈"。
      color: solid
          ? glow.withValues(alpha: 0.30 + 0.65 * intensity)
          : Colors.black.withValues(alpha: 0.35),
      border: Border.all(
        color: solid
            ? glow
            : (highlighted
                ? AppColors.accent
                : Colors.white.withValues(alpha: on ? 0.55 : 0.22)),
        width: highlighted ? 2.0 : 1.4,
      ),
      // 光晕整体跟着亮度缩放:调暗时不只是变淡,散开的范围也收小。
      // 氛围灯的光晕由里面那圈环自己带,这里不重复画。
      boxShadow: solid
          ? [
              BoxShadow(
                color: glow.withValues(alpha: 0.78 * intensity),
                blurRadius: d * (0.45 + 0.65 * intensity),
                spreadRadius: d * 0.30 * intensity,
              ),
              BoxShadow(
                color: glow.withValues(alpha: 0.38 * intensity),
                blurRadius: d * (0.9 + 1.7 * intensity),
                spreadRadius: d * 0.78 * intensity,
              ),
            ]
          : (highlighted && !_lit
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
  /// 车上那圈氛围灯就是围着射灯一圈的灯带,画成实心就跟射灯白光分不出来了。
  Widget _ring(double d, bool isBar, double w, double h) {
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
          color: glow.withValues(alpha: (0.45 + 0.55 * intensity).clamp(0.0, 1.0)),
          width: stroke,
        ),
        boxShadow: [
          BoxShadow(
            color: glow.withValues(alpha: 0.55 * intensity),
            blurRadius: d * (0.30 + 0.45 * intensity),
            spreadRadius: d * 0.10 * intensity,
          ),
        ],
      ),
      child: _labelText(d),
    );
  }

  Widget? _labelText(double d) => label == null
      ? null
      : Text(
          label!,
          style: TextStyle(
            fontSize: (d * 0.5).clamp(9.0, 14.0),
            fontWeight: FontWeight.w700,
            // 实心发光时灯芯很亮,黑字才看得清;
            // 氛围灯和灭灯时中间是暗的,用白字。
            color: (style == LampStyle.spot || style == LampStyle.drl)
                ? Colors.black87
                : Colors.white70,
          ),
        );
}

/// 光束:从每组点亮的射灯向左前方射出一道渐隐的光
class _BeamPainter extends CustomPainter {
  final List<Offset> origins;
  final List<double> sizes;
  final Color color;
  final bool flashing;
  final double intensity;

  _BeamPainter({
    required this.origins,
    required this.sizes,
    required this.color,
    required this.flashing,
    required this.intensity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < origins.length; i++) {
      final o = origins[i];
      final r = sizes[i];
      // 光束长度也跟着亮度走:调暗了射得就没那么远
      final len = size.width * (0.18 + 0.37 * intensity);
      final spread = r * 2.6; // 远端张开的半高

      // 车头朝左,光往左射;略微向下,和图里那道光轨的方向一致
      final endX = o.dx - len;
      final endY = o.dy + len * 0.06;

      final path = Path()
        ..moveTo(o.dx, o.dy - r * 0.42)
        ..lineTo(endX, endY - spread)
        ..lineTo(endX, endY + spread)
        ..lineTo(o.dx, o.dy + r * 0.42)
        ..close();

      final paint = Paint()
        ..blendMode = BlendMode.plus // 叠加发光,多道光束交叠处更亮
        ..shader = ui.Gradient.linear(
          Offset(o.dx, o.dy),
          Offset(endX, endY),
          [
            color.withValues(alpha: (flashing ? 0.42 : 0.30) * intensity),
            color.withValues(alpha: 0.10 * intensity),
            color.withValues(alpha: 0.0),
          ],
          const [0.0, 0.45, 1.0],
        )
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.9);

      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_BeamPainter old) =>
      old.origins.length != origins.length ||
      old.color != color ||
      old.flashing != flashing ||
      old.intensity != intensity;
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
