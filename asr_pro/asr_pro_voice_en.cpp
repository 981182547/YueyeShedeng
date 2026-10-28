#include "asr.h"
extern "C"{ void * __dso_handle = 0 ;}
#include "setup.h"
#include "HardwareSerial.h"
#include "myLib/asr_event.h"

uint32_t snid;
void ASR_CODE();

//{speak:Dora-英语女声,vol:10,speed:10,platform:haohaodada}
//{playid:10001,voice:Welcome. Say hey aurora to wake me up.}
//{playid:10002,voice:Going to sleep. Say hey aurora to wake me up.}

/* ============================================================
 * 越野射灯 2.0 —— 语音命令【English · 数字编号版】，串口指令协议（115200）
 *
 * 按天问【英文模型】的模板写的：播报音是 Dora-英语女声，回复语用英文。
 * 说法用车图上的编号，数字读成英文单词（one ~ eight）。区分的词放在句首：
 *   open light N -> ON（白光）     close light N -> OFF
 *   daytime light N -> DRL          ambient light N -> AMB      strobe light N -> FLASH
 * 整组：open / close / daytime / ambient / strobe (/ dim) + main lights（1~4 号）
 *       或 auxiliary lights（5~8 号）；
 * 全车：start party mode / stop party mode / close all lights。
 *
 * 为什么不用 on / off：两个都是轻读的短词，说快了很容易互相认错；
 * 而且原来每条都是「light N 某个词」，前面全一样，只靠最后一个短词区分。
 * 现在每条开头的词就不一样，open / close 也比 on / off 好认得多。
 *
 * 中文版和英文版的 ID、串口指令完全一样，ESP32 固件不用区分装的是哪一版。
 *
 * 唤醒词：hey aurora，回复「I am here」。唤醒后才能执行灯光命令（和中文版的「小北同学」一样）。
 * ASR_CODE 中调用 set_state_enter_wakeup(10000)，每次识别后保持唤醒 10 秒，
 * 超时后休眠，再说「hey aurora」重新唤醒；不再设置永久唤醒。
 *
 * 每条指令一行：  $<灯组>:<动作>\r\n      例：$APD:DRL
 * 接收端按冒号拆成 灯组 + 动作 两段，各自【整串比对】，不能用 strstr。
 *
 *   编号 代码  灯组          分类
 *   1    BMP   前杠灯      主灯
 *   2    APD   A柱直射灯   主灯
 *   3    APS   A柱侧位灯   主灯
 *   4    ROF   顶灯        主灯
 *   5    BMI   前杠内侧灯  辅助灯
 *   6    BMO   前杠外侧灯  辅助灯
 *   7    RGT   右侧灯      辅助灯
 *   8    LFT   左侧灯      辅助灯
 *
 *   MAIN = 主灯 1~4 号    AUX = 辅助灯 5~8 号    ALL = 全车
 *
 * ID 编码：编号 x10 + 动作号
 *   单灯    N1 DRL   N2 AMB   N3 FLASH   N4 OFF   N5 ON   （N = 1~8）
 *   主灯    101 DRL  102 AMB  103 FLASH  104 OFF  105 ON  106 DIM
 *   辅助灯  111 DRL  112 AMB  113 FLASH  114 OFF  115 ON
 *   全车    121 PARTY  122 PARTY_OFF  123 OFF
 * ============================================================ */

/* 发一条指令。格式集中在这里，以后要改协议只改这一处 */
void sendCmd(const char *cmd) {
  Serial.print("$");
  Serial.print(cmd);
  Serial.print("\r\n");
}

/*描述该功能...
*/
void ASR_CODE(){
  //本函数是语音识别成功钩子程序
  //运行时间越短越好，复杂控制启动新线程运行
  //唤醒时间设置必须在 ASR_CODE 中才有效，单位为毫秒
  set_state_enter_wakeup(10000);

  switch (snid) {
    /* 唤醒词只唤醒语音模块，不下发灯光指令 */
    case 0: break;

    /* 1 号：前杠灯（主灯） */
    case 11:  sendCmd("BMP:DRL");       break;
    case 12:  sendCmd("BMP:AMB");       break;
    case 13:  sendCmd("BMP:FLASH");     break;
    case 14:  sendCmd("BMP:OFF");       break;
    case 15:  sendCmd("BMP:ON");        break;

    /* 2 号：A柱直射灯（主灯） */
    case 21:  sendCmd("APD:DRL");       break;
    case 22:  sendCmd("APD:AMB");       break;
    case 23:  sendCmd("APD:FLASH");     break;
    case 24:  sendCmd("APD:OFF");       break;
    case 25:  sendCmd("APD:ON");        break;

    /* 3 号：A柱侧位灯（主灯） */
    case 31:  sendCmd("APS:DRL");       break;
    case 32:  sendCmd("APS:AMB");       break;
    case 33:  sendCmd("APS:FLASH");     break;
    case 34:  sendCmd("APS:OFF");       break;
    case 35:  sendCmd("APS:ON");        break;

    /* 4 号：顶灯（主灯） */
    case 41:  sendCmd("ROF:DRL");       break;
    case 42:  sendCmd("ROF:AMB");       break;
    case 43:  sendCmd("ROF:FLASH");     break;
    case 44:  sendCmd("ROF:OFF");       break;
    case 45:  sendCmd("ROF:ON");        break;

    /* 5 号：前杠内侧灯（辅助灯） */
    case 51:  sendCmd("BMI:DRL");       break;
    case 52:  sendCmd("BMI:AMB");       break;
    case 53:  sendCmd("BMI:FLASH");     break;
    case 54:  sendCmd("BMI:OFF");       break;
    case 55:  sendCmd("BMI:ON");        break;

    /* 6 号：前杠外侧灯（辅助灯） */
    case 61:  sendCmd("BMO:DRL");       break;
    case 62:  sendCmd("BMO:AMB");       break;
    case 63:  sendCmd("BMO:FLASH");     break;
    case 64:  sendCmd("BMO:OFF");       break;
    case 65:  sendCmd("BMO:ON");        break;

    /* 7 号：右侧灯（辅助灯） */
    case 71:  sendCmd("RGT:DRL");       break;
    case 72:  sendCmd("RGT:AMB");       break;
    case 73:  sendCmd("RGT:FLASH");     break;
    case 74:  sendCmd("RGT:OFF");       break;
    case 75:  sendCmd("RGT:ON");        break;

    /* 8 号：左侧灯（辅助灯） */
    case 81:  sendCmd("LFT:DRL");       break;
    case 82:  sendCmd("LFT:AMB");       break;
    case 83:  sendCmd("LFT:FLASH");     break;
    case 84:  sendCmd("LFT:OFF");       break;
    case 85:  sendCmd("LFT:ON");        break;

    /* 主灯 1~4 号一起 */
    case 101: sendCmd("MAIN:DRL");      break;
    case 102: sendCmd("MAIN:AMB");      break;
    case 103: sendCmd("MAIN:FLASH");    break;
    case 104: sendCmd("MAIN:OFF");      break;
    case 105: sendCmd("MAIN:ON");       break;
    case 106: sendCmd("MAIN:DIM");      break;

    /* 辅助灯 5~8 号一起 */
    case 111: sendCmd("AUX:DRL");       break;
    case 112: sendCmd("AUX:AMB");       break;
    case 113: sendCmd("AUX:FLASH");     break;
    case 114: sendCmd("AUX:OFF");       break;
    case 115: sendCmd("AUX:ON");        break;

    /* 全车 */
    case 121: sendCmd("ALL:PARTY");     break;
    case 122: sendCmd("ALL:PARTY_OFF"); break;
    case 123: sendCmd("ALL:OFF");       break;

    default: break;
  }
}

void hardware_init(){
  //需要操作系统启动后初始化的内容
  //音量范围1-7
  vol_set(7);
  vTaskDelete(NULL);
}

void setup()
{
  setPinFun(13,SECOND_FUNCTION);
  setPinFun(14,SECOND_FUNCTION);
  Serial.begin(115200);
  //需要操作系统启动前初始化的内容
  //播报音下拉菜单可以选择，合成音量是指TTS生成文件的音量
  //欢迎词指开机提示音，可以为空
  //退出语音是指休眠时提示音，可以为空
  //休眠后先用唤醒词唤醒，再执行命令。ID 范围为 0-9999
  //{ID:0,keyword:"唤醒词",ASR:"hey aurora",ASRTO:"I am here"}
  //{ID:11,keyword:"命令词",ASR:"daytime light one",ASRTO:"OK, daytime light one"}
  //{ID:12,keyword:"命令词",ASR:"ambient light one",ASRTO:"OK, ambient light one"}
  //{ID:13,keyword:"命令词",ASR:"strobe light one",ASRTO:"OK, strobe light one"}
  //{ID:14,keyword:"命令词",ASR:"close light one",ASRTO:"OK, close light one"}
  //{ID:15,keyword:"命令词",ASR:"open light one",ASRTO:"OK, open light one"}
  //{ID:21,keyword:"命令词",ASR:"daytime light two",ASRTO:"OK, daytime light two"}
  //{ID:22,keyword:"命令词",ASR:"ambient light two",ASRTO:"OK, ambient light two"}
  //{ID:23,keyword:"命令词",ASR:"strobe light two",ASRTO:"OK, strobe light two"}
  //{ID:24,keyword:"命令词",ASR:"close light two",ASRTO:"OK, close light two"}
  //{ID:25,keyword:"命令词",ASR:"open light two",ASRTO:"OK, open light two"}
  //{ID:31,keyword:"命令词",ASR:"daytime light three",ASRTO:"OK, daytime light three"}
  //{ID:32,keyword:"命令词",ASR:"ambient light three",ASRTO:"OK, ambient light three"}
  //{ID:33,keyword:"命令词",ASR:"strobe light three",ASRTO:"OK, strobe light three"}
  //{ID:34,keyword:"命令词",ASR:"close light three",ASRTO:"OK, close light three"}
  //{ID:35,keyword:"命令词",ASR:"open light three",ASRTO:"OK, open light three"}
  //{ID:41,keyword:"命令词",ASR:"daytime light four",ASRTO:"OK, daytime light four"}
  //{ID:42,keyword:"命令词",ASR:"ambient light four",ASRTO:"OK, ambient light four"}
  //{ID:43,keyword:"命令词",ASR:"strobe light four",ASRTO:"OK, strobe light four"}
  //{ID:44,keyword:"命令词",ASR:"close light four",ASRTO:"OK, close light four"}
  //{ID:45,keyword:"命令词",ASR:"open light four",ASRTO:"OK, open light four"}
  //{ID:51,keyword:"命令词",ASR:"daytime light five",ASRTO:"OK, daytime light five"}
  //{ID:52,keyword:"命令词",ASR:"ambient light five",ASRTO:"OK, ambient light five"}
  //{ID:53,keyword:"命令词",ASR:"strobe light five",ASRTO:"OK, strobe light five"}
  //{ID:54,keyword:"命令词",ASR:"close light five",ASRTO:"OK, close light five"}
  //{ID:55,keyword:"命令词",ASR:"open light five",ASRTO:"OK, open light five"}
  //{ID:61,keyword:"命令词",ASR:"daytime light six",ASRTO:"OK, daytime light six"}
  //{ID:62,keyword:"命令词",ASR:"ambient light six",ASRTO:"OK, ambient light six"}
  //{ID:63,keyword:"命令词",ASR:"strobe light six",ASRTO:"OK, strobe light six"}
  //{ID:64,keyword:"命令词",ASR:"close light six",ASRTO:"OK, close light six"}
  //{ID:65,keyword:"命令词",ASR:"open light six",ASRTO:"OK, open light six"}
  //{ID:71,keyword:"命令词",ASR:"daytime light seven",ASRTO:"OK, daytime light seven"}
  //{ID:72,keyword:"命令词",ASR:"ambient light seven",ASRTO:"OK, ambient light seven"}
  //{ID:73,keyword:"命令词",ASR:"strobe light seven",ASRTO:"OK, strobe light seven"}
  //{ID:74,keyword:"命令词",ASR:"close light seven",ASRTO:"OK, close light seven"}
  //{ID:75,keyword:"命令词",ASR:"open light seven",ASRTO:"OK, open light seven"}
  //{ID:81,keyword:"命令词",ASR:"daytime light eight",ASRTO:"OK, daytime light eight"}
  //{ID:82,keyword:"命令词",ASR:"ambient light eight",ASRTO:"OK, ambient light eight"}
  //{ID:83,keyword:"命令词",ASR:"strobe light eight",ASRTO:"OK, strobe light eight"}
  //{ID:84,keyword:"命令词",ASR:"close light eight",ASRTO:"OK, close light eight"}
  //{ID:85,keyword:"命令词",ASR:"open light eight",ASRTO:"OK, open light eight"}
  //{ID:101,keyword:"命令词",ASR:"daytime main lights",ASRTO:"OK, daytime main lights"}
  //{ID:102,keyword:"命令词",ASR:"ambient main lights",ASRTO:"OK, ambient main lights"}
  //{ID:103,keyword:"命令词",ASR:"strobe main lights",ASRTO:"OK, strobe main lights"}
  //{ID:104,keyword:"命令词",ASR:"close main lights",ASRTO:"OK, close main lights"}
  //{ID:105,keyword:"命令词",ASR:"open main lights",ASRTO:"OK, open main lights"}
  //{ID:106,keyword:"命令词",ASR:"dim main lights",ASRTO:"OK, dim main lights"}
  //{ID:111,keyword:"命令词",ASR:"daytime auxiliary lights",ASRTO:"OK, daytime auxiliary lights"}
  //{ID:112,keyword:"命令词",ASR:"ambient auxiliary lights",ASRTO:"OK, ambient auxiliary lights"}
  //{ID:113,keyword:"命令词",ASR:"strobe auxiliary lights",ASRTO:"OK, strobe auxiliary lights"}
  //{ID:114,keyword:"命令词",ASR:"close auxiliary lights",ASRTO:"OK, close auxiliary lights"}
  //{ID:115,keyword:"命令词",ASR:"open auxiliary lights",ASRTO:"OK, open auxiliary lights"}
  //{ID:121,keyword:"命令词",ASR:"start party mode",ASRTO:"OK, start party mode"}
  //{ID:122,keyword:"命令词",ASR:"stop party mode",ASRTO:"OK, stop party mode"}
  //{ID:123,keyword:"命令词",ASR:"close all lights",ASRTO:"OK, close all lights"}
  setPinFun(4,FIRST_FUNCTION);
  pinMode(4,output);
  digitalWrite(4,0);   // 上电先拉低，保证开机时灯是灭的
}
