import 'package:flutter/material.dart';


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
                tooltip: state.mode == LightMode.off ? s.turnOn : s.turnOff,
                icon: Icon(
                  Icons.power_settings_new,
                  color: state.mode == LightMode.off
                      ? AppColors.textLo
                      : AppColors.accent,
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

/// 当前模式 / 颜色 / 传感器状态。
/// 这一行的内容全部来自设备上报,所以它显示的就是车上真实的样子。
class _StatusBar extends StatelessWidget {
  final AppState state;
  const _StatusBar({required this.state});

  @override
  Widget build(BuildContext context) {
    final s = state.s;
    final lightColor = lightColorOf(state.mode);
    final off = state.isOff;

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
          const Spacer(),
          // 爆闪时固件无视通道掩码,四组一起闪 —— 这时显示「x/4 组」会对不上,
          // 所以直接说明白在全闪,免得用户对着关掉的那组发懵。
          Text(
            state.mode == LightMode.flash
                ? s.allGroupsFlash
                : s.groupCount(state.onGroupCount, kGroupCount),
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
    final on = state.isGroupOn(group);
    final partial = state.isGroupPartial(group);
    final lightColor = lightColorOf(state.mode);
    // 高亮与否跟着车图走:看的是【当前模式那一路】亮没亮,
    // 而不是"这组有没有开关是开的"。否则会出现图上灯灭着、卡片却高亮。
    final active = state.isGroupLit(group.id);

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
              partial ? s.partial : (on ? s.on : s.off),
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
    // 只有白光模式的亮度是用户说了算。
    // 日行灯和氛围灯固件里就是给满的,爆闪走节奏表,这三个手动调没有意义。
    final adjustable = state.brightnessAdjustable;
    // 不可调的时候显示固件真正在用的那个亮度,而不是滑条记着的值,
    // 否则日行模式下会显示上次拖到的 60%,和车上看到的对不上。
    final shown = adjustable ? state.brightness : state.effectiveDuty;
    final lightColor = lightColorOf(state.mode);
    final off = state.isOff;

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

