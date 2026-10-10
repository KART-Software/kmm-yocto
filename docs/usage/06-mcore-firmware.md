# 6. M コアのファーム(M7 / M4)

CAN コントローラは Cortex-M に任せていて、M コアで動く `can-gw`(Zephyr)が rpmsg で Linux の
`rpmsg-can` モジュールにつながり、`rpmsgcan0` を作る。8MP は M7 が FlexCAN1 を、8MM は M4 が
MCP2515(ECSPI2)を持つ。仕組みは [01-m7.md](../imx8mp-debix-bringup/01-m7.md)(8MP)と
[10-cortex-m4.md](../imx8mm-xpi-bringup/10-cortex-m4.md)(8MM)。

## ファームの置き場所

| 機種 | 置き場所 | 起動のしかた |
|---|---|---|
| 8MP | p3(MCORE)の `mcore-a.img` / `mcore-b.img`。Linux とは独立した A/B | SPL が env の面を読んで DDR に置き、BL31 が起動。Linux は動いている M7 に attach する |
| 8MM | BOOT の `m4-fw.img`(Linux の面と一緒に更新される) | 同じく SPL と BL31 が起動し、Linux が attach する |

どちらも、ヘッダ(magic `M7FW` / `M4FW`、長さ、CRC32、版)付きのコンテナに Zephyr の `zephyr.bin` を
包んだもの。

## ビルド

ソースは [data-logger-zephyr](https://github.com/KART-Software/data-logger-zephyr) の `apps/can-gw`。
ビルドは Docker で行う(同リポジトリの README)。

```bash
cd ../data-logger-zephyr
./west-container.sh build -b imx8mp_evk/mimx8ml8/m7 apps/can-gw -d build-cangw-8mp   # 8MP
./west-container.sh build -b imx8mm_evk/mimx8mm6/m4 apps/can-gw -d build-cangw-8mm   # 8MM
```

## 試す(再起動で元に戻る)

data-logger-zephyr の `scripts/try.sh` が ELF を機体の `/lib/firmware` に置き、remoteproc で
動いている M コアを止めて差し替える。M コア経由の CAN(`rpmsgcan0`)が上がるまで待つ。
eMMC に置いたファームは変えないので、再起動すれば元に戻る。

```bash
BOARD=root@<機体> ./scripts/try.sh build-cangw-8mp
```

ログは 8MP なら機体の `/sys/kernel/debug/remoteproc/remoteproc0/trace0`、8MM なら M4 の
UART(`/dev/kart-m4-uart`、115200)。

## 入れる(再起動後も使われる)

data-logger-zephyr の `scripts/install.sh` が、ビルドからコンテナを作って機体に置く。ビルドの SoC と
機体が合わなければ書く前に止まる。

```bash
BOARD=root@<機体> ./scripts/install.sh build-cangw-8mp --reboot
```

- **8MP**: 機体の `ab mcore update` で p3 の反対の面に書く。次の起動で 1 回だけ試し、rpmsg まで
  つながれば自動で確定、駄目なら確定済みの面に戻る。壊れたファームでも、試すのは 1 回きりなので
  リセットを繰り返すことはない
- **8MM**: BOOT の `m4-fw.img` を置き換える。次の起動からそのまま使われ、自動では戻らない。
  先に `try.sh` で動作を確かめること

## 製品に同梱するファーム

`meta-kart/recipes-bsp-imx/falcon-itb/files/m7-fw.bin` / `m4-fw.bin` が、ビルド済みの `zephyr.bin`
の同梱版。`falcon-itb` レシピがコンテナに包んで `m7-fw.img` / `m4-fw.img` を作る。

- 8MP の `m7-fw.img` は Linux のイメージには入らない。`ab mcore update` で入れる
  ([03-provisioning.md](03-provisioning.md)、[04-ab-updates.md](04-ab-updates.md))
- 8MM の `m4-fw.img` は Linux のイメージの BOOT に入る
- 同梱版を新しくするときは、ファイルを差し替え、レシピのコメント(provenance)に data-logger-zephyr の元のコミットを書く

## kmm から読む

kmm は `/data/kmm.env` の `CAN_INTERFACE=rpmsgcan0` で M コア経由の CAN を読む。手で見るなら:

```bash
candump rpmsgcan0
cansend rpmsgcan0 123#DEADBEEF
```
