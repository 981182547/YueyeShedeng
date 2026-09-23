import 'package:flutter/material.dart';

import '../ble/protocol.dart';
import '../i18n/strings.dart';
import '../models/lamp.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/car_view.dart';
import '../widgets/device_picker.dart';
import 'lamps_screen.dart';

/// 主页:车图 + 8 组卡片 + 娱乐模式 + 亮度,底部是主灯/辅助灯两排按钮
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
                // 看【实际亮没亮】—— 分路控制页可以手动点亮任意一路,
                // 那时候这个按钮得是亮的
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
                  _GroupGrid(state: state),
                  const SizedBox(height: 12),
                  _PartyButton(state: state),
                  const SizedBox(height: 12),
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
          bottomNavigationBar: _SectionBar(state: state),
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

/// 主灯 / 辅助灯各自现在是什么状态,一行说清楚。
/// 这一行的内容全部来自设备上报,所以它显示的就是车上真实的样子。
class _StatusBar extends StatelessWidget {
  final AppState state;
  const _StatusBar({required this.state});

  @override
  Widget build(BuildContext context) {
    final s = state.s;
    // 状态点的颜色看【实际亮着的是哪一路】—— 只留了氛围灯,这个点就是黄的
    final lightColor = state.litColor;
    final off = state.allDark;

    // 某一区各组不一样(语音单独改过某一组,或者分路页手动改过),就显示「自定义」;
    // 这一区的板子没接,就显示「未接」
    String secText(Section sec) {
      final what = state.isSectionPresent(sec)
          ? actName(s, state.sectionAct(sec))
          : s.notFitted;
      return '${sectionName(s, sec)} $what';
    }

    final text = state.party
        ? s.party
        : '${secText(kSectionMain)}   ·   ${secText(kSectionAux)}';

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
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textHi,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            // 分母是接了几组:两片都在是 8,只接一片是 4
            s.groupCount(state.onGroupCount, state.presentGroupCount),
            style: const TextStyle(color: AppColors.textLo, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}

/// 8 组灯的开关卡片:上排主灯 1~4,下排辅助灯 5~8。
/// 和车图上的点击是同一套动作 —— 车图上的灯太小,这里点起来更稳。
class _GroupGrid extends StatelessWidget {
  final AppState state;
  const _GroupGrid({required this.state});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final sec in kSections) ...[
          Row(
            children: [
              for (final g in sec.groupIds) ...[
                Expanded(child: _GroupChip(state: state, group: groupById(g))),
                if (g != sec.groupIds.last) const SizedBox(width: 8),
              ],
            ],
          ),
          if (sec != kSections.last) const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _GroupChip extends StatelessWidget {
  final AppState state;
  final LampGroup group;
  const _GroupChip({required this.state, required this.group});

  @override
  Widget build(BuildContext context) {
    final s = state.s;
    // 这组的板子没接:整张卡片变灰、点不了
    final present = state.isGroupPresent(group.id);
    // 亮不亮只看"有没有任意一路开着";卡片染成这组【实际亮着的那一路】的颜色
    final active = present && state.isGroupLit(group.id);
    final lightColor = state.groupLitColor(group.id);

    return IgnorePointer(
      ignoring: !present,
      child: Opacity(
        opacity: present ? 1 : 0.35,
        child: _chip(s, active, lightColor),
      ),
    );
  }

  Widget _chip(S s, bool active, Color lightColor) {
    return GestureDetector(
      onTap: () => state.toggleGroup(group),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 7),
        decoration: BoxDecoration(
          color: active ? lightColor.withValues(alpha: 0.10) : AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: active ? lightColor.withValues(alpha: 0.55) : AppColors.border,
          ),
        ),
        child: Row(
          children: [
            // 编号和车图上标的一样
            Container(
              width: 18,
              height: 18,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active ? lightColor : AppColors.surfaceHi,
              ),
              child: Text(
                '${group.id + 1}',
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1,
                  fontWeight: FontWeight.w700,
                  color: active ? Colors.black87 : AppColors.textLo,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                groupName(s, group.id),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: active ? AppColors.textHi : AppColors.textLo,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 娱乐模式:8 组轮流爆闪。它盖在上面显示,关掉后原来的灯光原样恢复。
class _PartyButton extends StatelessWidget {
  final AppState state;
  const _PartyButton({required this.state});

  @override
  Widget build(BuildContext context) {
    final s = state.s;
    final on = state.party;
    const color = AppColors.accent;

    return GestureDetector(
      onTap: state.toggleParty,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: on ? color.withValues(alpha: 0.14) : AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: on ? color.withValues(alpha: 0.7) : AppColors.border,
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.celebration,
                size: 21, color: on ? color : AppColors.textLo),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.party,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textHi,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    on ? s.partyOnHint : s.partyHint,
                    style: const TextStyle(
                        fontSize: 11.5, color: AppColors.textLo),
                  ),
                ],
              ),
            ),
            Icon(
              on ? Icons.stop_circle_outlined : Icons.play_circle_outline,
              size: 24,
              color: on ? color : AppColors.textLo,
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
    // 滑条只管白光常亮的组。日行、氛围、爆闪、微亮的亮度都是固件定死的,
    // 所以一组白光常亮的都没有的时候把滑条置灰。
    final adjustable = state.brightnessAdjustable;
    final shown = state.brightness;
    const lightColor = AppColors.lightWhite; // 调的是白光
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
                        // 锁:提示现在亮着的这些灯亮度是固件定的,不是没反应
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

/// 底部两排:主灯一排、辅助灯一排,每个按钮给这一区的几组盖同一个图章。
///
/// 这一区各组都是同一个状态时,对应的按钮高亮;各组不一样(单独改过某一组)
/// 就一个都不亮,上面状态条会写「自定义」。辅助灯没有微亮,那一格空着,
/// 让两排的「关」上下对齐。
class _SectionBar extends StatelessWidget {
  final AppState state;
  const _SectionBar({required this.state});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final sec in kSections)
                _SectionRow(state: state, section: sec),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionRow extends StatelessWidget {
  final AppState state;
  final Section section;
  const _SectionRow({required this.state, required this.section});

  @override
  Widget build(BuildContext context) {
    final s = state.s;
    // 这一区的板子没接:整排变灰、点不了,名字下面标「未接」
    final present = state.isSectionPresent(section);
    // 娱乐模式开着的时候哪个都不高亮 —— 那会儿车上亮的不是这些
    final current = (state.party || !present) ? null : state.sectionAct(section);

    return IgnorePointer(
      ignoring: !present,
      child: Opacity(
        opacity: present ? 1 : 0.35,
        child: Row(
          children: [
            SizedBox(
              width: 48,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    sectionName(s, section),
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textHi,
                    ),
                  ),
                  if (!present)
                    Text(
                      s.notFitted,
                      style: const TextStyle(
                          fontSize: 10, color: AppColors.textLo),
                    ),
                ],
              ),
            ),
            for (final a in actSlots(section))
              Expanded(
                child: a == null
                    ? const SizedBox.shrink()
                    : _ActButton(
                        info: a,
                        label: actName(s, a.act),
                        selected: current == a.act,
                        onTap: () => state.applySection(section, a.act),
                      ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ActButton extends StatelessWidget {
  final ActInfo info;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ActButton({
    required this.info,
    required this.label,
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
        margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
        padding: const EdgeInsets.symmetric(vertical: 7),
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
              size: 19,
              color: selected ? info.color : AppColors.textLo,
            ),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.fade,
              softWrap: false,
              style: TextStyle(
                fontSize: 11,
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
