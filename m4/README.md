# m4/ — Cortex-M4 ファームウェア

XPI-iMX8MM の Cortex-M4 (400MHz, TCM 128KB+128KB) 用ベアメタルコード置き場。
MCUXpresso SDK 非依存 — `apt install gcc-arm-none-eabi` だけでビルドできる。

背景・ハード調査・デバッグ手法の詳細は
[docs/imx8mm-xpi-bringup/10-cortex-m4.md](../docs/imx8mm-xpi-bringup/10-cortex-m4.md)。

## クイックスタート

```bash
cd hello-world
make            # → hello.elf (441 バイト)
make deploy     # scp + remoteproc 再起動。J64 (ttyACM1, 115200) に出力
make stop
```

前提: 実機カーネルに remoteproc 対応が入っていること
(m4-remoteproc.cfg + DTS の imx8mm-cm4 ノード — 本リポジトリで対応済み)。

## ディレクトリ

| dir | 内容 |
|---|---|
| `hello-world/` | 雛形。ベクタテーブル + UART4 直叩き + TCMU ブレッドクラム |
| `rpmsg-echo/` | rpmsg-lite ベースのエコー。リソーステーブル + MU 割り込みの雛形 |
| `can-sim/` | mock CAN フレーム (0x5F0-0x5F4) を rpmsg で流す。kmm rpmsg バックエンドの相手 |
| `repro-mu-read-reset/` | **NXP 報告用の最小再現**: rpmsg セッション中の GPIO read で SoC がハードリセットする問題 (pitfalls #26)。README は英語 |
| `shim/` | SDK 代替の最小ヘッダ (MU レジスタ / NVIC) + ベアメタル libc |
| `lib/` | ベンダリングライブラリ置き場 (gitignore、下記の手順で clone) |
| `tools/` | Linux 側の計測ツール (rpmsg RTT 計測、ボード上でビルドせず scp) |

## rpmsg-lite の取得 (rpmsg-echo / can-sim のビルドに必要)

`m4/lib/rpmsg-lite/` は gitignore してあるので初回に clone する:

```bash
git clone --depth 1 --branch v5.4.1 \
    https://github.com/nxp-mcuxpresso/rpmsg-lite m4/lib/rpmsg-lite
```

## 新しいファームを書くときの約束事

- レジスタ直叩きの値には**必ず出典コメント** (RM / linux ドライバ /
  pinfunc.h / 実機ダンプのどれか) を付ける
- クロックゲート (CCGR) は SET レジスタに **0x30** (M4 の実効フィールドは
  bits[5:4] — pitfalls #25)。root スライスは普通に書ける
- デバッグは TCMU ブレッドクラム (`DBG[]` @ 0x20000100、A53 から
  `devmem 0x800100` で読む) を最初から仕込む — UART より先に立つ
- M4 に渡すペリフェラルを増やすときは Linux DT で disable + RDC 確認
