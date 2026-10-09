/*
 * board_pins.h —— 两块板的引脚，对照最终版原理图核对过
 *
 * 用法：在 #include "board_pins.h" 之前定义 BOARD_VOICE 或 BOARD_CONTROL，
 * 两个都没定义（或者都定义了）会直接编译报错。
 *
 * 语音板和控制板的文件夹里各有一份，内容一模一样，改了要两边一起改。
 */
#pragma once

#if defined(BOARD_VOICE) && defined(BOARD_CONTROL)
  #error "BOARD_VOICE 和 BOARD_CONTROL 只能定义一个"

#elif defined(BOARD_VOICE)
  /* ── 语音板（驾驶室，电池供电）─────────────────────────
   * 空闲：0、4、5、6、7、20、21 */
  #define PIN_ASR_TX    2     /* ESP32 发 -> CI1302 RX */
  #define PIN_ASR_RX    3     /* ESP32 收 <- CI1302 TX */
  #define PIN_LED       10    /* 状态灯，高电平点亮 */
  #define PIN_BAT_ADC   1     /* 电池电压 = 读数 × 2；电源开关断开时读到 0（暂未使用） */
  #define PIN_BOOT      9     /* BOOT 键，按下为低；长按 3 秒配对 */
  /* USB：18 / 19 */

#elif defined(BOARD_CONTROL)
  /* ── 控制板（前舱，车上 12V 供电）─────────────────────
   * 空闲：0、1、3、10、20、21 */
  #define PIN_I2C_SDA   4     /* 板上 4.7k 上拉，可跑 400 kHz */
  #define PIN_I2C_SCL   5
  #define PIN_PCA_OE    6     /* 两片 PCA9685 的 OE，低电平使能；板上已上拉，上电默认关输出 */
  #define PIN_LED       7     /* 状态灯，高电平点亮 */
  #define PIN_BOOT      9     /* BOOT 键，按下为低；长按 3 秒配对 */
  /* USB：18 / 19 */

#else
  #error "请在 #include \"board_pins.h\" 之前定义 BOARD_VOICE 或 BOARD_CONTROL"
#endif
