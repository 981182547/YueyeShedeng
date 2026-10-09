/*
 * 越野射灯 —— 语音板（驾驶室） ESP32-C3 / Arduino IDE 版
 *
 * 干的事很简单：从串口收 CI1302 识别出来的指令 "$BMP:ON"，
 * 通过 ESP-NOW 转给前舱的控制板。灯怎么亮全由控制板决定，这块板不跑蓝牙。
 *
 * 配对、指示灯、心跳的规则见 spotlight_link.h 文件头。
 * 引脚见 board_pins.h（语音板：CI1302 TX->GPIO3、RX<-GPIO2，灯 GPIO10，BOOT GPIO9）。
 *
 * ── 耗电 ───────────────────────────────────────────────────
 * 无线一直开着（不进省电），反应最快、最稳；代价是 ESP32 这边约多 80mA。
 * 没做低电关机 —— 过放交给电池保护板。
 *
 * ── Arduino IDE 设置 ───────────────────────────────────────
 *   开发板   : ESP32C3 Dev Module
 *   USB CDC On Boot : Enabled（日志从 USB 口出）
 *   ESP32 核心 : 3.x（和遥控小车同一个环境就行）
 *   依赖库   : 全部为 ESP32 Arduino Core 自带
 */

#define BOARD_VOICE
#include "board_pins.h"
#include "spotlight_link.h"

#include <WiFi.h>
#include <esp_wifi.h>
#include <esp_now.h>
#include <esp_random.h>
#include <Preferences.h>

#define ASR_BAUD          115200
#define CMD_QUEUE_LEN     4       /* 排队等发的语音指令，语音是人说的，4 条足够 */
#define CMD_MAX_TRIES     4       /* 一条指令最多发 4 次（硬件本身还会再重试） */
#define CMD_RETRY_GAP_MS  40      /* 两次重发之间隔多久 */
#define CMD_STALE_MS      3000    /* 排队超过 3 秒还没发出去就丢掉，免得过一会儿灯自己乱变 */
#define SEND_GUARD_MS     300     /* 等发送回执最多等这么久，超时当作这一包丢了 */

static const uint8_t BCAST[6] = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

HardwareSerial ASR(1);
Preferences    prefs;

/* ── 配对状态 ─────────────────────────────────────────── */
static uint8_t  peerMac[6];               /* 控制板 MAC */
static bool     paired       = false;
static volatile bool pairing  = false;    /* 回调里也要读 */
static uint32_t pairingSince = 0;
static uint32_t lastPairReq  = 0;

/* ── 回调 -> loop 的交接 ───────────────────────────────────
 * ESP-NOW 回调跑在 WiFi 任务里，只做标记和拷贝，存盘、加 peer 这些都放 loop 里做。 */
static volatile bool     gotPairAck = false;
static uint8_t           pairAckMac[6];
static volatile uint32_t lastAckMs  = 0;   /* 最近一次单播发送成功（对方硬件应答了） */

/* 同一时间只有一个包在等回执，这样回执对得上是哪个包 */
static volatile uint8_t  inflight     = 0;     /* 正在等回执的包类型，0 = 空闲 */
static uint32_t          inflightSince = 0;
static volatile bool     resultReady  = false;
static volatile bool     resultOk     = false;
static volatile uint8_t  resultType   = 0;

/* ── 待发指令 ─────────────────────────────────────────── */
struct QueuedCmd { char text[LINK_TEXT_MAX]; uint8_t len; uint32_t at; };
static QueuedCmd cmdQ[CMD_QUEUE_LEN];
static uint8_t   qHead = 0, qCount = 0;
static uint8_t   seq = 0;                 /* 开机随机起点，见 setup */
static uint8_t   tries = 0;               /* 队头这条已经发了几次 */
static uint32_t  lastTry = 0;
static uint32_t  lastPing = 0;

static void printMac(const char *label, const uint8_t *m) {
  Serial.printf("%s%02X:%02X:%02X:%02X:%02X:%02X\n", label, m[0], m[1], m[2], m[3], m[4], m[5]);
}

/* ==========================================================
 * ESP-NOW
 * ========================================================== */
static void onSent(LINK_SEND_CB_ARGS) {
  bool ok = (status == ESP_NOW_SEND_SUCCESS);
  uint8_t t = inflight;
  /* 广播没有应答，"发送成功"只代表发出去了，不能当成连上 */
  if (ok && t != LINK_PAIR_REQ) lastAckMs = millis();
  resultType  = t;
  resultOk    = ok;
  resultReady = true;
  inflight    = 0;
}

static void onRecv(LINK_RECV_CB_ARGS) {
  if (len != (int)sizeof(LinkPkt)) return;
  const LinkPkt *p = (const LinkPkt *)data;
  if (p->magic != LINK_MAGIC) return;
  if (p->type == LINK_PAIR_ACK && pairing && !gotPairAck) {
    memcpy(pairAckMac, LINK_RECV_SRC, 6);
    gotPairAck = true;
  }
}

static void addPeer(const uint8_t *mac) {
  if (esp_now_is_peer_exist(mac)) return;
  esp_now_peer_info_t info = {};
  memcpy(info.peer_addr, mac, 6);
  info.channel = LINK_CHANNEL;
  info.encrypt = false;
  esp_now_add_peer(&info);
}

/* 发一个包。前一个包还在等回执就不发，返回 false */
static bool sendPkt(const uint8_t *mac, uint8_t type, uint8_t s, const char *text, uint8_t len) {
  if (inflight) return false;
  LinkPkt p = {};
  p.magic = LINK_MAGIC;
  p.type  = type;
  p.seq   = s;
  p.len   = len;
  if (len) memcpy(p.text, text, len);
  inflight = type;
  inflightSince = millis();
  if (esp_now_send(mac, (const uint8_t *)&p, sizeof(p)) != ESP_OK) {
    inflight = 0;
    return false;
  }
  return true;
}

static void linkInit() {
  WiFi.mode(WIFI_STA);
  esp_wifi_set_ps(WIFI_PS_NONE);              /* 无线常开：反应快（这块板没有蓝牙，可以这么设） */
  esp_wifi_set_max_tx_power(78);              /* 19.5 dBm */
  esp_wifi_set_promiscuous(true);
  esp_wifi_set_channel(LINK_CHANNEL, WIFI_SECOND_CHAN_NONE);
  esp_wifi_set_promiscuous(false);

  if (esp_now_init() != ESP_OK) {
    Serial.println("[ESP-NOW] 初始化失败！");
    return;
  }
  esp_now_register_send_cb(onSent);
  esp_now_register_recv_cb(onRecv);
  addPeer(BCAST);

  prefs.begin("link", true);
  if (prefs.getBytesLength("peer") == 6) {
    prefs.getBytes("peer", peerMac, 6);
    paired = true;
    addPeer(peerMac);
    printMac("[配对] 已加载控制板 MAC：", peerMac);
  } else {
    Serial.println("[配对] 还没配对过，长按 BOOT 3 秒进入配对");
  }
  prefs.end();
  Serial.printf("[配对] 本机 MAC：%s\n", WiFi.macAddress().c_str());
}

/* ==========================================================
 * 配对
 * ========================================================== */
static void startPairing() {
  pairing = true;
  pairingSince = millis();
  lastPairReq = 0;
  gotPairAck = false;
  Serial.println("[配对] 进入配对模式，30 秒内把控制板也长按 BOOT 3 秒");
}

static void stopPairing(const char *why) {
  pairing = false;
  Serial.printf("[配对] %s，%s\n", why, paired ? "继续用原来的配对" : "现在还没有配对");
}

static void finishPairing(const uint8_t *mac) {
  if (paired && memcmp(mac, peerMac, 6) != 0) esp_now_del_peer(peerMac);
  memcpy(peerMac, mac, 6);
  addPeer(peerMac);
  prefs.begin("link", false);
  prefs.putBytes("peer", peerMac, 6);
  prefs.end();
  paired = true;
  pairing = false;
  lastAckMs = millis();
  printMac("[配对] 配对成功，控制板 MAC：", peerMac);
}

/* BOOT 按住满 3 秒触发一次；松手之前不会重复触发 */
static bool bootLongPressed() {
  static uint32_t downSince = 0;
  static bool fired = false;
  if (digitalRead(PIN_BOOT) == LOW) {
    if (downSince == 0) downSince = millis() | 1;
    if (!fired && millis() - downSince >= LINK_PAIR_HOLD_MS) {
      fired = true;
      return true;
    }
  } else {
    downSince = 0;
    fired = false;
  }
  return false;
}

static void pollPairing() {
  uint32_t now = millis();

  if (bootLongPressed()) {
    if (pairing) stopPairing("取消配对");
    else startPairing();
  }

  if (gotPairAck) {
    uint8_t mac[6];
    memcpy(mac, pairAckMac, 6);
    gotPairAck = false;
    if (pairing) finishPairing(mac);
  }

  if (!pairing) return;
  if (now - pairingSince >= LINK_PAIR_WINDOW_MS) {
    stopPairing("配对超时");
    return;
  }
  if (now - lastPairReq >= LINK_PAIR_REQ_MS && sendPkt(BCAST, LINK_PAIR_REQ, 0, nullptr, 0)) {
    lastPairReq = now;
  }
}

/* ==========================================================
 * 语音指令：串口收 -> 排队 -> 发给控制板
 * ========================================================== */
static void enqueueCmd(const char *text, uint8_t len) {
  if (qCount == CMD_QUEUE_LEN) {               /* 满了：丢最老的，新的更要紧 */
    qHead = (qHead + 1) % CMD_QUEUE_LEN;
    qCount--;
    tries = 0;
  }
  QueuedCmd &c = cmdQ[(qHead + qCount) % CMD_QUEUE_LEN];
  memcpy(c.text, text, len);
  c.len = len;
  c.at = millis();
  qCount++;
}

static void popCmd() {
  qHead = (qHead + 1) % CMD_QUEUE_LEN;
  qCount--;
  tries = 0;
  seq++;                                       /* 下一条指令换新序号 */
}

/* 一整行，比如 "$BMP:ON"。行首必须是 $，CI1302 开机时自己的打印一律丢掉 */
static void handleAsrLine(const char *line) {
  if (line[0] != '$') return;
  const char *text = line + 1;
  size_t len = strlen(text);
  if (len == 0 || len >= LINK_TEXT_MAX || strchr(text, ':') == nullptr) {
    Serial.printf("[语音] 格式不对，忽略：%s\n", line);
    return;
  }
  if (!paired) {
    Serial.printf("[语音] %s —— 还没配对，发不出去\n", line);
    return;
  }
  Serial.printf("[语音] 收到 %s，转发给控制板\n", line);
  enqueueCmd(text, (uint8_t)len);
}

/* 攒字节，攒到换行处理一行 —— 串口一帧可能分两次到，也可能两条粘在一起 */
static void pollAsr() {
  static char buf[48];
  static uint8_t n = 0;
  while (ASR.available()) {
    char c = (char)ASR.read();
    if (c == '\r') continue;
    if (c == '\n') {
      buf[n] = '\0';
      if (n > 0) handleAsrLine(buf);
      n = 0;
      continue;
    }
    if (c == '$') n = 0;                        /* 新指令开头：前面残缺的半截丢掉 */
    if (n < sizeof(buf) - 1) buf[n++] = c;
    else n = 0;                                 /* 超长 = 乱码，整行作废 */
  }
}

/* 调试用：USB 串口监视器里输入 APS:ON（或 $APS:ON）回车，
 * 和 CI1302 发来的走同一条路 —— 不用对着语音模块说话也能把整条链路测一遍。
 * 大小写都行，「换行和回车」怎么选都行。 */
static void pollUsb() {
  static char buf[48];
  static uint8_t n = 0;
  while (Serial.available()) {
    char c = (char)Serial.read();
    if (c == '\r' || c == '\n') {
      if (n > 0) {
        buf[n] = '\0';
        char line[50];
        snprintf(line, sizeof(line), buf[0] == '$' ? "%s" : "$%s", buf);
        for (char *p = line; *p; p++) *p = (char)toupper((unsigned char)*p);
        handleAsrLine(line);
      }
      n = 0;
      continue;
    }
    if (n < sizeof(buf) - 1) buf[n++] = c;
    else n = 0;
  }
}

/* 发队头那条指令；失败了隔一会儿重发，发够次数还不行就放弃 */
static void pumpCmds() {
  uint32_t now = millis();

  /* 回执到了：看是不是队头指令的 */
  if (resultReady) {
    resultReady = false;
    if (resultType == LINK_CMD && qCount > 0) {
      QueuedCmd &c = cmdQ[qHead];
      if (resultOk) {
        Serial.printf("[发送] %.*s 已送达（第 %u 次）\n", c.len, c.text, tries);
        popCmd();
      } else if (tries >= CMD_MAX_TRIES) {
        Serial.printf("[发送] %.*s 发了 %u 次都没送达，放弃（控制板没上电？）\n",
                      c.len, c.text, tries);
        popCmd();
      }
    }
  }

  /* 回调丢了的兜底：等太久就当这一包没了 */
  if (inflight && now - inflightSince > SEND_GUARD_MS) inflight = 0;

  if (pairing || !paired || inflight || qCount == 0) return;

  QueuedCmd &c = cmdQ[qHead];
  if (now - c.at > CMD_STALE_MS) {
    Serial.printf("[发送] %.*s 等太久了，丢掉\n", c.len, c.text);
    popCmd();
    return;
  }
  if (tries > 0 && now - lastTry < CMD_RETRY_GAP_MS) return;
  if (sendPkt(peerMac, LINK_CMD, seq, c.text, c.len)) {
    tries++;
    lastTry = now;
  }
}

/* 没有指令要发的时候，每秒一个心跳，控制板靠它知道语音板还在 */
static void pumpPing() {
  uint32_t now = millis();
  if (pairing || !paired || inflight || qCount > 0) return;
  if (now - lastPing < LINK_PING_MS) return;
  if (sendPkt(peerMac, LINK_PING, 0, nullptr, 0)) lastPing = now;
}

/* ==========================================================
 * 指示灯
 * ========================================================== */
static void updateLed(bool connected) {
  uint32_t now = millis();
  bool on;
  if (pairing)        on = (now / 100) % 2 == 0;   /* 配对中：快闪 */
  else if (connected) on = true;                   /* 连上：常亮 */
  else                on = (now / 500) % 2 == 0;   /* 没连上：慢闪 */
  digitalWrite(PIN_LED, on ? HIGH : LOW);
}

/* ==========================================================
 * setup / loop
 * ========================================================== */
void setup() {
  pinMode(PIN_LED, OUTPUT);
  digitalWrite(PIN_LED, LOW);
  pinMode(PIN_BOOT, INPUT_PULLUP);

  Serial.begin(115200);
  ASR.begin(ASR_BAUD, SERIAL_8N1, PIN_ASR_RX, PIN_ASR_TX);

  linkInit();
  seq = (uint8_t)esp_random();     /* 随机起点：重启后第一条指令不会撞上控制板记着的旧序号 */
  lastAckMs = millis() - LINK_TIMEOUT_MS;

  Serial.println("[init] 语音板启动完毕");
}

void loop() {
  pollPairing();
  pollAsr();
  pollUsb();                       /* 调试：串口监视器也能输指令 */
  pumpCmds();
  pumpPing();

  bool connected = paired && (millis() - lastAckMs < LINK_TIMEOUT_MS);
  updateLed(connected);

  /* 连接状态变化时打一行日志 */
  static bool wasConnected = false;
  if (connected != wasConnected) {
    wasConnected = connected;
    Serial.println(connected ? "[连接] 已连上控制板" : "[连接] 和控制板断开了");
  }

  delay(5);
}
