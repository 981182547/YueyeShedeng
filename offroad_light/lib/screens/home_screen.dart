import 'package:flutter/material.dart';


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
        return Scaffold(
          appBar: AppBar(
            title: const Text('SPOTLIGHT'),
            actions: [
              _ConnChip(state: state),
              IconButton(
                tooltip: state.mode == LightMode.off ? '开灯' : '关灯',
                icon: Icon(
                  Icons.power_settings_new,
                  color: state.mode == LightMode.off
                      ? AppColors.textLo
                      : AppColors.accent,
                ),
                onPressed: state.togglePower,
              ),
              IconButton(
                tooltip: '蓝牙设备',
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
                  _StatusBar(state: state),
                  const SizedBox(height: 8),

                  // 车图:点哪个灯位,就开关它所在的那一组
                  CarView(
                    state: state,
                    onTapLamp: (lamp) => state.toggleGroup(groupOf(lamp.id)),
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
                    label: const Text('单灯控制'),
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
    final (color, text) = switch (state.conn) {
      ConnState.connected => (AppColors.online, '已连接'),
      ConnState.connecting => (Colors.amber, '连接中'),
      ConnState.disconnected => (AppColors.offline, '未连接'),
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

/// 当前模式 / 颜色 / 传感器状态。
/// 这一行的内容全部来自设备上报,所以它显示的就是车上真实的样子。
class _StatusBar extends StatelessWidget {
  final AppState state;
  const _StatusBar({required this.state});

  @override
  Widget build(BuildContext context) {
    final lightColor =
        state.isYellow ? AppColors.lightYellow : AppColors.lightWhite;
    final off = state.mode == LightMode.off;

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
            modeName(state.mode),
            style: const TextStyle(
              color: AppColors.textHi,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            off ? '' : (state.isYellow ? '黄光' : '白光'),
            style: const TextStyle(color: AppColors.textLo, fontSize: 12.5),
          ),
          const Spacer(),
          Text(
            '${state.onCount}/8 灯位',
            style: const TextStyle(color: AppColors.textLo, fontSize: 12.5),
          ),
          // 传感器状态:自动模式下这两个决定了灯的亮度和颜色
          if (state.night) ...[
            const SizedBox(width: 8),
            const Icon(Icons.nightlight_round,
                size: 15, color: AppColors.textLo),
          ],
          if (state.rain) ...[
            const SizedBox(width: 6),
            const Icon(Icons.water_drop, size: 15, color: Color(0xFF60A5FA)),
          ],
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
    final on = state.isGroupOn(group);
    final partial = state.isGroupPartial(group);
    final lightColor =
        state.isYellow ? AppColors.lightYellow : AppColors.lightWhite;
    final active = (on || partial) && state.mode != LightMode.off;

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
              on ? Icons.lightbulb : Icons.lightbulb_outline,
              size: 20,
              color: active ? lightColor : AppColors.textLo,
            ),
            const SizedBox(height: 6),
            Text(
              group.name,
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
              partial ? '半开' : (on ? '开' : '关'),
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
    // 只有常亮模式的亮度是用户说了算。
    // 日行是固定低亮度、自动看光敏、爆闪走节奏表,这三个手动调没有意义。
    final adjustable = state.mode == LightMode.steady;
    // 不可调的时候显示固件真正在用的那个亮度,而不是滑条记着的值,
    // 否则日行模式下会显示上次拖到的 100%,和车上看到的对不上。
    final shown = adjustable ? state.brightness : state.effectiveDuty;
    final lightColor =
        state.isYellow ? AppColors.lightYellow : AppColors.lightWhite;
    final off = state.mode == LightMode.off;

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
                          '亮度',
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

/// 底部两层:上面挑【颜色】,下面挑【模式】。
///
/// 分成两层是刻意的 —— 这两件事本来就互不相干:
/// 颜色决定灯发什么色,模式决定灯怎么个亮法,日行/自动/爆闪用的都是上面选中的颜色。
/// 以前把白光/黄光和日行/自动/爆闪并排塞进一排单选,选了黄光再点日行,
/// 颜色就被顶掉了。
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
              padding: const EdgeInsets.fromLTRB(11, 10, 11, 8),
              child: _ColorBar(state: state),
            ),
            const Divider(height: 1, color: AppColors.border),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  for (final m in kModes)
                    Expanded(
                      child: _ModeButton(
                        info: m,
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

/// 颜色:白光 / 黄光。切它不会打断当前模式。
class _ColorBar extends StatelessWidget {
  final AppState state;
  const _ColorBar({required this.state});

  @override
  Widget build(BuildContext context) {
    final off = state.mode == LightMode.off;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Opacity(
          opacity: off ? 0.45 : 1,
          child: Row(
            children: [
              Expanded(
                child: _ColorButton(
                  label: '白光',
                  icon: Icons.light_mode,
                  color: AppColors.lightWhite,
                  selected: !state.pickedYellow,
                  onTap: () => state.setColor(LightColorId.white),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _ColorButton(
                  label: '黄光',
                  icon: Icons.wb_incandescent,
                  color: AppColors.lightYellow,
                  selected: state.pickedYellow,
                  onTap: () => state.setColor(LightColorId.yellow),
                ),
              ),
            ],
          ),
        ),
        // 自动模式遇上下雨,设备会临时把颜色抢成黄光。
        // 不解释一句的话,用户会以为这个开关坏了。
        if (state.colorOverridden)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.water_drop, size: 13, color: Color(0xFF60A5FA)),
                const SizedBox(width: 5),
                Text(
                  '检测到下雨,已临时转黄光',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: AppColors.textLo.withValues(alpha: 0.95),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ColorButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _ColorButton({
    required this.label,
    required this.icon,
    required this.color,
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
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: selected ? color.withValues(alpha: 0.75) : AppColors.border,
            width: selected ? 1.4 : 1,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: 0.22),
                    blurRadius: 14,
                    spreadRadius: -2,
                  )
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: selected ? color : AppColors.textLo),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                color: selected ? color : AppColors.textLo,
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

  const _ModeButton({
    required this.info,
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
              info.name,
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

