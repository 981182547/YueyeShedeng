/*
 * spotlight_link.h —— 语音板 <-> 控制板 的 ESP-NOW 协议
 *
 * 语音板和控制板的文件夹里各有一份，内容必须完全一样，改了要两边一起改。
 *
 * ── 配对 ─────────────────────────────────────────────────
 * 两块板都长按 BOOT 3 秒进入配对（灯快闪），30 秒内两边都按下就能配上：
 *   语音板每 500ms 广播一次 PAIR_REQ；
 *   控制板在配对模式下收到 PAIR_REQ，存下语音板 MAC，单播回 PAIR_ACK；
 *   语音板收到 PAIR_ACK，存下控制板 MAC。
 * 双方 MAC 存在 NVS 里当凭证，重新上电直接用。
 * 配对中再长按 3 秒是取消；取消或 30 秒超时，原来的配对原样保留 ——
 * 只有真正配上了，新 MAC 才覆盖旧的。
 *
 * ── 指令 ─────────────────────────────────────────────────
 * 语音板把 CI1302 串口发来的一行 "$BMP:ON" 去掉 $ 和换行，原样装进 CMD 包；
 * 控制板补回 $，交给原来解析语音串口的那段代码，所以语音代码和 App 都不用改。
 * 每条指令带一个序号，语音板发失败会重发，控制板 2 秒内见到同一个序号就丢掉。
 *
 * ── 连接状态 ─────────────────────────────────────────────
 * 语音板每 0.5 秒发一个 PING。控制板同时跑着手机蓝牙，C3 只有一个射频，
 * 轮到蓝牙的那一刻 ESP-NOW 收不到、也回不了应答 —— 所以心跳发得勤一点，
 * 3.5 秒里只要有一次成功就算连着，偶尔丢几个包不会把指示灯闪成断开。
 *   语音板：最近一次单播「发送成功」（ESP-NOW 自带硬件应答）在 3.5 秒内 = 连上
 *   控制板：最近一次收到语音板的包在 3.5 秒内 = 连上
 *
 * ── 指示灯（两块板一样）────────────────────────────────────
 *   配对中：快闪（亮 0.1 秒 灭 0.1 秒）
 *   连上了：常亮
 *   没配对 / 配了但没连上：慢闪（亮 0.5 秒 灭 0.5 秒）
 */
#pragma once

#include <stdint.h>
#include <esp_now.h>
#include <esp_idf_version.h>

#define LINK_CHANNEL         1        /* 两块板固定在同一个信道 */
#define LINK_MAGIC           0xA7     /* 包头，区分别的 ESP-NOW 设备（比如遥控小车） */
#define LINK_TEXT_MAX        24       /* 最长的指令 "ALL:PARTY_OFF" 才 13 个字符 */

#define LINK_PING_MS         500      /* 心跳间隔 */
#define LINK_TIMEOUT_MS      3500     /* 超过这么久没通上就算断开 */
#define LINK_PAIR_HOLD_MS    3000     /* BOOT 长按多久进入 / 取消配对 */
#define LINK_PAIR_WINDOW_MS  30000    /* 配对超时 */
#define LINK_PAIR_REQ_MS     500      /* 配对请求广播间隔 */

enum LinkType : uint8_t {
  LINK_PAIR_REQ = 1,   /* 语音板 -> 广播：我在配对 */
  LINK_PAIR_ACK = 2,   /* 控制板 -> 语音板：配上了 */
  LINK_CMD      = 3,   /* 语音板 -> 控制板：一条语音指令，text = "BMP:ON" */
  LINK_PING     = 4,   /* 语音板 -> 控制板：心跳 */
};

/* 每个包都按这个结构整包发，收到的时候先核对长度和包头 */
struct __attribute__((packed)) LinkPkt {
  uint8_t magic;               /* LINK_MAGIC */
  uint8_t type;                /* LinkType */
  uint8_t seq;                 /* CMD 的序号，重发时不变 */
  uint8_t len;                 /* text 里有效字符数 */
  char    text[LINK_TEXT_MAX]; /* 不带 $、不带换行，不保证以 \0 结尾 */
};

/* ── ESP-NOW 回调的写法在不同版本的 ESP32 核心里不一样 ─────────
 * 核心 3.3（IDF 5.5）起，发送回调的第一个参数改成了 wifi_tx_info_t；
 * 核心 3.0（IDF 5.0）起，接收回调改成了 esp_now_recv_info_t。
 * 用下面几个宏写回调，换核心版本也能编译。 */
#if ESP_IDF_VERSION >= ESP_IDF_VERSION_VAL(5, 5, 0)
  #define LINK_SEND_CB_ARGS  const wifi_tx_info_t *txInfo, esp_now_send_status_t status
#else
  #define LINK_SEND_CB_ARGS  const uint8_t *txMac, esp_now_send_status_t status
#endif

#if ESP_IDF_VERSION >= ESP_IDF_VERSION_VAL(5, 0, 0)
  #define LINK_RECV_CB_ARGS  const esp_now_recv_info_t *rxInfo, const uint8_t *data, int len
  #define LINK_RECV_SRC      (rxInfo->src_addr)
#else
  #define LINK_RECV_CB_ARGS  const uint8_t *rxMac, const uint8_t *data, int len
  #define LINK_RECV_SRC      (rxMac)
#endif
