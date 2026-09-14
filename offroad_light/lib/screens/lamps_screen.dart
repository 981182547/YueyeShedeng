import 'package:flutter/material.dart';

import '../models/lamp.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/car_view.dart';

/// 分路控制页:12 路 PWM 一路一路独立开关。
///
/// 主页那 4 个组开关是"一次切一组的 3 路",这一页是把这 3 路拆开来单独管 ——
/// 比如想让前包围只出氛围灯、别的组正常,就在这里把前包围的射灯那一路关掉。
///
/// 关掉的通道在【对应模式下】不亮:关了氛围灯那一路,切到氛围灯模式时这组就是暗的,
/// 但切回白光模式照样亮。爆闪是唯一的例外,固件那边无视掩码四组一起闪。
class LampsScreen extends StatelessWidget {
  final AppState state;
  const LampsScreen({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        // 同主页:必须在 builder 里面取,否则切了语言这一页的标题不会变
        final s = state.s;
        return Scaffold(
          appBar: AppBar(
            title: Text(s.channelDetail),
            actions: [
              TextButton(
                onPressed: state.allOn,
                child: Text(s.allOn,
                    style: const TextStyle(color: AppColors.textHi)),
              ),
              TextButton(
                onPressed: state.allOff,
                child: Text(s.allOff,
                    style: const TextStyle(color: AppColors.textLo)),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  s.channelHint,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.5,
                    color: AppColors.textLo.withValues(alpha: 0.9),
                  ),
                ),
              ),

              // 车图:这里点一下也是切整组(左右并联,分不开),
              // 想拆到某一路就用下面那 12 个开关
              CarView(
                state: state,
                labelMode: LampLabel.group,
                onTapGroup: (g) => state.toggleGroup(groupById(g)),
              ),

              // 爆闪无视掩码,这点必须写清楚,否则用户会以为开关坏了
              if (state.mode == LightMode.flash)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline,
                          size: 14, color: AppColors.textLo),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          s.flashIgnoresMask,
                          style: const TextStyle(
                              fontSize: 11.5, color: AppColors.textLo),
                        ),
                      ),
                    ],
                  ),
                ),

              const SizedBox(height: 16),

              for (final g in kGroups) _GroupSection(state: state, group: g),
            ],
          ),
        );
      },
    );
  }
}

/// 统一的灯光开关样式:打开时染成这一路灯的真实颜色。
///
/// 这里用 WidgetStateProperty 而不是 Switch 的 activeThumbColor ——
/// 后者是较新 Flutter 才加的参数,属性解析写法在各版本上都编得过。
Widget _lightSwitch({
  required bool value,
  required Color color,
  required VoidCallback onTap,
}) {
  return Switch(
    value: value,
    thumbColor: WidgetStateProperty.resolveWith<Color?>(
      (s) => s.contains(WidgetState.selected) ? color : null,
    ),
    trackColor: WidgetStateProperty.resolveWith<Color?>(
      (s) => s.contains(WidgetState.selected)
          ? color.withValues(alpha: 0.35)
          : null,
    ),
    onChanged: (_) => onTap(),
  );
}

/// 这一路灯本身是什么颜色 —— 只有氛围灯是黄的
Color _fnColor(int fn) =>
    fn == LampFn.ambient ? AppColors.lightYellow : AppColors.lightWhite;

IconData _fnIcon(int fn) => switch (fn) {
      LampFn.spot => Icons.lightbulb_circle,
      LampFn.drl => Icons.wb_twilight,
      LampFn.ambient => Icons.blur_circular,
      _ => Icons.circle,
    };

class _GroupSection extends StatelessWidget {
  final AppState state;
  final LampGroup group;
  const _GroupSection({required this.state, required this.group});

  @override
  Widget build(BuildContext context) {
    final s = state.s;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          // 组标题:右边的开关一键切这组的 3 路
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 6),
            child: Row(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${group.id + 1}  ${groupName(s, group.id)}',
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textHi,
                      ),
                    ),
                    Text(
                      groupSubtitle(s, group.id),
                      style: const TextStyle(
                          fontSize: 11.5, color: AppColors.textLo),
                    ),
                  ],
                ),
                const Spacer(),
                Text(
                  state.isGroupPartial(group) ? s.partial : '',
                  style: const TextStyle(fontSize: 11, color: AppColors.textLo),
                ),
                _lightSwitch(
                  value: state.isGroupOn(group),
                  color: AppColors.lightWhite,
                  onTap: () => state.toggleGroup(group),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.border),

          // 组内 3 路各自一行
          for (final fn in LampFn.all)
            _ChannelTile(
              state: state,
              group: group,
              fn: fn,
              last: fn == LampFn.all.last,
            ),
        ],
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  final AppState state;
  final LampGroup group;
  final int fn;
  final bool last;

  const _ChannelTile({
    required this.state,
    required this.group,
    required this.fn,
    required this.last,
  });

  @override
  Widget build(BuildContext context) {
    final s = state.s;
    final ch = chOf(group.id, fn);
    final on = state.isChOn(ch);
    final color = _fnColor(fn);

    // 这一路正不正在出光:当前模式用的就是它,而且它的开关是开着的
    final active = state.activeFn == fn && on;

    return Column(
      children: [
        ListTile(
          onTap: () => state.toggleCh(ch),
          contentPadding: const EdgeInsets.only(left: 14, right: 6),
          leading: Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active
                  ? color.withValues(alpha: 0.9)
                  : AppColors.surfaceHi,
              border: Border.all(
                color: active ? color : AppColors.border,
              ),
              boxShadow: active
                  ? [
                      BoxShadow(
                        color: color.withValues(alpha: 0.5),
                        blurRadius: 10,
                        spreadRadius: 1,
                      )
                    ]
                  : null,
            ),
            child: Icon(
              _fnIcon(fn),
              size: 16,
              color: active ? Colors.black87 : AppColors.textLo,
            ),
          ),
          title: Row(
            children: [
              Text(
                fnName(s, fn),
                style: TextStyle(
                  fontSize: 14,
                  color: on ? AppColors.textHi : AppColors.textLo,
                ),
              ),
              // 一眼看出这会儿在用哪一路,不用回主页对模式
              if (active) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    s.activeNow,
                    style: TextStyle(fontSize: 10, color: color),
                  ),
                ),
              ],
            ],
          ),
          subtitle: Text(
            // 通道号照着固件的映射写,接线或调试时直接对得上
            s.channelNo(ch),
            style: const TextStyle(fontSize: 11, color: AppColors.textLo),
          ),
          trailing: _lightSwitch(
            value: on,
            color: color,
            onTap: () => state.toggleCh(ch),
          ),
        ),
        if (!last) const Divider(height: 1, indent: 56, color: AppColors.border),
      ],
    );
  }
}
