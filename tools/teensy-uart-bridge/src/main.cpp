// XPI-i.MX8MM の A コア / M コアの各 UART コンソールを、Teensy 4.0 を介して
// PC からは独立した 2 本の USB CDC シリアルデバイスとして見せるブリッジ。
//
// 配線 (すべて 3.3V ロジック、GND 共通):
//   Serial1: RX1 = pin 0, TX1 = pin 1  <->  A コア UART (TX->RX1, RX<-TX1)
//   Serial2: RX2 = pin 7, TX2 = pin 8  <->  M コア UART (TX->RX2, RX<-TX2)
//
// PC 側で開いたボーレート (CDC line coding) がそのままハードウェア UART に
// 反映されるので、picocom/minicom の -b 指定だけで両側の速度が揃う。

#include <Arduino.h>

#if !defined(USB_DUAL_SERIAL) && !defined(USB_TRIPLE_SERIAL)
#error "Build with -D USB_DUAL_SERIAL (platformio.ini の build_flags を確認)"
#endif

static constexpr uint32_t DEFAULT_BAUD = 115200;

// USB 側が詰まっている間も UART 受信を取りこぼさないよう受信バッファを拡張
static uint8_t uart1RxBuf[4096];
static uint8_t uart2RxBuf[4096];

static uint32_t baudA = 0;  // Serial1 に設定済みのボーレート
static uint32_t baudM = 0;  // Serial2 に設定済みのボーレート

static elapsedMillis sinceActivity;


#ifdef USB_TRIPLE_SERIAL
// ---- 自己診断コンソール (SerialUSB2 = if04) ----
// Serial2 (M コア側) が無音化した事例の真因判別用。固着時にここが生きて
// いれば LPUART の内部値で「LPUART 側の固着 (availableForWrite=0 等)」vs
// 「USB CDC2 側の死」をその場で確定できる。ここも死んでいれば USB
// スタック全体の問題と分かる。対策 (自動リセット等) は真因確定後に入れる。
static elapsedMillis sinceDiag;
static void diagReport() {
  if (sinceDiag < 1000) return;
  sinceDiag = 0;
  if (!SerialUSB2 || SerialUSB2.availableForWrite() < 96) return;  // 読者不在なら黙る
  IMXRT_LPUART_t *lp = &IMXRT_LPUART4;  // Serial2 = LPUART4 (pin7/8)
  SerialUSB2.printf(
      "s2 afw=%d avail=%d baudM=%lu stat=%08lX ctrl=%08lX water=%08lX usb1=%d\r\n",
      Serial2.availableForWrite(), Serial2.available(),
      (unsigned long)baudM, (unsigned long)lp->STAT, (unsigned long)lp->CTRL,
      (unsigned long)lp->WATER, (int)SerialUSB1.availableForWrite());
}
#endif

// ホストが CDC ポートに設定したボーレートを対応する UART へ追従させる
template <typename UsbSerial>
static void syncBaud(UsbSerial &usb, HardwareSerial &uart, uint32_t &current) {
  uint32_t b = usb.baud();
  if (b == 0) {
    b = DEFAULT_BAUD;  // ホスト未接続 or line coding 未設定
  }
  if (b != current) {
    current = b;
    uart.begin(b);
  }
}

// src -> dst へ、双方の空きに収まる分だけまとめて転送する
static size_t pump(Stream &src, Stream &dst) {
  int n = src.available();
  if (n <= 0) {
    return 0;
  }
  int space = dst.availableForWrite();
  if (space <= 0) {
    return 0;
  }
  uint8_t buf[512];
  if (n > space) n = space;
  if (n > (int)sizeof(buf)) n = (int)sizeof(buf);
  n = (int)src.readBytes((char *)buf, n);
  if (n > 0) {
    dst.write(buf, n);
  }
  return (size_t)n;
}

void setup() {
  pinMode(LED_BUILTIN, OUTPUT);

  Serial1.addMemoryForRead(uart1RxBuf, sizeof(uart1RxBuf));
  Serial2.addMemoryForRead(uart2RxBuf, sizeof(uart2RxBuf));
  Serial1.begin(DEFAULT_BAUD);
  Serial2.begin(DEFAULT_BAUD);
  baudA = DEFAULT_BAUD;
  baudM = DEFAULT_BAUD;
}

void loop() {
  syncBaud(Serial, Serial1, baudA);
  syncBaud(SerialUSB1, Serial2, baudM);

  size_t moved = 0;
  // ホストがポートを開いている (DTR あり) 時だけブリッジし、未接続時は
  // UART 受信を読み捨てる。溜め込むと CDC TX プール (8KB) が満杯になり
  // pump が止まる (実測)。その状態で溜まるのは「最古の ~12KB」なので、
  // 次に開いた時に古いバースト + 中抜けの壊れたログになる。捨てて鮮度を
  // 保てば「開いた瞬間から新しいデータが正しく流れる」が成立する。
  if (Serial) {
    moved += pump(Serial, Serial1);      // PC -> A コア
    moved += pump(Serial1, Serial);      // A コア -> PC
  } else {
    while (Serial1.available() > 0) Serial1.read();
  }
  if (SerialUSB1) {
    moved += pump(SerialUSB1, Serial2);  // PC -> M コア
    moved += pump(Serial2, SerialUSB1);  // M コア -> PC
  } else {
    while (Serial2.available() > 0) Serial2.read();
  }
#ifdef USB_TRIPLE_SERIAL
  diagReport();
#endif

  if (moved > 0) {
    sinceActivity = 0;
  }
  // 通信中は LED 点灯 (消灯まで 50ms ホールド)
  digitalWrite(LED_BUILTIN, sinceActivity < 50 ? HIGH : LOW);
}
