# 8. 起動しない・おかしいとき

多くの失敗は機体が自分で元に戻る。まず何が自動で起きるかを確かめ、それで戻らないときだけ
手で直す。

## 自動で戻るもの

| 症状 | 自動で起きること | 手でやること |
|---|---|---|
| falcon 経路の途中で落ちる・固まる | SPL は falcon に入る前に `boot_os=no` を書くので、次の起動は U-Boot proper 経由になる。起動できると falcon-rearm が `boot_os=yes` に戻す | 電源を入れ直す。毎回 proper に落ちるなら、その面の `falcon.itb` が壊れている。Linux の更新で直す |
| Linux の試起動が駄目 | commit しなければ、再起動で元の面に戻る。起動しない場合も、SPL が試行回数を数えて元の面に戻す | 再起動するだけ。確定後に戻したいときは `ab linux rollback` |
| 試す面に `falcon.itb` が無い | SPL が U-Boot proper に落ち、試行切れで元の面に戻る | なし |
| M コアの新しいファームが動かない | 試すのは 1 回だけで、キープアライブが届き続けなければ再起動して確定済みの面に戻る | 確定後に戻したいときは `ab mcore rollback` |
| SPL の A が壊れている(IVT が不正) | ROM が B を起動し、`ab-spl-selfheal` が B で A を直す | なし |

proper 経由で起動させたいときは、機体で `fw_setenv boot_os no` してから再起動する。

## 手で直すもの

- **SPL は起動するが動きがおかしい**: `ab spl rollback` で B(前の版)を A に書き戻す
- **SPL が途中で止まる(IVT は正しいので ROM は B に行かない)**: 外から書き直す
  - SD の U-Boot から書く: DIP を SD(011)にして SD の U-Boot を起動し、`dhcp` + `tftpboot` +
    `mmc write` で imx-boot を eMMC の A(セクタ 0x40)に書く。コマンドは
    [04-falcon.md](../imx8mp-debix-bringup/04-falcon.md)「リカバリ経路」。PC のファイアウォールが
    TFTP(UDP)を落とすことがあるので、通らなければ許可する
  - eMMC 全体を書き直す: [02-first-flash.md](02-first-flash.md)
- **LAN の SSH に入れない**: SSH のホスト鍵は `/data/ssh` にあるので、`/data` がマウントできないと
  LAN の SSH は動かない。シリアルで入り、`/data` の状態を見る。鍵が変わったと言われるときは
  [03-provisioning.md](03-provisioning.md) の「SSH のホスト鍵」
- **画面が出ない**: ユニットが全部動いていても黒いことがある。カメラの判定(lcd-validation)で
  確かめる。過去の真っ黒の原因と対処は [06-splash.md](../imx8mp-debix-bringup/06-splash.md)

## やってはいけないこと

- **`falcon.itb` やカーネルだけを差し替えない。** カーネルの版の文字列がビルドごとに変わり、rootfs の
  モジュールと合わなくなる(Ethernet や /boot のマウントまで止まる)。必ず Linux の更新
  ([04-ab-updates.md](04-ab-updates.md))でイメージごと入れる。やってしまったら
  `fw_setenv boot_os no` で proper 経由にして起動し、Linux の更新で直す
- **秘密の `kmm.env` をイメージや Git に入れない**

## XPI(i.MX8MM)

- SPL が壊れたときは USB 書き込み(DIP S1 を Serial Download)から
  [06-emmc-flash.md](../imx8mm-xpi-bringup/06-emmc-flash.md) の手順で書き直す
- S1 に触れないときは、動いている Linux から USB 書き込みに落とす(`xpi-remote-sdp` スキル)
