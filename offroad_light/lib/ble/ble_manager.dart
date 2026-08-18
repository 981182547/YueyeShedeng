import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'protocol.dart';

enum Conn { disconnected, scanning, connecting, connected }

/// BLE 客户端:扫描 -> 连接 -> 协商 MTU -> 找到读写特征 -> 收发 0xA5 封包。
///
/// 每一步都有超时保护:某些手机上 requestMtu / discoverServices 会永久挂起,
/// 没有超时就会出现"射灯已经连上、App 却一直转圈"的情况。
class BleManager {
  final void Function(Conn) onState;
  final void Function(String) onLog;

  /// 扫描列表有更新时回调,供设备选择弹层刷新
  void Function()? onScanUpdate;

  /// 连接成功后回调,把设备 ID 交给上层持久化,下次自动重连用
  final void Function(String deviceId)? onRemember;

  /// 收到射灯主动上报的数据(Notify)
  final void Function(int op, List<int> payload)? onDeviceMessage;

  BleManager({
    required this.onState,
    this.onLog = _noop,
    this.onScanUpdate,
    this.onRemember,
    this.onDeviceMessage,
  });
  static void _noop(String _) {}

  /// 断线后自动重连(用户手动断开时不触发)
  bool autoReconnect = true;
  String? _lastDeviceId;
  bool _manualDisconnect = false;
  int _retry = 0;
  Timer? _retryTimer;

  final List<ScanResult> scanResults = [];

  BluetoothDevice? _device;
  BluetoothCharacteristic? _rx;
  int _mtu = 23;

  Conn _state = Conn.disconnected;
  Conn get state => _state;

  BluetoothDevice? get connectedDevice =>
      _state == Conn.connected ? _device : null;

  String get deviceLabel {
    final d = _device;
    if (d == null) return '未连接';
    return d.platformName.isEmpty ? d.remoteId.str : d.platformName;
  }

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _notifySub;

  // 顺序写入锁:把每次发送串起来,避免并发写特征
  Future<void> _writeChain = Future.value();

  bool get isConnected => _state == Conn.connected;

  void _setState(Conn s) {
    _state = s;
    onState(s);
  }

  void _log(String m) => onLog(m);

  // ---------------- 权限 ----------------

  /// 只有安卓需要 App 主动申请蓝牙/定位权限。
  /// iOS 的蓝牙权限由系统在首次扫描时自动弹窗,且不需要定位权限;
  /// 这几个 Permission 在 iOS 上永远不会是 granted,照搬安卓逻辑会把扫描直接拦死。
  static bool get _needsRuntimePermissions =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<bool> hasPermissions() async {
    if (!_needsRuntimePermissions) return true;
    final scan = await Permission.bluetoothScan.status;
    final connect = await Permission.bluetoothConnect.status;
    final loc = await Permission.location.status;
    return (scan.isGranted || scan.isLimited) &&
        (connect.isGranted || connect.isLimited) &&
        (loc.isGranted || loc.isLimited);
  }

  Future<bool> requestPermissions() async {
    if (!_needsRuntimePermissions) return true;
    // 安卓 BLE 扫描依赖定位权限,必须一并申请,否则扫不到任何设备
    final res = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
    return res.values.every((s) => s.isGranted || s.isLimited);
  }

  /// 取蓝牙适配器的真实状态。
  ///
  /// 不能只看 adapterStateNow:那是缓存值,App 刚启动、状态流还没推过值时是
  /// unknown,会误判。这里退回到状态流取一次真实值。
  Future<BluetoothAdapterState> adapterState() async {
    try {
      final now = FlutterBluePlus.adapterStateNow;
      if (now != BluetoothAdapterState.unknown) return now;
      return await FlutterBluePlus.adapterState
          .firstWhere((s) => s != BluetoothAdapterState.unknown)
          .timeout(const Duration(seconds: 4));
    } catch (_) {
      return BluetoothAdapterState.unknown;
    }
  }

  static String describeAdapter(BluetoothAdapterState s) => switch (s) {
        BluetoothAdapterState.on => '已开启',
        BluetoothAdapterState.off => '已关闭',
        BluetoothAdapterState.turningOn => '正在开启',
        BluetoothAdapterState.turningOff => '正在关闭',
        BluetoothAdapterState.unauthorized => '未授权',
        BluetoothAdapterState.unavailable => '不支持',
        _ => '未知',
      };

  /// 需要用户去系统设置里手动授权(iOS 拒绝过蓝牙权限后无法再次弹窗)
  bool needsSystemSettings = false;

  Future<void> openSystemSettings() => openAppSettings();

  Future<bool> _ensureReady() async {
    if (await FlutterBluePlus.isSupported == false) {
      _log('这台手机不支持蓝牙');
      return false;
    }

    // 顺序很重要:必须【先】拿权限。
    // Android 12+ 没有 BLUETOOTH_CONNECT 权限时,连适配器状态都读不到,
    // 先查状态会得到 unknown,误判成"蓝牙未开启"而直接放弃。
    if (!await hasPermissions()) {
      if (!await requestPermissions()) {
        _log('需要蓝牙和位置权限才能搜索射灯(请在系统设置里开启)');
        return false;
      }
    }

    // iOS 上"权限被拒"会表现为 unauthorized,和"蓝牙关了"完全是两回事,
    // 提示必须分开,否则用户会一直去开本来就开着的蓝牙开关。
    final st = await adapterState();
    if (st == BluetoothAdapterState.unauthorized) {
      needsSystemSettings = true;
      _log('蓝牙权限被拒绝,请到系统设置里允许本 App 使用蓝牙');
      return false;
    }
    if (st == BluetoothAdapterState.unavailable) {
      _log('这台手机不支持蓝牙');
      return false;
    }
    if (st != BluetoothAdapterState.on) {
      _log('蓝牙${describeAdapter(st)},请打开蓝牙后重试');
      return false;
    }
    needsSystemSettings = false;
    return true;
  }

  // ---------------- 扫描 ----------------

  Future<void> startScan({Duration timeout = const Duration(seconds: 10)}) async {
    if (_state == Conn.connected || _state == Conn.connecting) return;
    if (!await _ensureReady()) {
      _setState(Conn.disconnected);
      return;
    }

    scanResults.clear();
    onScanUpdate?.call();
    _setState(Conn.scanning);
    _log('正在搜索射灯…');

    await _scanSub?.cancel();
    // 用 scanResults(保留结果)而不是 onScanResults:
    // 后者在扫描停止的瞬间会推一个空列表,会把刚扫到的设备全清掉。
    // 这里按设备 ID 累积合并,永不因为空列表而清空。
    _scanSub = FlutterBluePlus.scanResults.listen(
      (results) {
        for (final r in results) {
          final i = scanResults.indexWhere(
            (e) => e.device.remoteId == r.device.remoteId,
          );
          if (i >= 0) {
            scanResults[i] = r;
          } else {
            scanResults.add(r);
          }
        }
        if (results.isNotEmpty) onScanUpdate?.call();
      },
      onError: (e) => _log('扫描出错: $e'),
    );

    try {
      // 不按服务 UUID 过滤,直接扫全部:
      // 广播包只有 31 字节,设备名 + 128 位服务 UUID 常常放不下而被裁掉,
      // 一过滤就什么都扫不到。列表里会把射灯排在最前面。
      await FlutterBluePlus.startScan(timeout: timeout);
    } catch (e) {
      _log('扫描失败: $e');
    }

    if (_state == Conn.scanning) {
      if (scanResults.isEmpty) {
        _log('没有找到设备,请确认射灯控制器已上电');
      } else {
        _log('找到 ${scanResults.length} 个设备,点击选择');
      }
      _setState(Conn.disconnected);
    }
  }

  Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    if (_state == Conn.scanning) _setState(Conn.disconnected);
  }

  /// 是不是我们的射灯控制器。以广播里的服务 UUID 为准,不靠名字:
  /// iOS 缓存 GAP 名称时 ESP32 可能被报成别的名字,只看名字会认不出来。
  static bool isSpotlight(ScanResult r) {
    if (r.advertisementData.serviceUuids.contains(Guid(Protocol.serviceUuid))) {
      return true;
    }
    return r.advertisementData.advName == Protocol.deviceName ||
        r.device.platformName == Protocol.deviceName;
  }

  /// 扫描并自动连接第一个识别出来的射灯
  Future<void> connect() async {
    await startScan();
    if (scanResults.isEmpty) return;

    final found = scanResults.where(isSpotlight);
    if (found.isEmpty) {
      _log('附近没有识别到射灯,请手动选择');
      return;
    }
    await connectTo(found.first.device);
  }

  // ---------------- 连接 ----------------
  Future<void> connectTo(BluetoothDevice device) async {
    await stopScan();
    if (_state == Conn.connected || _state == Conn.connecting) return;

    _setState(Conn.connecting);
    _device = device;
    final name = device.platformName.isEmpty ? '设备' : device.platformName;
    _log('正在连接 $name…');

    try {
      await device.connect(timeout: const Duration(seconds: 15));

      // MTU 协商:部分手机会挂起,超时就用默认值继续,不能卡死
      try {
        _mtu = await device.requestMtu(185).timeout(const Duration(seconds: 5));
      } catch (e) {
        _mtu = 23;
        _log('MTU 协商跳过,用默认 23');
      }

      final services =
          await device.discoverServices().timeout(const Duration(seconds: 15));

      BluetoothCharacteristic? rx;
      for (final svc in services) {
        for (final c in svc.characteristics) {
          if (c.uuid == Guid(Protocol.rxUuid)) rx = c;
        }
      }
      // 没找到指定 UUID 时,退而求其次找任意可写特征
      if (rx == null) {
        for (final svc in services) {
          for (final c in svc.characteristics) {
            if (c.properties.write || c.properties.writeWithoutResponse) {
              rx = c;
              break;
            }
          }
          if (rx != null) break;
        }
        if (rx != null) _log('未找到标准写特征,改用 ${rx.uuid}');
      }

      if (rx == null) {
        _log('未找到可写特征,断开');
        await disconnect();
        return;
      }

      _rx = rx;

      // 订阅射灯的状态上报
      await _subscribeNotify(services);

      // 连上之后才监听断开事件:提前监听会立刻收到一个 disconnected 初始值
      await _connSub?.cancel();
      _connSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected &&
            _state == Conn.connected) {
          _log('射灯已断开');
          _cleanup();
          _setState(Conn.disconnected);
          if (!_manualDisconnect) _scheduleReconnect();
        }
      });

      _lastDeviceId = device.remoteId.str;
      _manualDisconnect = false;
      _retry = 0;
      onRemember?.call(_lastDeviceId!);

      _setState(Conn.connected);
      _log('已连接');

      // 连上先问一次当前状态,把界面同步成设备的真实状态
      await send(Protocol.query());
    } on TimeoutException {
      _log('连接超时,请重试');
      await disconnect();
    } catch (e) {
      _log('连接失败: $e');
      await disconnect();
    }
  }

  /// 订阅射灯的 Notify 特征。
  /// 设备端语音、传感器、手机三方谁改了状态都会推一帧过来,界面据此实时刷新。
  Future<void> _subscribeNotify(List<BluetoothService> services) async {
    BluetoothCharacteristic? tx;
    for (final svc in services) {
      for (final c in svc.characteristics) {
        if (c.uuid == Guid(Protocol.txUuid)) tx = c;
      }
    }
    if (tx == null) {
      _log('未找到状态上报特征,界面将无法自动刷新');
      return;
    }
    try {
      await tx.setNotifyValue(true);
      await _notifySub?.cancel();
      _notifySub = tx.onValueReceived.listen(_onDeviceData);
    } catch (e) {
      _log('订阅状态上报失败: $e');
    }
  }

  // 设备发来的数据是流式的,按 0xA5 封包重组
  final List<int> _rxBuf = [];

  void _onDeviceData(List<int> chunk) {
    _rxBuf.addAll(chunk);
    while (true) {
      final start = _rxBuf.indexOf(Protocol.magic);
      if (start < 0) {
        _rxBuf.clear();
        return;
      }
      if (start > 0) _rxBuf.removeRange(0, start);
      if (_rxBuf.length < 4) return;

      final op = _rxBuf[1];
      final len = (_rxBuf[2] << 8) | _rxBuf[3];
      if (_rxBuf.length < 4 + len) return; // 还没收齐

      final payload = _rxBuf.sublist(4, 4 + len);
      _rxBuf.removeRange(0, 4 + len);
      onDeviceMessage?.call(op, payload);
    }
  }

  // ---------------- 自动重连 ----------------
  void _scheduleReconnect() {
    if (!autoReconnect || _lastDeviceId == null) return;
    _retryTimer?.cancel();
    // 退避:2s、4s、8s、15s,之后固定 30s,避免一直高频重试耗电
    const backoff = [2, 4, 8, 15, 30];
    final delay = backoff[_retry < backoff.length ? _retry : backoff.length - 1];
    _retry++;
    _log('$delay 秒后尝试重连…');
    _retryTimer = Timer(Duration(seconds: delay), () {
      if (_state == Conn.disconnected) reconnectLast();
    });
  }

  Future<void> reconnectLast() async {
    final id = _lastDeviceId;
    if (id == null) return;
    if (_state != Conn.disconnected) return;
    if (!await _ensureReady()) return;
    try {
      await connectTo(BluetoothDevice.fromId(id));
    } catch (e) {
      _log('重连失败: $e');
      _scheduleReconnect();
    }
  }

  /// 上层在启动时调用:如果记得上次的设备就自动连上
  Future<void> tryAutoConnect(String? savedId) async {
    if (savedId == null || savedId.isEmpty) return;
    _lastDeviceId = savedId;
    _log('正在自动连接上次的射灯…');
    await reconnectLast();
  }

  // ---------------- 发送 ----------------
  Future<void> send(Uint8List msg) {
    if (_state != Conn.connected) return Future.value();
    _writeChain = _writeChain.then((_) => _write(msg)).catchError((e) {
      _log('发送失败: $e');
    });
    return _writeChain;
  }

  Future<void> _write(Uint8List msg) async {
    final c = _rx;
    if (c == null) return;
    final noResp = !c.properties.write && c.properties.writeWithoutResponse;
    // 控制指令都只有几个字节,正常一次就写完。
    // 这里仍按 MTU 分片:以后万一加了长指令,不会因为超长被底层直接丢掉。
    final chunk = (_mtu - 3).clamp(20, 512);
    var i = 0;
    while (i < msg.length) {
      final end = (i + chunk < msg.length) ? i + chunk : msg.length;
      await c.write(msg.sublist(i, end), withoutResponse: noResp);
      i = end;
    }
  }

  // ---------------- 断开 ----------------
  Future<void> disconnect() async {
    _manualDisconnect = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    try {
      await _device?.disconnect();
    } catch (_) {}
    _cleanup();
    _setState(Conn.disconnected);
  }

  void _cleanup() {
    _scanSub?.cancel();
    _scanSub = null;
    _connSub?.cancel();
    _connSub = null;
    _notifySub?.cancel();
    _notifySub = null;
    _rxBuf.clear();
    _rx = null;
    _mtu = 23;
  }

  void dispose() {
    _retryTimer?.cancel();
    _cleanup();
  }
}
