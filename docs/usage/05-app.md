# 5. アプリ(kmm)の更新

GUI アプリは別リポジトリの kart-machine-manager(`app-cpp/`、C++/Qt6 Widgets)。イメージには
常に入っていて、`/usr/bin/kmm` を `kmm.service` が起動する。

## 正式な更新

1. kart-machine-manager に push する
2. `meta-kart/recipes-app/kmm/kmm_2.0.bb` の `SRCREV` をそのコミットにする。ブランチを変えたときは
   `SRC_URI` の `branch=` も直す
3. イメージをビルドし([01-build.md](01-build.md))、Linux の更新で入れる([04-ab-updates.md](04-ab-updates.md))

```bash
./scripts/ab.sh --host <機体> linux try <wic.bz2>
./scripts/ab.sh --host <機体> linux commit
```

## 手元で試す(イメージを作り直さない)

Qt の SDK でクロスビルドし、バイナリだけ差し替える。rootfs は読み取り専用なので、書くときだけ
書き込み可にする。差し替えたバイナリは、次の Linux の更新で消える。

```bash
source <SDK>/environment-setup-*
cmake -B build-app ../kart-machine-manager/app-cpp && cmake --build build-app -j
ssh root@<機体> 'mount -o remount,rw /'
scp build-app/kmm root@<機体>:/usr/bin/kmm
ssh root@<機体> 'mount -o remount,ro / ; systemctl restart kmm'
```

SDK は、機種の構成の後ろに `kas/sdk.yml` を足して `meta-toolchain-qt6` をビルドする(例は
`kas/sdk.yml` の冒頭)。Qt は qtbase だけに絞ってある。インストーラは
`build/tmp/deploy/sdk/poky-glibc-x86_64-meta-toolchain-qt6-*.sh`。

手元のソースのままイメージに入れたいときは、Yocto の externalsrc で kmm のレシピを手元のソースに向ける
(kas の設定をもう 1 枚重ねる。リポジトリには入れていない)。

## 設定

秘密の設定は `/data/kmm.env`([03-provisioning.md](03-provisioning.md))。項目は kart-machine-manager の
`app-cpp/README.md`。
