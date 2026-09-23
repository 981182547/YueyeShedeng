import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../i18n/strings.dart';
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

  /// 取当前语言的文案表。
  ///
  /// 传的是【函数】不是 S 实例:用户切语言之后,这里之后再产生的提示
  /// 也要跟着变。存一份实例的话会一直用连接时那个语言。
  final S Function() strings;

  S get _s => strings();

  BleManager({
    required this.onState,
    required this.strings,
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

  /// 当前设备的显示名(没名字就退回设备 ID),没连时为 null
  String? get deviceLabel {
    final d = _device;
    if (d == null) return null;
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

  static String describeAdapter(S s, BluetoothAdapterState st) => switch (st) {
        BluetoothAdapterState.on => s.adapterOn(),
        BluetoothAdapterState.off => s.adapterOff(),
        BluetoothAdapterState.turningOn => s.adapterTurningOn(),
        BluetoothAdapterState.turningOff => s.adapterTurningOff(),
        BluetoothAdapterState.unauthorized => s.adapterUnauthorized(),
        BluetoothAdapterState.unavailable => s.adapterUnavailable(),
        _ => s.adapterUnknown(),
      };

  /// 需要用户去系统设置里手动授权(iOS 拒绝过蓝牙权限后无法再次弹窗)
  bool needsSystemSettings = false;

  Future<void> openSystemSettings() => openAppSettings();

  Future<bool> _ensureReady() async {
    if (await FlutterBluePlus.isSupported == false) {
      _log(_s.bleUnsupported);
      return false;
    }

    // 顺序很重要:必须【先】拿权限。
    // Android 12+ 没有 BLUETOOTH_CONNECT 权限时,连适配器状态都读不到,
    // 先查状态会得到 unknown,误判成"蓝牙未开启"而直接放弃。
    if (!await hasPermissions()) {
      if (!await requestPermissions()) {
        _log(_s.blePermissionNeeded);
        return false;
      }
    }

    // iOS 上"权限被拒"会表现为 unauthorized,和"蓝牙关了"完全是两回事,
    // 提示必须分开,否则用户会一直去开本来就开着的蓝牙开关。
    final st = await adapterState();
    if (st == BluetoothAdapterState.unauthorized) {
      needsSystemSettings = true;
      _log(_s.bleUnauthorized);
      return false;
    }
    if (st == BluetoothAdapterState.unavailable) {
      _log(_s.bleUnsupported);
      return false;
    }
    if (st != BluetoothAdapterState.on) {
      _log(_s.bleAdapterOff(describeAdapter(_s, st)));
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
    _log(_s.bleScanning);

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
      onError: (e) => _log(_s.bleScanError(e)),
    );

    try {
      // 不按服务 UUID 过滤,直接扫全部:
      // 广播包只有 31 字节,设备名 + 128 位服务 UUID 常常放不下而被裁掉,
      // 一过滤就什么都扫不到。列表里会把射灯排在最前面。
      await FlutterBluePlus.startScan(timeout: timeout);
    } catch (e) {
      _log(_s.bleScanFailed(e));
    }

    if (_state == Conn.scanning) {
      if (scanResults.isEmpty) {
        _log(_s.bleNoneFound);
      } else {
        _log(_s.bleFoundN(scanResults.length));
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
      _log(_s.bleNotFoundNearby);
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
    final name =
        device.platformName.isEmpty ? _s.unknownDevice : device.platformName;
    _log(_s.bleConnectingTo(name));

    try {
      await device.connect(timeout: const Duration(seconds: 15));

      // MTU 协商:部分手机会挂起,超时就用默认值继续,不能卡死
      try {
        _mtu = await device.requestMtu(185).timeout(const Duration(seconds: 5));
      } catch (e) {
        _mtu = 23;
        _log(_s.bleMtuSkipped);
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
        if (rx != null) _log(_s.bleFallbackWrite(rx.uuid));
      }

      if (rx == null) {
        _log(_s.bleNoWritable);
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
          _log(_s.bleLost);
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
      _log(_s.bleConnected);

      // 连上先问一次当前状态,把界面同步成设备的真实状态
      await send(Protocol.query());
    } on TimeoutException {
      _log(_s.bleTimeout);
      await disconnect();
    } catch (e) {
      _log(_s.bleConnectFailed(e));
      await disconnect();
    }
  }

  /// Notify 到底订上了没。
  ///
  /// 这一步失败的话,车上用语音/传感器改了状态,手机是完全不会知道的 ——
  /// 界面看着一切正常,其实显示的是过期数据。所以必须让界面能看见这个状态。
  bool notifyReady = false;

  /// 订阅射灯的 Notify 特征。
  /// 设备端语音、传感器、手机三方谁改了状态都会推一帧过来,界面据此实时刷新。
  Future<void> _subscribeNotify(List<BluetoothService> services) async {
    notifyReady = false;
    BluetoothCharacteristic? tx;
    for (final svc in services) {
      for (final c in svc.characteristics) {
        if (c.uuid == Guid(Protocol.txUuid)) tx = c;
      }
    }
    if (tx == null) {
      _log(_s.bleNoNotify);
      return;
    }
    try {
      // 顺序很重要:先挂监听,再开订阅。
      // 反过来的话,setNotifyValue 返回到 listen 之间设备推过来的帧会直接丢掉,
      // 而连上后的第一帧恰恰就在这个窗口里。
      await _notifySub?.cancel();
      _notifySub = tx.onValueReceived.listen(_onDeviceData);
      await tx.setNotifyValue(true);
      notifyReady = true;
    } catch (e) {
      _log(_s.bleNotifyFailed(e));
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
    _log(_s.bleRetryIn(delay));
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
      _log(_s.bleRetryFailed(e));
      _scheduleReconnect();
    }
  }

  /// 上层在启动时调用:如果记得上次的设备就自动连上
  Future<void> tryAutoConnect(String? savedId) async {
    if (savedId == null || savedId.isEmpty) return;
    _lastDeviceId = savedId;
    _log(_s.bleAutoConnecting);
    await reconnectLast();
  }

  // ---------------- 发送 ----------------
  Future<void> send(Uint8List msg) {
    if (_state != Conn.connected) return Future.value();
    _writeChain = _writeChain.then((_) => _write(msg)).catchError((e) {
      _log(_s.bleSendFailed(e));
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
    notifyReady = false;
  }

  void dispose() {
    _retryTimer?.cancel();
    _cleanup();
  }
}
