#include "asr.h"
extern "C"{ void * __dso_handle = 0 ;}
#include "setup.h"
#include "HardwareSerial.h"
#include "myLib/asr_event.h"   // set_wakeup_forever() 在这里面，不能删

uint32_t snid;
void ASR_CODE();

//{speak:Dora-英语女声,vol:10,speed:10,platform:haohaodada}
//{playid:10001,voice:}
//{playid:10002,voice:}

/* ============================================================
 * 越野射灯 2.0 —— 语音命令【English · 数字编号版】，串口指令协议（115200）
 *
 * 按天问【英文模型】的模板写的：播报音是 Dora-英语女声，回复语用英文。
 * 模板里的唤醒词「天问五幺」和 set_state_enter_wakeup(10000) 都去掉了（见下面说明），
 * 欢迎词 / 退出语留空 —— 模板里那两句说的是「用天问五幺唤醒我」，已经对不上了。
 * 说法用车图上的编号，数字读成英文单词（one ~ eight）：
 *   light N on -> ON（白光）   light N daytime -> DRL   light N ambient -> AMB
 *   light N strobe -> FLASH    light N off -> OFF
 * 整组：main lights ...（1~4 号）、aux lights ...（5~8 号）；
 * 全车：party mode on / party mode off / all lights off。
 * 如果平台提示 aux 不认识，把 aux 换成 auxiliary 就行。
 *
 * 中文版和英文版的 ID、串口指令完全一样，ESP32 固件不用区分装的是哪一版。
 *
 * 不用唤醒词：hardware_init 里 set_wakeup_forever() 让模块一直处于唤醒状态，
 * 直接说命令就行。ASR_CODE 里【不要】再调 set_state_enter_wakeup() ——
 * 它会把唤醒时间改回几秒，时间一到模块就休眠，没有唤醒词就再也叫不醒了。
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
  //这里不设唤醒时间：模块是永久唤醒的，见文件头说明

  switch (snid) {
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
  set_wakeup_forever();   // 永久唤醒：不用唤醒词，直接说命令
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
  //不用唤醒词：模块永久唤醒（见 hardware_init），直接说命令。回复语可以空。ID范围为0-9999
  //{ID:11,keyword:"命令词",ASR:"light one daytime",ASRTO:"OK, light one daytime"}
  //{ID:12,keyword:"命令词",ASR:"light one ambient",ASRTO:"OK, light one ambient"}
  //{ID:13,keyword:"命令词",ASR:"light one strobe",ASRTO:"OK, light one strobe"}
  //{ID:14,keyword:"命令词",ASR:"light one off",ASRTO:"OK, light one off"}
  //{ID:15,keyword:"命令词",ASR:"light one on",ASRTO:"OK, light one on"}
  //{ID:21,keyword:"命令词",ASR:"light two daytime",ASRTO:"OK, light two daytime"}
  //{ID:22,keyword:"命令词",ASR:"light two ambient",ASRTO:"OK, light two ambient"}
  //{ID:23,keyword:"命令词",ASR:"light two strobe",ASRTO:"OK, light two strobe"}
  //{ID:24,keyword:"命令词",ASR:"light two off",ASRTO:"OK, light two off"}
  //{ID:25,keyword:"命令词",ASR:"light two on",ASRTO:"OK, light two on"}
  //{ID:31,keyword:"命令词",ASR:"light three daytime",ASRTO:"OK, light three daytime"}
  //{ID:32,keyword:"命令词",ASR:"light three ambient",ASRTO:"OK, light three ambient"}
  //{ID:33,keyword:"命令词",ASR:"light three strobe",ASRTO:"OK, light three strobe"}
  //{ID:34,keyword:"命令词",ASR:"light three off",ASRTO:"OK, light three off"}
  //{ID:35,keyword:"命令词",ASR:"light three on",ASRTO:"OK, light three on"}
  //{ID:41,keyword:"命令词",ASR:"light four daytime",ASRTO:"OK, light four daytime"}
  //{ID:42,keyword:"命令词",ASR:"light four ambient",ASRTO:"OK, light four ambient"}
  //{ID:43,keyword:"命令词",ASR:"light four strobe",ASRTO:"OK, light four strobe"}
  //{ID:44,keyword:"命令词",ASR:"light four off",ASRTO:"OK, light four off"}
  //{ID:45,keyword:"命令词",ASR:"light four on",ASRTO:"OK, light four on"}
  //{ID:51,keyword:"命令词",ASR:"light five daytime",ASRTO:"OK, light five daytime"}
  //{ID:52,keyword:"命令词",ASR:"light five ambient",ASRTO:"OK, light five ambient"}
  //{ID:53,keyword:"命令词",ASR:"light five strobe",ASRTO:"OK, light five strobe"}
  //{ID:54,keyword:"命令词",ASR:"light five off",ASRTO:"OK, light five off"}
  //{ID:55,keyword:"命令词",ASR:"light five on",ASRTO:"OK, light five on"}
  //{ID:61,keyword:"命令词",ASR:"light six daytime",ASRTO:"OK, light six daytime"}
  //{ID:62,keyword:"命令词",ASR:"light six ambient",ASRTO:"OK, light six ambient"}
  //{ID:63,keyword:"命令词",ASR:"light six strobe",ASRTO:"OK, light six strobe"}
  //{ID:64,keyword:"命令词",ASR:"light six off",ASRTO:"OK, light six off"}
  //{ID:65,keyword:"命令词",ASR:"light six on",ASRTO:"OK, light six on"}
  //{ID:71,keyword:"命令词",ASR:"light seven daytime",ASRTO:"OK, light seven daytime"}
  //{ID:72,keyword:"命令词",ASR:"light seven ambient",ASRTO:"OK, light seven ambient"}
  //{ID:73,keyword:"命令词",ASR:"light seven strobe",ASRTO:"OK, light seven strobe"}
  //{ID:74,keyword:"命令词",ASR:"light seven off",ASRTO:"OK, light seven off"}
  //{ID:75,keyword:"命令词",ASR:"light seven on",ASRTO:"OK, light seven on"}
  //{ID:81,keyword:"命令词",ASR:"light eight daytime",ASRTO:"OK, light eight daytime"}
  //{ID:82,keyword:"命令词",ASR:"light eight ambient",ASRTO:"OK, light eight ambient"}
  //{ID:83,keyword:"命令词",ASR:"light eight strobe",ASRTO:"OK, light eight strobe"}
  //{ID:84,keyword:"命令词",ASR:"light eight off",ASRTO:"OK, light eight off"}
  //{ID:85,keyword:"命令词",ASR:"light eight on",ASRTO:"OK, light eight on"}
  //{ID:101,keyword:"命令词",ASR:"main lights daytime",ASRTO:"OK, main lights daytime"}
  //{ID:102,keyword:"命令词",ASR:"main lights ambient",ASRTO:"OK, main lights ambient"}
  //{ID:103,keyword:"命令词",ASR:"main lights strobe",ASRTO:"OK, main lights strobe"}
  //{ID:104,keyword:"命令词",ASR:"main lights off",ASRTO:"OK, main lights off"}
  //{ID:105,keyword:"命令词",ASR:"main lights on",ASRTO:"OK, main lights on"}
  //{ID:106,keyword:"命令词",ASR:"main lights dim",ASRTO:"OK, main lights dim"}
  //{ID:111,keyword:"命令词",ASR:"aux lights daytime",ASRTO:"OK, aux lights daytime"}
  //{ID:112,keyword:"命令词",ASR:"aux lights ambient",ASRTO:"OK, aux lights ambient"}
  //{ID:113,keyword:"命令词",ASR:"aux lights strobe",ASRTO:"OK, aux lights strobe"}
  //{ID:114,keyword:"命令词",ASR:"aux lights off",ASRTO:"OK, aux lights off"}
  //{ID:115,keyword:"命令词",ASR:"aux lights on",ASRTO:"OK, aux lights on"}
  //{ID:121,keyword:"命令词",ASR:"party mode on",ASRTO:"OK, party mode on"}
  //{ID:122,keyword:"命令词",ASR:"party mode off",ASRTO:"OK, party mode off"}
  //{ID:123,keyword:"命令词",ASR:"all lights off",ASRTO:"OK, all lights off"}
  setPinFun(4,FIRST_FUNCTION);
  pinMode(4,output);
  digitalWrite(4,0);   // 上电先拉低，保证开机时灯是灭的
}
