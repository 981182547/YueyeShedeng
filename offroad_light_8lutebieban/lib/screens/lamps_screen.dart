import 'package:flutter/material.dart';

import '../models/lamp.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/car_view.dart';

/// 分路控制页:8 组 × 3 路 = 24 路,一路一路直接开关。
///
/// 这一页是【最高权限】—— 开关就是输出。想要"前杠灯出白光、顶灯出氛围灯"
/// 这种整组按钮给不了的组合,就在这里点。
///
/// 主页上主灯/辅助灯那两排按钮是预设图章:点一下会把那几组重设一遍,
/// 所以改花了想复位,回主页点一下对应的按钮就行。
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
              // 想拆到某一路就用下面那 24 个开关
              CarView(
                state: state,
                labelMode: LampLabel.group,
                onTapGroup: (g) => state.toggleGroup(groupById(g)),
              ),

              // 改花了就说一声怎么恢复,否则用户找不到复位的入口
              if (state.anyCustom)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    children: [
                      const Icon(Icons.tune,
                          size: 14, color: AppColors.textLo),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          s.customizedHint,
                          style: const TextStyle(
                              fontSize: 11.5, height: 1.4,
                              color: AppColors.textLo),
                        ),
                      ),
                    ],
                  ),
                ),

              const SizedBox(height: 16),

              // 主灯 1~4 一段、辅助灯 5~8 一段,和主页底部那两排按钮对应
              for (final sec in kSections) ...[
                _SectionHeader(title: sectionName(s, sec)),
                for (final g in sec.groupIds)
                  _GroupSection(state: state, group: groupById(g)),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// 「主灯」「辅助灯」段标题
class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 0, 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: AppColors.textLo,
          letterSpacing: 1,
        ),
      ),
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
                _lightSwitch(
                  // 整组开关是"这组有没有亮着",不是"三路全开"——
                  // 整组按钮每次只开一路,要求三路全开才算开的话,
                  // 这个开关永远是灰的。
                  value: state.isGroupLit(group.id),
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
    // 开关就是输出:开着 = 这一路正在亮,没有"开着但被模式挡住"这回事
    final on = state.isChOn(ch);
    final color = fnColor(fn);

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
              color: on
                  ? color.withValues(alpha: 0.9)
                  : AppColors.surfaceHi,
              border: Border.all(
                color: on ? color : AppColors.border,
              ),
              boxShadow: on
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
              color: on ? Colors.black87 : AppColors.textLo,
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
              // 一眼看出这会儿哪几路真的亮着
              if (on) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    s.litNow,
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
