# teensy-uart-bridge

XPI-i.MX8MM の **A コア** / **M コア** それぞれの UART コンソールを Teensy 4.0 に集約し、
PC からは **独立した 2 本の USB シリアルデバイス** として見せるブリッジファームウェア。

```
XPI-i.MX8MM                    Teensy 4.0                PC
  A コア UART  <-- 3.3V UART -->  Serial1 (pin 0/1)  ┐
  M コア UART  <-- 3.3V UART -->  Serial2 (pin 7/8)  ┴─ USB ─→  /dev/ttyACM0 (A コア)
                                                               /dev/ttyACM1 (M コア)
```

Teensy の `USB_DUAL_SERIAL` ビルドオプションを使い、1 本の USB ケーブルで
2 つの CDC-ACM インターフェースを列挙させている。
PC 側で設定したボーレート（picocom の `-b` など）は CDC line coding 経由で
そのままハードウェア UART に反映されるので、速度は PC 側の指定だけで揃う。

## 配線

| Teensy 4.0 | 接続先 |
|---|---|
| pin 0 (RX1) | A コア UART の **TX** |
| pin 1 (TX1) | A コア UART の **RX** |
| pin 7 (RX2) | M コア UART の **TX** |
| pin 8 (TX2) | M コア UART の **RX** |
| GND | ボードの GND |

- **3.3V ロジックのみ**。Teensy 4.0 の I/O は 5V 非トレラント。i.MX8MM 側の UART は 3.3V なのでそのまま接続できる。
- 電源線は接続しない（GND のみ共通化）。
- i.MX8MM EVK の慣例では A53 コンソールが UART2、M4 コンソールが UART4。XPI ボード上のどのピンヘッダに出ているかは基板のピンアサイン表で確認すること。

## ビルドと書き込み

[PlatformIO](https://platformio.org/) を使用（`pipx install platformio` などで導入）。

```bash
cd tools/teensy-uart-bridge
pio run                 # ビルドのみ
pio run -t upload       # Teensy へ書き込み（teensy-loader が自動起動）
```

## PC 側での見え方

USB を挿すと CDC-ACM が 2 つ列挙される。順序は固定で、
1 本目（`bInterfaceNumber` 00）が A コア、2 本目（同 02）が M コア。

```bash
ls /dev/serial/by-id/
# usb-Teensyduino_Dual_Serial_XXXXXXXX-if00  -> A コア
# usb-Teensyduino_Dual_Serial_XXXXXXXX-if02  -> M コア

picocom -b 115200 /dev/serial/by-id/usb-Teensyduino_Dual_Serial_*-if00   # A コア
picocom -b 115200 /dev/serial/by-id/usb-Teensyduino_Dual_Serial_*-if02   # M コア
```

`/dev/ttyACM0` / `ttyACM1` の番号は他のデバイスとの挿抜順で変わりうるので、
固定名が欲しい場合は `by-id` パスを使うか udev ルールを書く。

## 動作の詳細

- 起動時は両 UART とも 115200 bps。ホストがポートを開いてボーレートを設定すると即座に追従する。
- UART 受信バッファは各 4KB に拡張済み（USB 側が詰まった際の取りこぼし対策）。
- オンボード LED はいずれかの方向にデータが流れている間だけ点灯する。
