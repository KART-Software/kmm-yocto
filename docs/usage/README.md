# 使い方

機体を用意してから更新・開発・復旧までの手順を、作業の順にまとめる。仕組みと設計の
説明は [ルートの README](../../README.ja.md) と各 bring-up 記録([imx8mp-debix-bringup](../imx8mp-debix-bringup/)、
[imx8mm-xpi-bringup](../imx8mm-xpi-bringup/))にある。

| # | 文書 | いつ読むか |
|---|---|---|
| 1 | [01-build.md](01-build.md) | PC の用意とイメージのビルド |
| 2 | [02-first-flash.md](02-first-flash.md) | 新しい機体の eMMC に最初に書き込む |
| 3 | [03-provisioning.md](03-provisioning.md) | 書き込んだ直後の初期設定(kmm.env・M コアのファーム・Tailscale) |
| 4 | [04-ab-updates.md](04-ab-updates.md) | 動いている機体の Linux・M コア・SPL を更新する、戻す |
| 5 | [05-app.md](05-app.md) | GUI アプリ(kmm)を更新する、手元で試す |
| 6 | [06-mcore-firmware.md](06-mcore-firmware.md) | M コア(M7 / M4)のファームを試す、入れる |
| 7 | [07-bench.md](07-bench.md) | 電源・ブートモード・シリアル・カメラなどベンチの操作 |
| 8 | [08-recovery.md](08-recovery.md) | 起動しない・おかしいときの戻し方 |

新しい機体の流れ: 1 → 2 → 3。以後の更新は 4〜6。

対象は DEBIX Infinity(i.MX8MP、最新)と XPI-iMX8MM。違いがある所は機種ごとに書く。
コマンドの `<機体>` は機体の IP アドレスか Tailscale の名前(root で入る)。
