import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../ble/ble_manager.dart';
import '../theme.dart';

/// 设备选择弹层:扫描附近的蓝牙设备,射灯排在最前面
Future<void> showDevicePicker(BuildContext context, BleManager ble) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _DeviceSheet(ble: ble),
  );
}

class _DeviceSheet extends StatefulWidget {
  final BleManager ble;
  const _DeviceSheet({required this.ble});

  @override
  State<_DeviceSheet> createState() => _DeviceSheetState();
}

class _DeviceSheetState extends State<_DeviceSheet> {
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    // 弹层期间临时接管扫描回调,关掉时还回去
    widget.ble.onScanUpdate = () {
      if (mounted) setState(() {});
    };
    _scan();
  }

  @override
  void dispose() {
    widget.ble.onScanUpdate = null;
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    await widget.ble.startScan();
    if (mounted) setState(() => _scanning = false);
  }

  @override
  Widget build(BuildContext context) {
    // 射灯优先,其次按信号强度排序;没名字的设备沉底
    final list = [...widget.ble.scanResults]..sort((a, b) {
        final pa = BleManager.isSpotlight(a) ? 0 : 1;
        final pb = BleManager.isSpotlight(b) ? 0 : 1;
        if (pa != pb) return pa - pb;
        final na = a.device.platformName.isEmpty ? 1 : 0;
        final nb = b.device.platformName.isEmpty ? 1 : 0;
        if (na != nb) return na - nb;
        return b.rssi.compareTo(a.rssi);
      });

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Text('选择射灯控制器',
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textHi)),
                const Spacer(),
                if (_scanning)
                  const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                else
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: _scan,
                    tooltip: '重新搜索',
                  ),
              ],
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.5,
              ),
              child: list.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 32),
                      child: Text(
                        _scanning ? '正在搜索…' : '没找到设备,确认控制器已上电',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppColors.textLo),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: list.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, color: AppColors.border),
                      itemBuilder: (_, i) => _tile(list[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(ScanResult r) {
    final ours = BleManager.isSpotlight(r);
    final name = r.device.platformName.isEmpty
        ? (r.advertisementData.advName.isEmpty
            ? '未知设备'
            : r.advertisementData.advName)
        : r.device.platformName;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        ours ? Icons.lightbulb_circle : Icons.bluetooth,
        color: ours ? AppColors.accent : AppColors.textLo,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppColors.textHi)),
          ),
          if (ours)
            Container(
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text('射灯',
                  style: TextStyle(fontSize: 10, color: AppColors.accent)),
            ),
        ],
      ),
      subtitle: Text('${r.device.remoteId.str}   ${r.rssi} dBm',
          style: const TextStyle(fontSize: 11.5, color: AppColors.textLo)),
      onTap: () {
        Navigator.pop(context);
        widget.ble.connectTo(r.device);
      },
    );
  }
}
