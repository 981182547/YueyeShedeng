import 'package:flutter/material.dart';


import '../ble/protocol.dart';
import '../i18n/strings.dart';
import '../models/lamp.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/car_view.dart';
import '../widgets/device_picker.dart';
import 'lamps_screen.dart';

/// 主页:车图分组控制 + 底部模式条
class HomeScreen extends StatelessWidget {
  final AppState state;
  const HomeScreen({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        // s 必须在 builder 【里面】取:切换语言只会重建这个 builder,
        // HomeScreen.build 本身不会再跑,放外面就会一直用旧语言的文案。
        final s = state.s;
        return Scaffold(
          appBar: AppBar(
            title: Text(s.appTitle),
            actions: [
              _LangChip(state: state),
              const SizedBox(width: 6),
              _ConnChip(state: state),
              IconButton(
                // 看【实际亮没亮】,不看模式 —— 分路控制页可以在关灯模式下
                // 手动点亮某一路,那时候这个按钮得是亮的
                tooltip: state.allDark ? s.turnOn : s.turnOff,
                icon: Icon(
                  Icons.power_settings_new,
                  color: state.allDark ? AppColors.textLo : AppColors.accent,
                ),
                onPressed: state.togglePower,
              ),
              IconButton(
                tooltip: s.devices,
                icon: Icon(
                  state.isConnected
                      ? Icons.bluetooth_connected
                      : Icons.bluetooth_searching,
                  color:
                      state.isConnected ? AppColors.online : AppColors.textLo,
                ),
                onPressed: () {
                  final ble = state.ble;
                  if (ble != null) showDevicePicker(context, ble);
                },
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 固件和 App 不是同一版的时候,下面显示的一切都不可信,
                  // 所以这条横幅顶在最上面,别让人对着错的状态排查半天
                  if (state.versionMismatch) ...[
                    _FwMismatchBanner(state: state),
                    const SizedBox(height: 8),
                  ],
                  _StatusBar(state: state),
                  const SizedBox(height: 8),

                  // 车图:点哪个灯位,就开关它所在的那一组
                  CarView(
                    state: state,
                    labelMode: LampLabel.group,
                    onTapGroup: (g) => state.toggleGroup(groupById(g)),
                  ),

                  const SizedBox(height: 12),
                  _GroupRow(state: state),
                  const SizedBox(height: 14),
                  _BrightnessBar(state: state),
                  const SizedBox(height: 10),

                  OutlinedButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => LampsScreen(state: state),
                      ),
                    ),
                    icon: const Icon(Icons.tune, size: 18),
                    label: Text(s.channelDetail),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.textHi,
                      side: const BorderSide(color: AppColors.border),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ],
              ),
            ),
          ),
          bottomNavigationBar: _BottomBar(state: state),
        );
      },
    );
  }
}

/// 中英切换。
///
/// 样式刻意照着旁边的连接状态胶囊做:同样的圆角、同样的字号、同样的内边距,
/// 看起来是一套的。只是配色用中性灰 —— 连接状态才是需要一眼看到的信息,
/// 语言按钮不该抢它的注意力。
///
/// 显示的是【当前】语言:中文界面显示「中」,英文界面显示「EN」,点一下就换。
class _LangChip extends StatelessWidget {
  final AppState state;
  const _LangChip({required this.state});

  @override
  Widget build(BuildContext context) {
    final zh = state.lang == AppLang.zh;
    return GestureDetector(
      onTap: state.toggleLang,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: AppColors.textLo.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.language, size: 13, color: AppColors.textLo),
            const SizedBox(width: 5),
            Text(
              zh ? '中' : 'EN',
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textHi,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// AppBar 上的连接状态小圆点。
///
/// state 必须当参数传进来,不能用 InheritedWidget 去取:
/// AppState 是个 ChangeNotifier,对象引用从头到尾不变,
/// InheritedWidget 的 updateShouldNotify 比的是引用,永远是 false,
/// 于是连上了这里还一直显示"未连接"。
class _ConnChip extends StatelessWidget {
  final AppState state;
  const _ConnChip({required this.state});

  @override
  Widget build(BuildContext context) {
    final s = state.s;
    final (color, text) = switch (state.conn) {
      ConnState.connected => (AppColors.online, s.connected),
      ConnState.connecting => (Colors.amber, s.connecting),
      ConnState.disconnected => (AppColors.offline, s.disconnected),
    };

    return GestureDetector(
      onTap: () {
        final ble = state.ble;
        if (ble == null) return;
        if (state.conn == ConnState.disconnected) {
          showDevicePicker(context, ble);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(text, style: TextStyle(fontSize: 12, color: color)),
          ],
        ),
      ),
    );
  }
}

/// 固件版本对不上时顶在最上面的横幅。
///
/// 这种错配最难查:App 能连上、状态也在刷,就是行为不对 ——
/// 因为同样长度的几个字节在两版固件里含义不一样。直接说清楚要重烧固件。
class _FwMismatchBanner extends StatelessWidget {
  final AppState state;
  const _FwMismatchBanner({required this.state});

  @override
  Widget build(BuildContext context) {
    final s = state.s;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.55)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded,
              size: 18, color: AppColors.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.fwMismatch,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textHi,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  s.fwMismatchDetail(
                      state.deviceVersion ?? 0, Protocol.fwVersion),
                  style: const TextStyle(
                    fontSize: 11.5,
                    height: 1.45,
                    color: AppColors.textLo,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 当前模式 / 颜色 / 传感器状态。
/// 这一行的内容全部来自设备上报,所以它显示的就是车上真实的样子。
class _StatusBar extends StatelessWidget {
  final AppState state;
  const _StatusBar({required this.state});

  @override
  Widget build(BuildContext context) {
    final s = state.s;
    // 状态点的颜色看【实际亮着的是哪一路】,不看模式 ——
    // 在白光模式下手动只留一路氛围灯,这个点也该是黄的。
    final lightColor = state.litColor;
    final off = state.allDark;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: off ? AppColors.offline : lightColor,
              boxShadow: off
                  ? null
                  : [
                      BoxShadow(
                        color: lightColor.withValues(alpha: 0.7),
                        blurRadius: 8,
                        spreadRadius: 1,
                      )
                    ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            modeName(s, state.mode),
            style: const TextStyle(
              color: AppColors.textHi,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          // 12 路被手动改过,和模式的默认不一样了。
          // 不标一下的话,"选着白光却亮着黄的"会让人以为是 bug。
          if (state.customized) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: AppColors.textLo.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                s.customized,
                style: const TextStyle(fontSize: 10, color: AppColors.textLo),
              ),
            ),
          ],
          const Spacer(),
          Text(
            s.groupCount(state.onGroupCount, kGroupCount),
            style: const TextStyle(color: AppColors.textLo, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}

/// 四组灯的开关卡片,和车图上的点击是同一套动作
class _GroupRow extends StatelessWidget {
  final AppState state;
  const _GroupRow({required this.state});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final g in kGroups) ...[
          Expanded(child: _GroupCard(state: state, group: g)),
          if (g != kGroups.last) const SizedBox(width: 8),
        ]
      ],
    );
  }
}

class _GroupCard extends StatelessWidget {
  final AppState state;
  final LampGroup group;
  const _GroupCard({required this.state, required this.group});

  @override
  Widget build(BuildContext context) {
    final s = state.s;
    // 亮不亮只看"有没有任意一路开着"。
    //
    // 不用"三路全开才算开"那套了:新模型下白光模式每组只点射灯一路,
    // 按全开判定的话四张卡片会永远显示「半开」—— 一路开在这里是常态,
    // 不是中间状态,拆到哪一路是分路控制页的事。
    final active = state.isGroupLit(group.id);
    // 卡片染成这组【实际亮着的那一路】的颜色
    final lightColor = state.groupLitColor(group.id);

    return GestureDetector(
      onTap: () => state.toggleGroup(group),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: active
              ? lightColor.withValues(alpha: 0.10)
              : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active
                ? lightColor.withValues(alpha: 0.55)
                : AppColors.border,
          ),
        ),
        child: Column(
          children: [
            Icon(
              active ? Icons.lightbulb : Icons.lightbulb_outline,
              size: 20,
              color: active ? lightColor : AppColors.textLo,
            ),
            const SizedBox(height: 6),
            Text(
              groupName(s, group.id),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: active ? AppColors.textHi : AppColors.textLo,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              active ? s.on : s.off,
              style: TextStyle(
                fontSize: 10.5,
                color: active ? lightColor : AppColors.offline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 亮度条:整条都能点、能拖。
///
/// 没有用 Material 的 Slider —— 那个的触摸目标只有中间那个小圆点,
/// 在车上单手操作基本抓不住。这里做成填充条,条上任意位置按下即生效,
/// 手指横着划就能连续调,触摸高度 52dp。
class _BrightnessBar extends StatelessWidget {
  final AppState state;
  const _BrightnessBar({required this.state});

  @override
  Widget build(BuildContext context) {
    final s = state.s;
    // 滑条只管射灯那一路。日行灯和氛围灯固件里就是给满的,没什么可调的,
    // 所以一路射灯都没亮的时候把滑条置灰。
    final adjustable = state.brightnessAdjustable;
    final shown = state.brightness;
    const lightColor = AppColors.lightWhite; // 调的是射灯,射灯是白的
    final off = !adjustable;

    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;

        void applyAt(double dx, {bool commit = false}) {
          state.setBrightness(((dx / w) * 100).round(), commit: commit);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // 点一下直接跳到该位置,不用非得从滑块开始拖
          onTapDown:
              adjustable ? (d) => applyAt(d.localPosition.dx, commit: true) : null,
          onHorizontalDragUpdate:
              adjustable ? (d) => applyAt(d.localPosition.dx) : null,
          onHorizontalDragEnd:
              adjustable ? (_) => state.commitBrightness() : null,
          child: Opacity(
            opacity: adjustable ? 1 : 0.5,
            child: Container(
              height: 52,
              decoration: BoxDecoration(
                color: AppColors.surfaceHi,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.border),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                children: [
                  // 填充部分:用当前灯色,一眼看出调到哪儿了
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: (shown / 100).clamp(0.0, 1.0),
                      heightFactor: 1,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              lightColor.withValues(alpha: off ? 0.10 : 0.16),
                              lightColor.withValues(alpha: off ? 0.16 : 0.34),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 15),
                    child: Row(
                      children: [
                        Icon(Icons.brightness_6,
                            size: 19,
                            color: off ? AppColors.textLo : lightColor),
                        const SizedBox(width: 10),
                        Text(
                          s.brightness,
                          style: TextStyle(
                            fontSize: 13.5,
                            color: AppColors.textHi.withValues(alpha: 0.9),
                          ),
                        ),
                        const Spacer(),
                        // 锁:提示这个模式的亮度是固件定的,不是没反应
                        if (!adjustable) ...[
                          const Icon(Icons.lock_outline,
                              size: 13, color: AppColors.textLo),
                          const SizedBox(width: 5),
                        ],
                        Text(
                          '$shown%',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: off ? AppColors.textLo : AppColors.textHi,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 底部模式条:白光 / 日行灯 / 氛围灯 / 爆闪,四选一。
///
/// 没有独立的"颜色"选择了 —— 选哪个模式就亮哪一路灯:
/// 白光和爆闪走射灯那一路,氛围灯走外圈黄光那一路,互斥。
/// 关灯在顶栏那个电源按钮上。
class _BottomBar extends StatelessWidget {
  final AppState state;
  const _BottomBar({required this.state});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  for (final m in kModes)
                    Expanded(
                      child: _ModeButton(
                        info: m,
                        s: state.s,
                        selected: state.mode == m.id,
                        onTap: () => state.setMode(m.id),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  final ModeInfo info;
  final bool selected;
  final VoidCallback onTap;

  /// 这个按钮不持有 state,文案表直接传进来
  final S s;

  const _ModeButton({
    required this.info,
    required this.s,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin: const EdgeInsets.symmetric(horizontal: 3),
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? info.color.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? info.color.withValues(alpha: 0.7)
                : Colors.transparent,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              info.icon,
              size: 21,
              color: selected ? info.color : AppColors.textLo,
            ),
            const SizedBox(height: 4),
            Text(
              modeName(s, info.id),
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? info.color : AppColors.textLo,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

