import 'package:flutter/material.dart';

import '../models/lamp.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/car_view.dart';

/// 单灯控制页:8 个灯位一个一个独立开关。
///
/// 这里点车图是控制【单个灯位】,和主页点一下开一整组不一样。
class LampsScreen extends StatelessWidget {
  final AppState state;
  const LampsScreen({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('单灯控制'),
            actions: [
              TextButton(
                onPressed: state.allOn,
                child: const Text('全开',
                    style: TextStyle(color: AppColors.textHi)),
              ),
              TextButton(
                onPressed: state.allOff,
                child: const Text('全关',
                    style: TextStyle(color: AppColors.textLo)),
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
                  '点车图上的光点,或用下面的开关,单独控制每一只灯',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: AppColors.textLo.withValues(alpha: 0.9),
                  ),
                ),
              ),

              // 车图:这里点一下只切一个灯位
              CarView(
                state: state,
                showLabels: true,
                onTapLamp: (lamp) => state.toggleLamp(lamp.id),
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

/// 统一的灯光开关样式:打开时染成当前的灯光颜色。
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

class _GroupSection extends StatelessWidget {
  final AppState state;
  final LampGroup group;
  const _GroupSection({required this.state, required this.group});

  @override
  Widget build(BuildContext context) {
    final lightColor =
        state.isYellow ? AppColors.lightYellow : AppColors.lightWhite;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          // 组标题:右边的开关一键切整组
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 6),
            child: Row(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      group.name,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textHi,
                      ),
                    ),
                    Text(
                      group.subtitle,
                      style: const TextStyle(
                          fontSize: 11.5, color: AppColors.textLo),
                    ),
                  ],
                ),
                const Spacer(),
                Text(
                  state.isGroupPartial(group) ? '半开' : '',
                  style: const TextStyle(fontSize: 11, color: AppColors.textLo),
                ),
                _lightSwitch(
                  value: state.isGroupOn(group),
                  color: lightColor,
                  onTap: () => state.toggleGroup(group),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.border),

          // 组内两个灯位各自一行
          for (final id in group.lampIds)
            _LampTile(
              state: state,
              lamp: lampById(id),
              last: id == group.lampIds.last,
            ),
        ],
      ),
    );
  }
}

class _LampTile extends StatelessWidget {
  final AppState state;
  final Lamp lamp;
  final bool last;

  const _LampTile({
    required this.state,
    required this.lamp,
    required this.last,
  });

  @override
  Widget build(BuildContext context) {
    final on = state.isLampOn(lamp.id);
    final lit = state.isLampLit(lamp.id);
    final lightColor =
        state.isYellow ? AppColors.lightYellow : AppColors.lightWhite;

    return Column(
      children: [
        ListTile(
          onTap: () => state.toggleLamp(lamp.id),
          contentPadding: const EdgeInsets.only(left: 14, right: 6),
          leading: Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: lit
                  ? lightColor.withValues(alpha: 0.9)
                  : AppColors.surfaceHi,
              border: Border.all(
                color: lit ? lightColor : AppColors.border,
              ),
              boxShadow: lit
                  ? [
                      BoxShadow(
                        color: lightColor.withValues(alpha: 0.5),
                        blurRadius: 10,
                        spreadRadius: 1,
                      )
                    ]
                  : null,
            ),
            child: Text(
              '${lamp.id + 1}',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: lit ? Colors.black87 : AppColors.textLo,
              ),
            ),
          ),
          title: Text(
            lamp.name,
            style: TextStyle(
              fontSize: 14,
              color: on ? AppColors.textHi : AppColors.textLo,
            ),
          ),
          subtitle: Text(
            // 通道号照着固件的映射写,接线或调试时直接对得上
            '黄光 CH${lamp.id}  ·  白光 CH${lamp.id + 8}',
            style: const TextStyle(fontSize: 11, color: AppColors.textLo),
          ),
          trailing: _lightSwitch(
            value: on,
            color: lightColor,
            onTap: () => state.toggleLamp(lamp.id),
          ),
        ),
        if (!last) const Divider(height: 1, indent: 56, color: AppColors.border),
      ],
    );
  }
}
