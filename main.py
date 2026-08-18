'''
实验名称：智能AI越野射灯系统 - 最终完整版 (AI + 语音 + 光敏自动大灯 + 雨水自动黄光 + 爆闪)
'''

from libs.PipeLine import PipeLine, ScopedTiming
from libs.AIBase import AIBase
from libs.AI2D import Ai2d
import os
import ujson
from media.media import *
from media.sensor import *
from time import *
import nncase_runtime as nn
import ulab.numpy as np
import time
import utime
import image
import random
import gc
import sys
import aidemo

# 新增了 Pin，用于读取 GPIO 数字电平
from machine import UART, PWM, FPIOA, Pin

PERSON_IDX = 0
VEHICLE_IDXS = [2, 3, 5, 7]
TRAFFIC_LIGHT_IDX = 9

# ============================================================
# 外设初始化：UART2 + PWM双路 + 光敏(46) + 雨水(47)
# ============================================================

def init_peripherals(uart_baudrate=115200, pwm_freq=1000):
    fpioa = FPIOA()

    # 串口2 (语音)
    fpioa.set_function(11, FPIOA.UART2_TXD)
    fpioa.set_function(12, FPIOA.UART2_RXD)
    uart = UART(UART.UART2, uart_baudrate)

    # PWM 灯光控制
    fpioa.set_function(42, FPIOA.PWM0)
    fpioa.set_function(43, FPIOA.PWM1)
    pwm0 = PWM(0, freq=pwm_freq, duty=0)
    pwm1 = PWM(1, freq=pwm_freq, duty=0)

    # 光敏传感器 (IO46)
    fpioa.set_function(46, FPIOA.GPIO46)
    light_sensor = Pin(46, Pin.IN, Pin.PULL_UP)

    # 雨水传感器 (IO47)
    fpioa.set_function(47, FPIOA.GPIO47)
    rain_sensor = Pin(47, Pin.IN, Pin.PULL_UP)

    return uart, pwm0, pwm1, light_sensor, rain_sensor

def pwm_set(pwm, duty_percent, freq=None, enable=True):
    if freq is not None:
        pwm.freq(freq)
    if enable:
        pwm.duty(duty_percent)
    else:
        pwm.duty(0)

def uart_read_cmd(uart):
    data = uart.read(128)
    if data is not None and len(data) > 0:
        try:
            return data.decode('utf-8').strip().upper()
        except Exception:
            return None
    return None

def calculate_headlight_duty(parsed_dets, scene, frame_width=224, frame_height=224):
    HIGH_BEAM = 100   # 郊区晚上 无人无车
    MEET_BEAM = 50    # 会车 / 行人
    CITY_BEAM = 20    # 城市

    if scene == "Urban":
        return CITY_BEAM, "Urban Area (City 20%)"

    for d in parsed_dets:
        cat = d['category']
        x, y, w, h = d['x'], d['y'], d['w'], d['h']
        cx = x + w / 2
        cy = y + h / 2
        area = w * h

        if cat == 'person':
            return MEET_BEAM, "Pedestrian Detected (50%)"

        if cat == 'vehicle':
            if cx < (frame_width / 2):
                return MEET_BEAM, "Oncoming Vehicle (50%)"

            is_center = (frame_width * 0.33) < cx < (frame_width * 0.67)
            is_bottom = cy > (frame_height * 0.5)
            is_large = area > (frame_width * frame_height * 0.08)

            if is_center and is_bottom and is_large:
                return 70, "Following Vehicle (70%)"

    return HIGH_BEAM, "Clear Suburb (High Beam 100%)"

# ============================================================
# 自定义YOLOv8检测类与场景判断器
# ============================================================
class ObjectDetectionApp(AIBase):
    def __init__(self,kmodel_path,labels,model_input_size,max_boxes_num,confidence_threshold=0.5,nms_threshold=0.2,rgb888p_size=[224,224],display_size=[1920,1080],debug_mode=0):
        super().__init__(kmodel_path,model_input_size,rgb888p_size,debug_mode)
        self.kmodel_path=kmodel_path
        self.labels=labels
        self.model_input_size=model_input_size
        self.confidence_threshold=confidence_threshold
        self.nms_threshold=nms_threshold
        self.max_boxes_num=max_boxes_num
        self.rgb888p_size=[ALIGN_UP(rgb888p_size[0],16),rgb888p_size[1]]
        self.display_size=[ALIGN_UP(display_size[0],16),display_size[1]]
        self.debug_mode=debug_mode
        self.x_factor = float(self.rgb888p_size[0])/self.model_input_size[0]
        self.y_factor = float(self.rgb888p_size[1])/self.model_input_size[1]
        self.ai2d=Ai2d(debug_mode)
        self.ai2d.set_ai2d_dtype(nn.ai2d_format.NCHW_FMT,nn.ai2d_format.NCHW_FMT,np.uint8, np.uint8)

    def config_preprocess(self,input_image_size=None):
        with ScopedTiming("set preprocess config",self.debug_mode > 0):
            ai2d_input_size=input_image_size if input_image_size else self.rgb888p_size
            self.ai2d.resize(nn.interp_method.tf_bilinear, nn.interp_mode.half_pixel)
            self.ai2d.build([1,3,ai2d_input_size[1],ai2d_input_size[0]],[1,3,self.model_input_size[1],self.model_input_size[0]])

    def postprocess(self,results):
        with ScopedTiming("postprocess",self.debug_mode > 0):
            result=results[0]
            result = result.reshape((result.shape[0] * result.shape[1], result.shape[2]))
            output_data = result.transpose()
            boxes_ori = output_data[:,0:4]
            scores_ori = output_data[:,4:]
            confs_ori = np.max(scores_ori,axis=-1)
            inds_ori = np.argmax(scores_ori,axis=-1)
            boxes,scores,inds = [],[],[]
            for i in range(len(boxes_ori)):
                if confs_ori[i] > self.confidence_threshold:
                    scores.append(confs_ori[i])
                    inds.append(inds_ori[i])
                    x = boxes_ori[i,0]
                    y = boxes_ori[i,1]
                    w = boxes_ori[i,2]
                    h = boxes_ori[i,3]
                    left = int((x - 0.5 * w) * self.x_factor)
                    top = int((y - 0.5 * h) * self.y_factor)
                    right = int((x + 0.5 * w) * self.x_factor)
                    bottom = int((y + 0.5 * h) * self.y_factor)
                    boxes.append([left,top,right,bottom])
            if len(boxes)==0:
                return []
            boxes = np.array(boxes)
            scores = np.array(scores)
            inds = np.array(inds)
            keep = self.nms(boxes,scores,self.nms_threshold)
            dets = np.concatenate((boxes, scores.reshape((len(boxes),1)), inds.reshape((len(boxes),1))), axis=1)
            dets_out = []
            for keep_i in keep:
                dets_out.append(dets[keep_i])
            dets_out = np.array(dets_out)
            dets_out = dets_out[:self.max_boxes_num, :]
            return dets_out

    def parse_detections(self, dets):
        parsed = []
        if len(dets) == 0:
            return parsed
        for det in dets:
            cls_id = int(det[5])
            if cls_id == PERSON_IDX:
                cat = "person"
            elif cls_id in VEHICLE_IDXS:
                cat = "vehicle"
            elif cls_id == TRAFFIC_LIGHT_IDX:
                cat = "traffic_light"
            else:
                continue
            x1, y1, x2, y2 = int(det[0]), int(det[1]), int(det[2]), int(det[3])
            parsed.append({
                "category": cat,
                "raw_label": self.labels[cls_id],
                "confidence": round(float(det[4]), 2),
                "x": x1, "y": y1,
                "w": x2 - x1, "h": y2 - y1
            })
        return parsed

    def nms(self,boxes,scores,thresh):
        x1,y1,x2,y2 = boxes[:, 0],boxes[:, 1],boxes[:, 2],boxes[:, 3]
        areas = (x2 - x1 + 1) * (y2 - y1 + 1)
        order = np.argsort(scores,axis = 0)[::-1]
        keep = []
        while order.size > 0:
            i = order[0]
            keep.append(i)
            new_x1,new_y1,new_x2,new_y2,new_areas = [],[],[],[],[]
            for order_i in order:
                new_x1.append(x1[order_i])
                new_x2.append(x2[order_i])
                new_y1.append(y1[order_i])
                new_y2.append(y2[order_i])
                new_areas.append(areas[order_i])
            new_x1 = np.array(new_x1)
            new_x2 = np.array(new_x2)
            new_y1 = np.array(new_y1)
            new_y2 = np.array(new_y2)
            xx1 = np.maximum(x1[i], new_x1)
            yy1 = np.maximum(y1[i], new_y1)
            xx2 = np.minimum(x2[i], new_x2)
            yy2 = np.minimum(y2[i], new_y2)
            w = np.maximum(0.0, xx2 - xx1 + 1)
            h = np.maximum(0.0, yy2 - yy1 + 1)
            inter = w * h
            new_areas = np.array(new_areas)
            ovr = inter / (areas[i] + new_areas - inter)
            new_order = []
            for ovr_i,ind in enumerate(ovr):
                if ind < thresh:
                    new_order.append(order[ovr_i])
            order = np.array(new_order,dtype=np.uint8)
        return keep

class SceneClassifier:
    def __init__(self, window=10, urban_vehicle_thresh=2, urban_person_thresh=3):
        self.window = window
        self.urban_vehicle_thresh = urban_vehicle_thresh
        self.urban_person_thresh = urban_person_thresh
        self.history = []

    def update(self, parsed_dets):
        n_p = 0; n_v = 0; n_t = 0
        for d in parsed_dets:
            if d["category"] == "person": n_p += 1
            elif d["category"] == "vehicle": n_v += 1
            elif d["category"] == "traffic_light": n_t += 1
        self.history.append((n_p, n_v, n_t))
        if len(self.history) > self.window:
            self.history.pop(0)

    def classify(self):
        if len(self.history) == 0:
            return "Unknown", 0.0, 0.0, 0
        avg_p = sum(h[0] for h in self.history) / len(self.history)
        avg_v = sum(h[1] for h in self.history) / len(self.history)
        sum_t = sum(h[2] for h in self.history)
        is_urban = (sum_t > 0) or (avg_v >= self.urban_vehicle_thresh) or (avg_p >= self.urban_person_thresh)
        scene = "Urban" if is_urban else "Suburb"
        return scene, avg_p, avg_v, sum_t


# ============================================================
# 主函数运行区
# ============================================================
if __name__=="__main__":

    display="lcd2_4"
    if display=="hdmi":
        display_mode='hdmi'
        display_size=[1920,1080]
    elif display=="lcd3_5":
        display_mode= 'st7701'
        display_size=[800,480]
    elif display=="lcd2_4":
        display_mode= 'st7701'
        display_size=[640,480]

    rgb888p_size=[224,224]
    kmodel_path="/sdcard/examples/kmodel/yolov8n_224.kmodel"
    labels = ["person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat",
              "traffic light", "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat",
              "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe", "backpack",
              "umbrella", "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball",
              "kite", "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket",
              "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
              "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake",
              "chair", "couch", "potted plant", "bed", "dining table", "toilet", "tv", "laptop",
              "mouse", "remote", "keyboard", "cell phone", "microwave", "oven", "toaster", "sink",
              "refrigerator", "book", "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush"]

    confidence_threshold = 0.4
    nms_threshold = 0.45
    max_boxes_num = 30

    pl=PipeLine(rgb888p_size=rgb888p_size,display_size=display_size,display_mode=display_mode)
    if display == "lcd2_4":
         pl.create(Sensor(id=0, width=1280, height=960))
    else:
         pl.create(Sensor(id=0, width=1920, height=1080))
    ob_det = ObjectDetectionApp(
        kmodel_path, labels=labels, model_input_size=[224,224], max_boxes_num=max_boxes_num,
        confidence_threshold=confidence_threshold, nms_threshold=nms_threshold,
        rgb888p_size=rgb888p_size, display_size=display_size, debug_mode=0
    )
    ob_det.config_preprocess()
    scene_clf = SceneClassifier(window=10, urban_vehicle_thresh=2, urban_person_thresh=3)

    # =============== 硬件与状态初始化 ===============
    uart, pwm0, pwm1, light_sensor, rain_sensor = init_peripherals(115200, 1000)
    print("[init] 系统启动完毕")

    clock = time.clock()

    current_white_duty = 0.0
    current_red_duty = 0.0
    smoothing_factor = 0.15

    # 新增 MODE_FLASH 状态常量
    MODE_AUTO = 0
    MODE_MANUAL = 1
    MODE_FLASH = 2
    sys_mode = MODE_AUTO

    active_light = "WHITE"
    manual_intensity = 0.0

    # 爆闪专用的节奏表与非阻塞计时变量
    # 格式: (持续时间ms, 目标亮度%)
    FLASH_PATTERN = [
        (50, 100), (50, 0), (50, 100), (50, 0), (50, 100), (300, 0)
    ]
    flash_idx = 0
    last_flash_time = utime.ticks_ms()

    # 用于边缘检测的历史状态 (假设开机时天亮、没下雨)
    last_rain_state = 1

    while True:
        clock.tick()
        img = pl.get_frame()

        # =============== 0. 传感器状态轮询 ===============
        # 光敏传感器 (IO46): 0=有光(白天), 1=无光(黑夜)
        current_light = light_sensor.value()

        # 雨水传感器 (IO47): 0=下雨, 1=干燥
        current_rain = rain_sensor.value()

        # 雨滴边沿检测：自动拨动颜色通道，但不抢夺系统模式控制权
        if current_rain == 0 and last_rain_state == 1:
            active_light = "RED"
            print(">> [Sensor] 检测到下雨，自动拨至黄/红光通道穿透雨雾")
        elif current_rain == 1 and last_rain_state == 0:
            active_light = "WHITE"
            print(">> [Sensor] 雨停，自动拨回白光通道")
        last_rain_state = current_rain


        # =============== 1. 处理接收到的串口透传指令 ===============
        cmd = uart_read_cmd(uart)
        if cmd:
            print(f"\n[BLE Command] 收到语音指令: {cmd}")

            # 状态机判定：通道修改 (切通道时，如果处于爆闪模式，则退出并恢复自动)
            if "WHT" in cmd:
                active_light = "WHITE"
                if sys_mode == MODE_FLASH: sys_mode = MODE_AUTO
                print(f">> [Voice] 通道切换: 记忆白光")
            elif "YEL" in cmd or "RED" in cmd:
                active_light = "RED"
                if sys_mode == MODE_FLASH: sys_mode = MODE_AUTO
                print(f">> [Voice] 通道切换: 记忆红/黄光")
                
            # 新增爆闪判定
            elif "BLBL" in cmd or "BL" in cmd:
                # 只有在非爆闪状态下收到指令才重置节奏，防止重复指令卡死
                if sys_mode != MODE_FLASH:
                    sys_mode = MODE_FLASH
                    flash_idx = 0
                    last_flash_time = utime.ticks_ms()
                print(">> [Voice] 模式切换: 爆闪")

            # 状态机判定：模式/亮度修改
            elif "AUTO" in cmd:
                sys_mode = MODE_AUTO
                print(f">> [Voice] 模式切换: 自动模式 (AI 重新接管)")
            elif "OFF" in cmd:
                sys_mode = MODE_MANUAL
                manual_intensity = 0.0
                print(">> [Voice] 模式切换: 手动关闭")
            elif "ON" in cmd:
                sys_mode = MODE_MANUAL
                manual_intensity = 100.0
                print(f">> [Voice] 模式切换: 手动开启")
            elif "DRL" in cmd:
                sys_mode = MODE_MANUAL
                manual_intensity = 10.0  # 日行灯手动模式亮度修改为 10%
                print(f">> [Voice] 模式切换: 日行灯模式 (10%)")


        # =============== 2. 仲裁与 AI 逻辑 (计算并输出目标亮度) ===============
        
        # 【爆闪模式】：直接查节奏表，跳过后续所有 AI 运算与平滑渐变
        if sys_mode == MODE_FLASH:
            scene_text = "Scene: [Flash Mode Active]"
            reason = "Voice Override (Flash)"
            
            # 非阻塞获取当前时间并对比
            now_ms = utime.ticks_ms()
            step_duration, step_duty = FLASH_PATTERN[flash_idx]
            
            # 达到阶段时长，切换到下一个闪烁步骤
            if utime.ticks_diff(now_ms, last_flash_time) >= step_duration:
                last_flash_time = now_ms
                flash_idx = (flash_idx + 1) % len(FLASH_PATTERN)
                step_duration, step_duty = FLASH_PATTERN[flash_idx]
                
            # 爆闪直接硬切赋值，且只给激活通道供电，跳过渐变系数
            if active_light == "WHITE":
                current_white_duty = float(step_duty)
                current_red_duty = 0.0
            else:
                current_white_duty = 0.0
                current_red_duty = float(step_duty)
                
            # 同步 Target 变量以供日志打印
            target_white_duty = current_white_duty
            target_red_duty = current_red_duty
            
        # 【自动 / 手动常规模式】
        else:
            if sys_mode == MODE_AUTO:
    
                if current_light == 0:
                    # 【白天模式】：光敏读到0，固定10%亮度，跳过AI节省算力
                    scene_text = "Scene: [Daytime - 10%]"
                    parsed = []
                    base_target_duty = 10.0
                    reason = "Light Sensor (Daytime 10%)"
    
                else:
                    # 【黑夜模式】：光敏读到1，启动 AI 防眩目大灯
                    res = ob_det.run(img)
                    parsed = ob_det.parse_detections(res)
                    scene_clf.update(parsed)
                    scene, avg_p, avg_v, sum_t = scene_clf.classify()
                    scene_text = "Scene: " + scene + " (P:%.1f V:%.1f TL:%d)" % (avg_p, avg_v, sum_t)
    
                    # AI 算出当前需要的亮度级别 (高亮100 或 近光30)
                    base_target_duty, reason = calculate_headlight_duty(parsed, scene, frame_width=224, frame_height=224)
    
            else:
                # 【语音手动模式】：跳过光敏和AI
                scene_text = "Scene: [Disabled by Voice Control]"
                parsed = []
                base_target_duty = manual_intensity
                reason = "Voice Override"
    
    
            # =============== 3. 路由与平滑输出 ===============
            # 【路由核心】：无论基准亮度是多少，只分配给 active_light，另一个严格为 0
            if active_light == "WHITE":
                target_white_duty = base_target_duty
                target_red_duty = 0.0
            else:
                target_white_duty = 0.0
                target_red_duty = base_target_duty
    
            # 平滑渐变算法
            # 此版本为正逻辑，占空比与亮度成正比，直接把亮度送进 PWM 寄存器即可
            current_white_duty += (target_white_duty - current_white_duty) * smoothing_factor
            current_red_duty += (target_red_duty - current_red_duty) * smoothing_factor


        # =============== 4. 最终输出与终端状态打印 ===============
        pwm_set(pwm0, int(current_white_duty), enable=True)
        pwm_set(pwm1, int(current_red_duty), enable=True)
        
        print("---- frame ----")
        print(scene_text)
        mode_str = "AUTO" if sys_mode == MODE_AUTO else ("MANUAL" if sys_mode == MODE_MANUAL else "FLASH")
        print(f"--> Mode: [{mode_str}] | Active Channel: [{active_light}] | Reason: {reason}")
        print(f"--> WHITE(42): Target {int(target_white_duty)}% -> Act {int(current_white_duty)}%")
        print(f"--> RED  (43): Target {int(target_red_duty)}% -> Act {int(current_red_duty)}%")
        print("fps:", clock.fps())

        gc.collect()