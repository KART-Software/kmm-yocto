# 4. A/B の更新(SSH 経由)

Linux、M コアのファーム、SPL はそれぞれ独立した A/B を持つ。機体側の `ab` コマンド一つで
3 つを扱い、PC からは `scripts/ab.sh` が SSH(Tailscale でもよい)越しに使う。ファイルを渡す
操作は、先にファイルを機体へ送ってから機体の `ab` を呼ぶ。設計は
[04-falcon.md](../imx8mp-debix-bringup/04-falcon.md)「A/B とスロット選択」。

```bash
H=192.168.0.7
D=build/tmp/deploy/images/imx8mp-debix
./scripts/ab.sh --host $H status
./scripts/ab.sh --host $H linux try $D/kart-image-imx8mp-debix-emmc.wic.bz2
./scripts/ab.sh --host $H linux commit
./scripts/ab.sh --host $H mcore update $D/m7-fw.img
./scripts/ab.sh --host $H spl update $D/imx-boot
```

| 対象 | 操作 | 何が起きるか |
|---|---|---|
| `linux` | `try` / `commit` / `rollback` / `status` | `try` は空いている面に書き、普段と同じ falcon 経路で**1 回だけ**試起動する。確かめて `commit` する。`commit` せずに再起動すると元の面に戻る。SPL も試行回数を数え、`bootlimit` を超えると元の面に戻す。`rollback` は反対の面を同じように試起動する(書き込みはしない)ので、確かめてから `commit` する |
| `mcore` | `update` / `rollback` / `status` | `update` は p3 の反対の面に書き、次の起動で 1 回試す。M コアのキープアライブが届き続ければ自動で確定し([06-mcore-firmware.md](06-mcore-firmware.md))、駄目なら再起動して確定済みの面に戻る。`rollback` も同じように反対の面を試す |
| `spl` | `update` / `rollback` / `status` | `update` は新しい版を A に、それまでの版を B に書く。ROM が B を起動するのは A が壊れているときだけなので、自動の判断はしない。`ab spl status` で確かめ、駄目なら `rollback` |

`update` / `try` / `rollback` は自分で再起動する。`--no-reboot` を付けると書き込みと予約だけして
再起動を待つ。

## Linux の更新

```bash
./scripts/ab.sh --host <機体> linux try <wic.bz2> [--authkey <鍵のファイル>]
# 起動した面を確かめる(ab.sh が起動後の linux status を表示する)
./scripts/ab.sh --host <機体> linux commit
```

- 書く前に確かめること: 試行中でない、書き込み先がマウントされていない、イメージの名前に
  機体のホスト名(Yocto の MACHINE)が入っている。機種の照合は `--force` で飛ばせる
- rootfs は gzip で流し込み、機体で読み戻して sha256 を照合する。PC 側で約 2 分
- **両面を同じ版にするなら `linux try` → `commit` を 2 回**(2 回目はもう片方の面に書く)
- `--authkey` は Tailscale の初回参加用の鍵を新しい面の BOOT に置く([03-provisioning.md](03-provisioning.md))
- 新しい面では、`falcon.itb`(BL31 とカーネル)も、proper に落ちたときの U-Boot proper も新しい版が動く
- 2026-10 より前のイメージは、全機体で同じ SSH のホスト鍵を使っていた。それより後のイメージへ更新すると、
  試起動の時点で機体ごとの鍵に変わる。`ab.sh` の SSH が鍵の不一致で止まるので、PC で
  `ssh-keygen -R <機体>` してから続ける([03-provisioning.md](03-provisioning.md))

### commit が確かめること

`ab linux commit` は次が揃わないと確定しない(`--force` で飛ばせる。ただし試している面で
動いていないときは、`--force` でも確定しない):

- 新しい面から falcon 経路で起動し、falcon-rearm が次の起動も falcon になるよう再アームした
- 起動が終わり、失敗したユニットが 0、ordering cycle が 0
- weston と kmm が動いている(kmm は最初の画面表示で起動完了を知らせる)
- `/data` がマウントされ `kmm.env` がある
- `/boot` がマウントされ、動いているカーネルのモジュールがある
- `linux try` の前に Tailscale がつながっていたなら、今もつながっている

画面が実際に映っているかは判定できない。表示は lcd-validation で確かめる。

## ab status の見方

| 項目 | 意味 |
|---|---|
| `LINUX_RUNNING` | いま動いている Linux の面 |
| `LINUX_SLOT` / `LINUX_FALLBACK` | 次に起動する面 / 試行に失敗したとき戻る面 |
| `LINUX_TRY` | 1 なら試行中(まだ commit していない) |
| `LINUX_BOOTCOUNT` | 試行の回数 / 上限 |
| `LINUX_BOOT_PATH` | `falcon` / `proper`。旧 SPL では `unknown` |
| `MCORE_SLOT` / `MCORE_RUNNING` | 確定済みの M コアの面 / この起動で SPL が置いた面 |
| `MCORE_STATE` | remoteproc の状態。`attached` なら Linux とつながっている |
| `MCORE_KEEPALIVE` | M コアのキープアライブ。`alive` なら M コアが動いている。`none` はチャネルが無い(M コアが無いか、キープアライブを送らないファーム) |
| `MCORE_LAST_TRY` | 最後に試した M コアのファームの結果。確定したか、戻したならその理由 |
| `MCORE_A` / `MCORE_B` | 各面のファームの版・CRC・大きさ。`none` は空 |
| `SPL_RUNNING_COPY` | ROM が起動した SPL のコピー(A / B) |
| `SPL_A_AB` / `SPL_B_AB` | その SPL が A/B に対応した版なら 1 |

## XPI(8MM)

同じ `ab` コマンドが入るが、SPL がまだ A/B に対応していない(SPL のサイズが TCM に収まらず
保留)。そのため:

- Linux の面は MBR の起動フラグで選ばれ、試起動は U-Boot proper を通る。`ab` が env と MBR を
  揃えるので、使い方は同じ
- M コアの A/B は無い。`ab mcore` は断る。M4 のファームは BOOT の `m4-fw.img`
  ([06-mcore-firmware.md](06-mcore-firmware.md))
- `ab linux commit` は起動経路の確認を飛ばす
