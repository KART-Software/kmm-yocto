# 3. 書き込んだ直後の初期設定

[02-first-flash.md](02-first-flash.md) の後に、機体ごとに一度だけ行う。

## 機体に入る

- ネットワークは systemd-networkd の DHCP。IP はルーターの払い出し一覧で探すか、シリアル
  コンソールで `ip -4 addr` を見る。シリアルは全イメージで root に自動ログインする
  ([07-bench.md](07-bench.md))
- 開発用イメージ(debug-tweaks)は root のパスワードが空で、`ssh root@<IP>` で入れる
- prod イメージは root のパスワードがロックされていて、LAN の SSH では入れない。入り口は
  Tailscale SSH だけなので、下の Tailscale を先に済ませる

## SSH のホスト鍵

SSH のホスト鍵は機体ごとに違う。最初の起動で GUI が出た後に作られ、永続領域 `/data/ssh` に残る。
Linux を更新しても変わらない。イメージにもリポジトリにも鍵は入っていない。

`/data` ごと書き直す(最初の書き込みをやり直す)と鍵が変わるので、PC の `known_hosts` から古い鍵を
消してからつなぐ:

```bash
ssh-keygen -R <IP>
```

Tailscale SSH は tailscaled が自分の鍵を使うので、この影響を受けない。

## kmm.env を置く

GUI アプリ(kmm)の秘密の設定は、イメージにも Git にも入れない。永続領域 `/data` に置く
(更新しても消えない)。無いと kmm は起動に失敗する。

```bash
scp kmm.env root@<機体>:/data/kmm.env
ssh root@<機体> systemctl restart kmm
```

- 項目は kart-machine-manager の `app-cpp/README.md` にある
- M コアの CAN を使う構成(製品構成)では `CAN_INTERFACE=rpmsgcan0` を入れる。省略すると
  `can0` を読む。8MP の `can0` は Linux 側の FlexCAN2 で、製品では使っていない

## M コアのファームを置く(8MP)

書き込んだばかりの 8MP には M7 のファームが無く、CAN(`rpmsgcan0`)が動かない。ビルドが作る
`m7-fw.img` を M コアの A/B に入れる:

```bash
./scripts/ab.sh --host <機体> mcore update build/tmp/deploy/images/imx8mp-debix/m7-fw.img
```

機体は再起動して新しいファームを 1 回試し、rpmsg までつながれば自動で確定する。確定まで
1 分以内に終わる。確かめ方:

```bash
ssh root@<機体> 'ab mcore status; ip -s link show rpmsgcan0'
# MCORE_SLOT=a、MCORE_STATE=attached、rpmsgcan0 の RX が増えていればよい
```

XPI(8MM)は `m4-fw.img` がイメージの BOOT に入っていて、この作業は要らない。

## Tailscale に参加させる

鍵は [Tailscale の管理画面](https://login.tailscale.com/admin/settings/keys)で発行する。
**事前承認済み・非 ephemeral** にする(承認待ちだと `tailscale up` が止まり、ephemeral は切断で
識別が消える)。複数台なら reusable にしてタグを付け、ACL はタグで書く。tailnet の ACL で SSH を
許可しておく。参加状態は `/data/tailscale` に残り、更新しても参加し直す必要は無い。

参加のさせ方は 2 通り:

- **次の Linux の更新と一緒に**: `linux try` に `--authkey <鍵のファイル>` を付ける。鍵は新しい面の
  BOOT に置かれ、起動時に `tailscale-autoconnect` が参加して鍵を消す

  ```bash
  ./scripts/ab.sh --host <機体> linux try <wic.bz2> --authkey <鍵のファイル>
  ```

- **今すぐ手で**(LAN の SSH かシリアルで入れるとき): 自動参加と同じ引数で

  ```bash
  tailscale up --authkey=<鍵> --hostname=$(hostname) --ssh --accept-dns=false
  ```

`--accept-dns=false` は MagicDNS を OS に入れない設定で、読み取り専用の rootfs に resolv.conf を
書こうとして失敗するのを避ける。

## Linux の b 面を埋める

書いた直後は Linux の b 面が空。一度 `linux try` → `linux commit` すると b 面にも入り、両面が
同じ版になる([04-ab-updates.md](04-ab-updates.md))。

## 確かめる

```bash
ssh root@<機体> 'ab status; systemctl --failed'
```

- `ab status` の見方は [04-ab-updates.md](04-ab-updates.md)
- 画面が実際に映っているかは、ユニットの状態では分からない。カメラの判定(lcd-validation)で
  確かめる([07-bench.md](07-bench.md))
