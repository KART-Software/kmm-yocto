# Boot Time Optimization Research（起動時間最適化の研究ログ）

対象: Yocto (scarthgap 5.0) + QEMU (aarch64) / RPi5  
目的: 電源投入から GUI 表示（weston kiosk）までの時間短縮

> **注意（2026-07-26 / 2026-08-04 更新）**: 本書は時系列の実験ログ。§1〜13 は
> 2026-04〜05 の記録で、一部はその後の作業で置き換えられている（該当箇所に
> 「⚠️ その後」注記あり）。**最適化の経緯のまとめは §14、全段の実測値は §15**、
> および [ab-ota.md](ab-ota.md) を参照。
> 現行構成の実測サマリだけが必要なら [boot-timing.md](boot-timing.md) を見ること。

---

## 測定方法

### 全体時間
```bash
systemd-analyze
```
出力例: `Startup finished in 1.138s (kernel) + 6.329s (userspace) = 7.467s`

### サービスごとの起動時間
```bash
systemd-analyze blame --no-pager
```
各サービスの **実行時間（秒）** が一覧で表示される。

### クリティカルチェーン
```bash
systemd-analyze critical-chain <unit名>
```
- `@時刻` = そのユニットが完了した時刻（ブート開始から）
- `+時間` = そのユニット自身の実行時間
- チェーンは下から上へ読む（根本原因が一番下）

### journalctl による時系列確認
```bash
journalctl -b -o short-monotonic -u <サービス名> --no-pager
```
monotonic タイムスタンプ付きでログを確認できる。ブート開始からの経過秒でイベント順序を把握するのに使う。

---

## 調査対象サービスの役割

| サービス | 役割 |
|---------|------|
| `systemd-logind.service` | PAM・cgroup・VT 監視などユーザーセッション管理（約350ms） |
| `seatd.service` | GPU/入力デバイスのシート管理（起動自体はほぼ0ms） |
| `weston.service` | Wayland コンポジター（GL renderer + DRM 初期化で約1.4s） |
| `systemd-vconsole-setup.service` | TTY のキーボード配列・フォント設定（約279ms） |
| `systemd-timesyncd.service` | NTP 時刻同期（起動時に約540ms） |
| `systemd-journal-catalog-update.service` | journald カタログ更新（約436ms） |
| `kmmd.service` | kart-machine-manager デーモン（Python プロセス） |
| `kmm-start.service` | weston が準備できたときに GUI 開始を通知するサービス |

---

## 項目別 調査・対応・効果

---

### 1. weston.service から `systemd-user-sessions.service` 依存の削除

#### 問題
修正前の weston.service：
```ini
Requires=seatd.service systemd-user-sessions.service
After=seatd.service systemd-user-sessions.service dbus.socket
```

`systemd-user-sessions.service` は `network.target` を経由するため、NetworkManager の起動完了（746ms）まで weston が待機していた。

#### クリティカルチェーン（修正前）
```
weston.service
└─systemd-user-sessions.service @3.860s +112ms
  └─network.target @3.803s
    └─NetworkManager.service @3.054s +746ms
```

#### 修正内容
`meta-kart/recipes-graphics/weston/files/weston.service` を修正：
```ini
# 変更前
Requires=seatd.service systemd-user-sessions.service
After=seatd.service systemd-user-sessions.service dbus.socket

# 変更後
Requires=seatd.service
After=seatd.service dbus.socket
Wants=dbus.socket
```

#### 効果
- weston のクリティカルパスが `network.target` 経由ではなく `seatd → basic.target` 経由に変わった
- kiosk モードではユーザーセッション管理が不要なため、機能上の問題なし

---

### 2. seatd.service の起動タイミング前倒し

#### 問題の分析
`systemd-analyze blame` で `seatd.service @3.057s` と表示されていた。これを「3秒かかって起動している」と誤解しやすいが、実際は異なる。

- **`@3.057s`** = seatd が完了した時刻（ブート開始から）
- seatd 自体の初期化時間は **ほぼ0ms**（`systemd-analyze blame` に表示されない）
- 実態は「basic.target（@2.997s）の完了を 60ms 待って、その後瞬時に起動した」

journalctl 確認：
```
[4.042s] seatd: Created VT-bound seat seat0  ← ほぼ0秒で完了
[4.044s] seatd: seatd started
```

#### seatd が basic.target を待つ理由
`DefaultDependencies=yes`（デフォルト）の場合、systemd は自動的に `After=basic.target` を付与する。kiosk 用途では basic.target の一部（sshd socket 等）が不要なため、依存を削減できる。

#### 修正内容
`meta-kart/recipes-graphics/seatd/files/seatd.service` を修正：
```ini
# 変更前
[Unit]
Description=Seat management daemon
Documentation=man:seatd(1)

# 変更後
[Unit]
Description=Seat management daemon
Documentation=man:seatd(1)
DefaultDependencies=no
After=sysinit.target
```

`DefaultDependencies=no` を設定することで、`basic.target` への暗黙的な依存を削除し、`sysinit.target` 完了後すぐに起動できるようにした。

#### 効果（QEMU 測定）
- seatd はクリティカルチェーン上で `basic.target → seatd` → `basic.target → seatd`（@3.057s → @3.054s）と変化
- 改善量は微小（seatd と basic.target の差が 60ms 程度だったため）
- ただし RPi5 実機で basic.target が遅くなるケース（NetworkManager 等）では効果が出る可能性あり

#### `Before=basic.target` の検討と却下
最初の実装に `Before=basic.target` を追加したが不要と判断した理由：
- seatd が basic.target より前に**完全起動**する必要はない
- weston が `Requires=seatd.service` で待つため、weston 側が保証する
- `Before=basic.target` を入れると逆に basic.target の起動を遅延させることになる

---

### 3. `systemd-vconsole-setup.service` の無効化

#### 問題
`systemd-vconsole-setup.service` は TTY のキーボード配列・フォントを設定するサービス。kiosk 構成では TTY を使わないため不要。

`systemd-analyze critical-chain sysinit.target` の結果（修正前）：
```
sysinit.target @3.023s
└─systemd-vconsole-setup.service @2.742s +279ms
  └─systemd-journald.socket @787ms
```
sysinit のクリティカルパス上に +279ms が乗っていた。

#### 無効化の方法
systemd のサービスを無効化する方法として「マスク（mask）」を採用。
`/dev/null` へのシンボリックリンクを作成することで、systemd がそのサービスを起動しようとしてもスキップされる。

kiosk では現地 TTY 保守が不要なため、この影響はない。

#### 修正内容
`meta-kart/recipes-core/images/kart-image.bb` に postprocess 関数を追加：
```bitbake
ROOTFS_POSTPROCESS_COMMAND += "mask_vconsole_setup;"

mask_vconsole_setup() {
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system
    ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/systemd-vconsole-setup.service
}
```

#### デバッグ確認
```bash
systemctl status systemd-vconsole-setup.service
# → Loaded: masked, Active: inactive (dead)

ls -l /etc/systemd/system/systemd-vconsole-setup.service
# → lrwxrwxrwx ... -> /dev/null
```

#### 効果（QEMU 測定）
- `sysinit.target` 完了: **3.023s → 2.756s（-267ms）**
- `basic.target` 完了: **3.100s → 2.847s（-253ms）**
- `weston.service` 完了: **4.601s → 4.265s（-336ms）**
- userspace 合計: **6.513s → 6.318s（-195ms）**

vconsole を外したことで sysinit のクリティカルパスが変わり、次のボトルネックとして `systemd-timesyncd` が浮上した。

---

### 4. `systemd-timesyncd.service` の遅延起動

> **⚠️ その後（2026-07）**: この「遅延起動」方式は廃止。RTC 無しの実機では
> 時計がビルド時エポック(~2025)のままになり、NTP 同期が遅れると tailscale の
> TLS が証明書エラーで失敗する問題が発覚。最終形は「**network-online.target
> 後に起動**」（ネット確立直後に NTP → 数秒で同期）。移行時に ordering cycle
> を2回踏んだ経緯と根治は git log `d524b17` と CLAUDE.md の Gotchas を参照。

#### 問題
vconsole 無効化後のクリティカルチェーン：
```
sysinit.target @2.808s
└─systemd-timesyncd.service @2.267s +539ms
```
`systemd-timesyncd` が sysinit のクリティカルパスに 539ms 乗っていた。

timesyncd は NTP で時刻を合わせるサービス。kiosk の起動直後に正確な時刻が必要なわけではないため、遅延起動が適切。

#### 実装方針
1. `systemd-timesyncd` を mask して sysinit からの自動起動を完全に止める
2. 起動後 10s に timer で unmask → start する

#### 失敗した最初のアプローチ
最初の実装では `sysinit.target.wants/` のシンボリックリンクを削除するだけだったが、timesyncd は `enabled` のままだったため通常起動し続けた（Early start + 遅延 timer の二重起動状態になっていた）。

journalctl 確認で判明：
```
[3.384s] systemd: Starting Network Time Synchronization...  ← 早期起動
[11.034s] systemd: Starting Delayed start of systemd-timesyncd...  ← 遅延
```

#### 修正：mask + unmask approach
```bitbake
delay_timesyncd_start() {
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/sysinit.target.wants
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/timers.target.wants

    # sysinit.target.wants のリンクを削除
    rm -f ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/sysinit.target.wants/systemd-timesyncd.service
    # mask で完全停止
    ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/systemd-timesyncd.service

    # 遅延起動サービス：unmask してから start
    cat > ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/timesyncd-delayed-start.service << 'EOF'
[Unit]
Description=Delayed start of systemd-timesyncd

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'systemctl unmask systemd-timesyncd.service && systemctl start systemd-timesyncd.service'
EOF

    # 起動後 10s のタイマー
    cat > ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/timesyncd-delayed-start.timer << 'EOF'
[Unit]
Description=Delay systemd-timesyncd start until after boot

[Timer]
OnBootSec=10s
AccuracySec=1s
Unit=timesyncd-delayed-start.service

[Install]
WantedBy=timers.target
EOF

    ln -sf ../timesyncd-delayed-start.timer \
        ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/timers.target.wants/timesyncd-delayed-start.timer
}
```

#### デバッグ確認
```bash
journalctl -b -o short-monotonic -u systemd-timesyncd \
    -u timesyncd-delayed-start.timer -u timesyncd-delayed-start.service
```
修正後の結果：
```
[3.896s]  Started Delay systemd-timesyncd start until after boot.
[11.026s] Starting Delayed start of systemd-timesyncd...
[11.186s] Removed "/etc/systemd/system/systemd-timesyncd.service"  ← unmask 完了
[12.194s] Starting Network Time Synchronization...
[12.438s] Started Network Time Synchronization.
```
timesyncd の起動が約 12s まで遅延されたことを確認。

```bash
systemctl status systemd-timesyncd.service
# → disabled（起動後は running）
systemctl list-timers | grep timesyncd
# → タイマーが expired 表示
```

#### 効果（QEMU 測定）
- timesyncd は sysinit クリティカルパスから削除された
- `sysinit.target` 完了: **2.808s → 2.756s（-52ms）**
- ブート全体への改善は微小（QEMU 測定ノイズ範囲）

---

## 全体の改善まとめ

調査開始時点（基準: userspace 6.513s の計測）と最新状態の比較：

| 指標 | 調査開始時 | 最新 | 短縮 |
|------|-----------|------|------|
| userspace 合計 | 6.513s | 6.222s | **-291ms** |
| multi-user.target 到達 | 6.376s | 6.056s | **-320ms** |
| sysinit.target 完了 | 3.023s | 2.638s | **-385ms** |
| basic.target 完了 | 3.100s | 2.735s | **-365ms** |
| weston 完了相当（basic + weston） | 4.601s | 4.051s | **-550ms** |

※ QEMU のソフトウェアエミュレーション上での測定であり、±100〜200ms 程度の測定ノイズを含む。

---

## 残存ボトルネック（次の最適化候補）

現在の sysinit クリティカルパス（最新）：
```
sysinit.target @2.638s
└─systemd-update-done.service @2.569s +66ms
  └─ldconfig.service @1.881s +571ms
    └─local-fs.target @1.873s
      ...
        └─systemd-sysusers.service @1.261s +423ms
          └─systemd-remount-fs.service @977ms +240ms
            └─systemd-journald.socket @761ms
```

| サービス | 時間 | 対応可否 |
|---------|------|---------|
| `ldconfig.service` | 571ms | 無効化は非推奨（共有ライブラリキャッシュ更新） |
| `systemd-sysusers` | 423ms | 削減困難（ユーザー作成に必要） |
| `systemd-remount-fs` | 240ms | 削減困難（rootfs remount に必要） |
| `systemd-tmpfiles-setup` | 229-260ms | 削減困難（/run, /tmp 等の作成に必要） |

`systemd-journal-catalog-update` は既にマスク済みで、現在のクリティカルチェーンには入っていない。次の候補は `ldconfig` だが、これはライブラリ解決に関わるため、無効化は副作用リスクが高い。

---

## 注意事項

### QEMU と実機の違い
- QEMU はソフトウェア GPU（Mesa softpipe）を使用するため、weston 初期化が実機より遅い
- RPi5 実機では HW GPU による weston 初期化の短縮が期待できる
- QEMU での測定は傾向確認に有効だが、±100〜200ms のノイズを含む

### RPi5 特有のボトルネック（確認済み）
- `systemd-networkd-wait-online` が SD カード起動時に **1分47秒** かかるケースがある
- これはネットワーク待機のタイムアウトが原因で、GUI 起動には本来不要
- 対策: `systemd-networkd-wait-online.service` を無効化または masked にする

---

## 追記（追加検証）

ここから下は、前節以降に実施した追加の最適化・デバッグ結果。

### 5. `systemd-journal-catalog-update.service` のマスク

#### 目的
`sysinit` のクリティカルチェーン上に見えていた `systemd-journal-catalog-update (+436ms)` を除去する。

#### 修正内容
`meta-kart/recipes-core/images/kart-image.bb` に以下を追加済み。

```bitbake
ROOTFS_POSTPROCESS_COMMAND += "...;mask_journal_catalog_update;"

mask_journal_catalog_update() {
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system
    ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/systemd-journal-catalog-update.service
}
```

#### デバッグ内容
```bash
systemctl status systemd-journal-catalog-update.service
ls -l /etc/systemd/system/systemd-journal-catalog-update.service
systemd-analyze critical-chain sysinit.target
```

確認結果:
- `Loaded: masked`
- `/etc/systemd/system/systemd-journal-catalog-update.service -> /dev/null`
- `sysinit` のクリティカルチェーンから当該ユニットが消えた

#### 効果（QEMU 実測）
直前状態（timesyncd 遅延まで適用済み）との比較:

- `sysinit.target`: **2.756s -> 2.711s（-45ms）**
- `basic.target`: **2.847s -> 2.809s（-38ms）**
- `weston 完了相当（basic + weston）`: **4.265s -> 4.145s（-120ms）**
- `multi-user.target`: **6.224s -> 6.201s（-23ms）**
- 全体（kernel+userspace）: **7.467s -> 7.456s（-11ms）**

補足:
- `+436ms` は「ユニット単体実行時間」であり、並列実行の重なりがあるため全体短縮量と一致しない。

---

### 6. `systemd-resolved.service` の遅延起動

#### 目的
`sysinit` 直下の新ボトルネック `systemd-resolved (+534ms)` をクリティカルパスから外す。

#### 修正内容
`meta-kart/recipes-core/images/kart-image.bb` に `delay_resolved_start()` を追加。

方針:
1. `sysinit.target.wants` の `systemd-resolved` リンクを削除
2. `systemd-resolved.service` を mask
3. `resolved-delayed-start.timer`（OnBootSec=10s）で起動後に unmask + start

```bitbake
delay_resolved_start() {
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/sysinit.target.wants
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/timers.target.wants

    rm -f ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/sysinit.target.wants/systemd-resolved.service
    ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/systemd-resolved.service

    # resolved-delayed-start.service / .timer を生成して timers.target で有効化
}
```

#### デバッグ内容
```bash
systemctl status systemd-resolved.service
systemctl status resolved-delayed-start.timer
journalctl -b -o short-monotonic \
  -u systemd-resolved \
  -u resolved-delayed-start.timer \
  -u resolved-delayed-start.service
systemd-analyze critical-chain sysinit.target
```

主要ログ:
```
[3.735s]  Started Delay systemd-resolved start until after boot.
[11.040s] Starting Delayed start of systemd-resolved...
[12.661s] Starting Network Name Resolution...
[12.939s] Started Network Name Resolution.
```

確認結果:
- `systemd-resolved.service`: `disabled`（起動後は running）
- `resolved-delayed-start.timer`: `enabled` / `elapsed`
- `sysinit` チェーンから `systemd-resolved` が消えた

#### 効果（QEMU 実測）
直前状態（journal-catalog-update マスク済み）との比較:

- `userspace`: **6.342s -> 6.222s（-120ms）**
- `multi-user.target`: **6.201s -> 6.056s（-145ms）**
- `sysinit.target`: **2.711s -> 2.638s（-73ms）**
- `basic.target`: **2.809s -> 2.735s（-74ms）**
- `weston 完了相当（basic + weston）`: **4.145s -> 4.051s（-94ms）**
- 全体（kernel+userspace）: **7.456s -> 7.317s（-139ms）**

補足:
- `resolved-delayed-start.service` が `blame` で重く見えるのは `OnBootSec=10s` の待機を含むためで、ブートクリティカルには乗らない。

---

## 最新時点の主要ボトルネック（QEMU）

`resolved` 遅延後の `sysinit` クリティカルチェーン:

```
sysinit.target @2.638s
└─systemd-update-done.service @2.569s +66ms
  └─ldconfig.service @1.881s +571ms
    └─local-fs.target @1.873s
      ...
        └─systemd-sysusers.service @1.261s +423ms
          └─systemd-remount-fs.service @977ms +240ms
            └─systemd-journald.socket @761ms
```

現時点で優先度が高い候補:
1. `ldconfig.service`（+571ms）
2. `systemd-sysusers.service`（+423ms）
3. `systemd-remount-fs.service`（+240ms）

---

### 7. SSH ホスト鍵の事前生成 + 不要サービスの一括 mask

#### 目的
sysinit クリティカルパス外で CPU リソースを消費しているサービスを一掃し、間接的に全体のブート時間を短縮する。

#### 調査結果

`systemd-analyze blame` で確認した非クリティカルパス上の重いサービス:

| サービス | 時間 | 内容 |
|---------|------|------|
| `sshdgenkeys.service` | 2.127s | SSH ホスト鍵の生成（鍵が無ければ毎回実行） |
| `NetworkManager.service` | 855ms | ネットワーク管理（WiFi/modem 向け、デスクトップ向き） |
| `systemd-networkd.service` | 569ms | 軽量ネットワーク管理（組み込み向き） |
| `avahi-daemon.service` | 385ms | mDNS/DNS-SD（`.local` 名前解決） |
| `dnsmasq.service` | 241ms | DNS/DHCP サーバー |
| `systemd-network-generator.service` | 155ms | kernel `ip=` を `.network` ファイルに変換 |
| `rpcbind.service` | 133ms | NFS 用 RPC ポートマッパー |
| `busybox-klogd/syslog` | — | BusyBox ログデーモン（journald と重複） |

#### 各サービスの判断

**mask（無効化）するもの:**

1. **sshdgenkeys.service** — SSH ホスト鍵をイメージビルド時に事前格納し、ブート時の鍵生成を回避。サービス自体も mask して `sshd_check_keys` スクリプトの実行をスキップ。
2. **avahi-daemon.service/.socket** — kiosk 用途で mDNS 不要。
3. **dnsmasq.service** — DNS/DHCP サーバーは不要。名前解決は systemd-resolved（遅延起動）で十分。
4. **rpcbind.service/.socket** — NFS 不使用。
5. **busybox-klogd.service / busybox-syslog.service** — systemd-journald と完全に重複。
6. **NetworkManager.service / dispatcher / wait-online** — systemd-networkd より重い。networkd に統一。

**残すもの:**

| サービス | 残す理由 |
|---------|---------|
| `user@0.service` (740ms) | SSH セッションの systemd ユーザーインスタンス。SSH 接続がある限り自動起動する |
| `systemd-network-generator` (155ms) | QEMU の kernel `ip=` パラメータを `.network` ファイルに変換する必須サービス |
| `systemd-networkd` (569ms) | NM より軽量。ネットワーク管理はこちらに統一 |
| `psplash` | ブートスプラッシュ画面。weston 起動後に `psplash-write "QUIT"` で終了。UX に必要 |

#### ネットワーク統一: networkd を採用した理由

- **networkd**: 569ms、C 実装、メモリ少、設定ファイルベース → 組み込み kiosk 向き
- **NetworkManager**: 855ms、D-Bus 常駐プロセス、WiFi/modem 向け → デスクトップ向き

QEMU では kernel `ip=` → `systemd-network-generator` → `systemd-networkd` の経路でネットワークが設定される。RPi5 実機では `.network` ファイルを別途追加する必要がある（TODO）。

注意: `systemd-network-generator` と `systemd-networkd` の両方を mask すると QEMU のネットワークが完全に死ぬ。実際にやって VNC/SSH 接続不能になった。

#### 修正内容

`meta-kart/recipes-core/images/kart-image.bb`:

```bitbake
ROOTFS_POSTPROCESS_COMMAND += "...;generate_ssh_host_keys;mask_unnecessary_services;"

generate_ssh_host_keys() {
    install -d ${IMAGE_ROOTFS}${sysconfdir}/ssh
    for keyfile in ssh_host_rsa_key ssh_host_ecdsa_key ssh_host_ed25519_key; do
        install -m 0600 ${THISDIR}/files/ssh-host-keys/${keyfile} \
            ${IMAGE_ROOTFS}${sysconfdir}/ssh/${keyfile}
        install -m 0644 ${THISDIR}/files/ssh-host-keys/${keyfile}.pub \
            ${IMAGE_ROOTFS}${sysconfdir}/ssh/${keyfile}.pub
    done
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system
    ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/sshdgenkeys.service
}

mask_unnecessary_services() {
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system
    ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/avahi-daemon.service
    ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/avahi-daemon.socket
    ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/dnsmasq.service
    ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/rpcbind.service
    ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/rpcbind.socket
    ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/busybox-klogd.service
    ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/busybox-syslog.service
    ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/NetworkManager.service
    ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/NetworkManager-dispatcher.service
    ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/NetworkManager-wait-online.service
}
```

追加ファイル: `meta-kart/recipes-core/images/files/ssh-host-keys/` に事前生成した SSH ホスト鍵 3 種（rsa, ecdsa, ed25519）を格納。

注意: 全イメージが同一のホスト鍵を共有する。本番でデバイスごとに固有の鍵が必要な場合は、この仕組みを外して初回起動時の ~2s コストを受け入れる。

#### デバッグ

ビルド時にコンテナ内で `ssh-keygen` が使えず失敗（`ssh-keygen: not found`）。  
→ ホスト側で事前生成した鍵ファイルを `install` でコピーする方式に変更して解決。

#### 効果（QEMU 実測）

直前状態（resolved 遅延まで適用済み）との比較:

| 指標 | 前回 | 今回 | 差分 |
|------|------|------|------|
| kernel | 1.095s | 1.142s | +47ms (誤差) |
| userspace | 6.222s | **5.645s** | **-577ms** |
| multi-user.target | 6.056s | **5.532s** | **-524ms** |
| sysinit.target | 2.638s | **2.488s** | **-150ms** |
| basic.target | 2.735s | **2.581s** | **-154ms** |
| weston 完了 | ~4.051s | **~3.818s** | **-233ms** |
| total | 7.317s | **6.787s** | **-530ms** |

mask 確認（`systemctl list-unit-files --state=masked`）: 17 unit masked。

主な削減要因:
- `sshdgenkeys` の 2.1s が完全消滅（CPU 負荷解消）
- `NetworkManager` の 855ms が完全消滅
- `avahi` / `dnsmasq` / `rpcbind` 合計 ~760ms が消滅
- これらの CPU 競合解消により、クリティカルパス上の weston 完了も 233ms 短縮

---

## 全体の改善まとめ（最新）

調査開始時点（基準: userspace 6.513s の計測）と最新状態の比較：

| 指標 | 調査開始時 | 最新 | 短縮 |
|------|-----------|------|------|
| userspace 合計 | 6.513s | **5.645s** | **-868ms** |
| multi-user.target 到達 | 6.376s | **5.532s** | **-844ms** |
| sysinit.target 完了 | 3.023s | **2.488s** | **-535ms** |
| basic.target 完了 | 3.100s | **2.581s** | **-519ms** |
| weston 完了相当 | 4.601s | **~3.818s** | **-783ms** |
| 全体（kernel+userspace） | 7.651s | **6.787s** | **-864ms** |

※ QEMU のソフトウェアエミュレーション上での測定であり、±100〜200ms 程度の測定ノイズを含む。

---

## 残存ボトルネック（最新）

現在の sysinit クリティカルパス:
```
sysinit.target @2.488s
└─systemd-update-done.service @2.423s +63ms
  └─ldconfig.service @1.763s +586ms
    └─local-fs.target @1.759s
      └─var-volatile.mount @1.702s +49ms
        └─local-fs-pre.target @1.679s
          └─systemd-tmpfiles-setup-dev.service @1.594s +83ms
            └─systemd-sysusers.service @1.198s +368ms
              └─systemd-remount-fs.service @919ms +251ms
                └─systemd-journald.socket @739ms
```

| サービス | 時間 | 対応可否 |
|---------|------|---------|
| `ldconfig.service` | 586ms | 無効化は非推奨（共有ライブラリキャッシュ更新） |
| `systemd-sysusers` | 368ms | 削減困難（ユーザー作成に必要） |
| `systemd-remount-fs` | 251ms | 削減困難（rootfs remount に必要） |
| `systemd-networkd` | 587ms | クリティカルパス外、残す必要あり |

### TODO
- RPi5 実機用に networkd の `.network` ファイル（DHCP）を追加

---

### 8. NetworkManager パッケージ削除 + networkd への統一

#### 目的
NM を mask するだけでなくパッケージ自体を削除し、イメージサイズを削減する。

#### 修正内容

- `kart-image.bb`: `IMAGE_INSTALL` から `networkmanager` を削除
- `kas/base.yml`: `PACKAGECONFIG:append:pn-networkmanager = " modemmanager"` セクションを削除
- `kart-image.bb`: `mask_unnecessary_services()` から NM 関連の mask 3行を削除（パッケージ自体が無いため不要）
- `kart-image.bb`: DESCRIPTION から `NetworkManager` の記述を削除

ネットワーク管理は `systemd-networkd` に統一。QEMU では kernel `ip=` → `systemd-network-generator` → `systemd-networkd` の経路で自動設定される。

#### 効果
ブート時間への影響は誤差範囲（NM は既に mask 済みだったため）。主な効果はイメージサイズの削減。

---

### 9. psplash 削除と fb0 タイムアウト解消

#### 問題
RPi5 実機で `systemd-analyze` が **1 分 34 秒**を報告。`multi-user.target` は 13.4s で到達しているにもかかわらず、`Startup finished` が 94 秒後に出力されていた。

原因調査:
```bash
journalctl -b -o short-monotonic | grep "fb0\|timed out\|Startup finished"
```

```
[  1.278s] simple-framebuffer 3f800000.framebuffer: fb0: simplefb registered!
[  3.296s] vc4-drm axi:gpu: [drm] fb0: vc4drmfb frame buffer device
[  4.247s] Expecting device /sys/devices/platform/gpu/graphics/fb0...
[ 94.106s] sys-devices-platform-gpu-graphics-fb0.device: Job ... timed out.
[ 94.107s] Timed out waiting for device /sys/devices/platform/gpu/graphics/fb0.
[ 94.107s] Startup finished in 3.362s (kernel) + 1min 30.744s (userspace)
```

#### 原因
psplash の systemd unit が `/sys/devices/platform/gpu/graphics/fb0` デバイスの出現を待機していた。RPi5 では:

1. 起動初期に `simple-framebuffer` が fb0 を登録
2. その後 `vc4-drm` が GPU ドライバをロードし、fb0 を別パスに置き換え
3. systemd が元のパスで fb0 を待ち続け、90 秒のデフォルトタイムアウトで失敗

weston は DRM/KMS を使うため framebuffer デバイスに依存しない。psplash は weston 起動前のスプラッシュ画面用だが、weston の起動が十分速い（~800ms）ため不要と判断。

#### 修正内容

- `kart-image.bb`: `IMAGE_INSTALL` から `psplash` を削除
- `weston.service`: `ExecStartPost=-/usr/bin/psplash-write "QUIT"` を削除
- `meta-kart/recipes-core/psplash/` ディレクトリを丸ごと削除（bbappend + カスタム画像）

#### 効果（RPi5 実機）

| 指標 | psplash あり | psplash なし | 差分 |
|------|-------------|-------------|------|
| Startup finished | **1 分 34 秒** | **13.6s** | **-80 秒** |
| kernel | 3.362s | 3.357s | 同等 |
| userspace | 90.7s | **10.2s** | **-80.5s** |
| multi-user.target | 13.4s | **10.2s** | **-3.2s** |
| weston 完了 | @3.917s | @4.098s | 同等 |

fb0 タイムアウトが完全に解消。

---

## RPi5 実機 計測結果

### クリティカルチェーン（kmm-start.service まで）
```
kmm-start.service +821ms
└─weston.service @3.271s +827ms
  └─basic.target @3.078s
    └─sockets.target @3.063s
      └─sshd.socket @3.014s +34ms
        └─sysinit.target @2.866s
          └─systemd-resolved.service @7.638s +96ms
            └─systemd-tmpfiles-setup.service @2.371s +35ms
              └─local-fs.target @2.291s
                └─boot.mount @2.122s +58ms
                  └─dev-mmcblk0p1.device @2.054s
```

### 電源 → GUI 表示の内訳
```
kernel boot:     3.357s
weston 開始:     +3.271s (userspace)
weston 完了:     +4.098s (userspace)
kmm-start 完了:  +4.919s (userspace)
──────────────────────────
電源 → GUI:      約 8.3 秒
```

### blame 上位（RPi5 実機）
| サービス | 時間 | 備考 |
|---------|------|------|
| `systemd-networkd-wait-online` | 6.113s | DHCP 待ち。GUI には影響なし |
| `dev-mmcblk0p2.device` | 1.542s | SD カード検出 |
| `weston.service` | 827ms | HW GPU で高速 |
| `kmm-start.service` | 821ms | GUI アプリ起動 |
| `ldconfig.service` | 464ms | ライブラリキャッシュ |
| `tailscaled.service` | 419ms | Tailscale VPN |
| `systemd-fsck-root.service` | 307ms | rootfs チェック |
| `kmmd.service` | 284ms | Python デーモン |

### QEMU vs RPi5 比較
| 指標 | QEMU | RPi5 |
|------|------|------|
| kernel | 1.1s | 3.4s |
| weston 単体 | 1.152s | **0.827s** |
| kmm-start 単体 | 1.782s | **0.821s** |
| 電源 → GUI | ~4.9s + 1.1s = ~6.0s | ~4.9s + 3.4s = **~8.3s** |

RPi5 は kernel ブートが SD カード読み込みで遅いが、weston/GUI は HW GPU により QEMU より速い。

---

## 残存ボトルネック（RPi5 実機・最新）

| サービス | 時間 | 対応可否 |
|---------|------|---------|
| `systemd-networkd-wait-online` | 6.113s | GUI 非依存。遅延起動 or mask で multi-user 短縮可 |
| `dev-mmcblk0p2.device` | 1.542s | SD カード性能依存。NVMe で大幅改善見込み |
| `ldconfig.service` | 464ms | 無効化は非推奨 |
| `tailscaled.service` | 419ms | 遅延起動で multi-user 短縮可 |

### TODO
- RPi5 実機用に networkd の `.network` ファイル（DHCP）を追加
- `systemd-networkd-wait-online` の遅延起動または無効化を検討
- NVMe ブートでの kernel 起動時間短縮を検証

---

### 10. 遅延タイマーの改善 (OnBootSec=10s → After=kmm-start + OnActiveSec=500ms)

> **⚠️ その後（2026-07）**: timesyncd 側は §4 の注記どおり network-online 起動へ
> 移行済み（タイマー廃止）。resolved の遅延タイマーは現在も有効。

#### 目的
固定 10 秒だった resolved / timesyncd の遅延起動を、GUI 起動完了に連動させる。

#### 変更内容

**Before:**
```ini
[Timer]
OnBootSec=10s
AccuracySec=1s
```

**After:**
```ini
[Unit]
After=kmm-start.service

[Timer]
OnActiveSec=500ms
AccuracySec=1ms
```

- `After=kmm-start.service`: タイマー自体が `timers.target` から Want されてキューに入るが、`After=` により kmm-start 完了まで active にならない
- `OnActiveSec=500ms`: タイマーが active になってから 500ms 後に発火
- `AccuracySec=1ms`: 省電力のためのタイマー合算を無効化（起動時 1 回きりなので影響なし。1s だと最大 +1s の遅延が発生していた）

#### 効果（RPi5 実機）

| 指標 | Before (10s) | After (500ms) |
|------|-------------|---------------|
| kmm-start 完了 | @8.6s | @8.7s |
| タイマー active | - | @8.7s |
| resolved/timesyncd 起動 | @10.0s | **@9.2s** |
| 遅延（kmm-start→起動） | 固定 1.4s | **0.5s** |

GUI 描画（kmm-start 完了 +300ms ≈ @9.0s）との重なりもなし。

---

### 11. 不要サービスの mask → パッケージ除外への置き換え

#### 背景
これまで `mask_unnecessary_services()` / `mask_vconsole_setup()` で `/dev/null` シンボリックリンクによる mask をしていたが、
パッケージ自体はイメージに残っていた。DISTRO_FEATURES / PACKAGECONFIG で元から除外する方式に変更。

#### 変更内容

**[kas/base.yml](kas/base.yml)**:
```yaml
DISTRO_FEATURES:remove = "x11 sysvinit bluetooth pcmcia 3g nfc zeroconf nfs"
PACKAGECONFIG:remove:pn-systemd = "rfkill vconsole"
PACKAGECONFIG:remove:pn-busybox = "syslog"
```

**[meta-kart/recipes-core/images/kart-image.bb](meta-kart/recipes-core/images/kart-image.bb)**:
- `mask_unnecessary_services()` 関数を削除
- `mask_vconsole_setup()` 関数を削除
- `ROOTFS_POSTPROCESS_COMMAND` から両関数の呼び出しを削除

#### 除外されるパッケージ

| パッケージ | 依存元 | 除外理由 |
|-----------|--------|---------|
| `avahi-daemon` | `packagegroup-base-zeroconf` (DISTRO_FEATURES zeroconf) | mDNS 不要 |
| `rpcbind` | `packagegroup-base-nfs` (DISTRO_FEATURES nfs) | NFS 未使用 |
| `busybox-syslog` / `busybox-klogd` | busybox PACKAGECONFIG syslog | systemd-journald と重複 |
| `systemd-vconsole-setup` | systemd PACKAGECONFIG vconsole | Weston 占有で TTY 未使用 |
| `systemd-rfkill` | systemd PACKAGECONFIG rfkill | Bluetooth/WiFi 無効化制御不要 |

#### 効果
- イメージサイズ減（パッケージ自体が入らない）
- `systemctl --failed` の rfkill 関連エラーが消える
- mask ファイル管理が不要に

#### 実機検証結果（再ビルド後の RPi5）

```
Startup finished in 1.320s (kernel) + 7.738s (userspace) = 9.059s
```

**パッケージ除外確認** (opkg list-installed):

| パッケージ | 状態 |
|-----------|------|
| `systemd-rfkill` | NOT INSTALLED ✓ |
| `systemd-vconsole-setup` | NOT INSTALLED ✓ |
| `busybox-syslog` | NOT INSTALLED ✓ |
| `avahi-daemon` | NOT INSTALLED ✓ |
| `rpcbind` | NOT INSTALLED ✓ |

**failed units**: 2 (rfkill 起因) → **0**

起動時間自体は 8.86s → 9.06s でほぼ変わらず（誤差レベル）。
これは今回の変更が起動時間短縮ではなくイメージクリーン化が目的なため想定通り。

---

### 12. agetty / serial-getty の扱い（調査のみ）

#### 現状
- `kart-image.bb` で `systemd-serialgetty` を明示的に IMAGE_INSTALL
- `util-linux-agetty` は systemd の RRECOMMENDS で入る
- `getty@tty1.service` と `serial-getty@ttyAMA0.service` が有効

#### 用途と影響
| ユニット | 用途 | 影響 |
|---------|------|------|
| `getty@tty1` | HDMI でのログインプロンプト | Weston が tty1 占有するため実質未使用 |
| `serial-getty@ttyAMA0` | UART 経由デバッグログイン | 現地で SSH/Tailscale 不通時の復旧手段 |

**SSH には影響なし**（sshd は独立）。

#### 削除時の起動時間効果
- どちらも `Type=idle` でクリティカルパスに乗らない
- `systemd-analyze blame` の top にも出ない
- 体感速度改善はほぼ期待できない（数十 ms / 数 MB のイメージサイズ削減のみ）

#### 結論
- serial-getty は**復旧手段として残す**推奨（本番で SSH 不通時の最後の砦）
- 削除するなら `systemd-serialgetty` を `local-dev.yml` へ移し、本番で除外する形

---

### 13. RPi5 実機 8.9 秒計測 + wait-online の影響範囲確認

#### 環境
- RPi5 (SD カード), kernel 1.325s + userspace 7.530s = **8.855s**

#### blame 上位
```
4.449s systemd-networkd-wait-online.service
1.403s tailscaled.service
 711ms weston.service
 703ms kmm-start.service
 421ms dev-mmcblk0p2.device
 150ms dbus.service
```

#### critical-chain（GUI 系）

```
weston.service        +711ms  (開始 @1.468s → ready @2.179s)
kmm-start.service     +703ms  (weston 完了後)
kmmd.service          +46ms   (basic.target から並列)
```

すべて `basic.target @1.452s` から分岐。**`network-online.target` を経由しない**。

> **⚠️ その後（2026-07）**: wait-online は削除ではなく **`--any`**（どれか1つの
> リンクが online なら成立）に変更。オンボード eth0 にケーブルが無い構成で
> 全リンク待ちの 120 秒タイムアウトが発生し、multi-user 到達と tailscale が
> 2分遅れる事故が起きたため。kart-image.bb の `configure_wait_online_any` 参照。

#### 結論: `systemd-networkd-wait-online` を削除しても GUI 表示時刻は変わらない

| 指標 | Before | 仮に wait-online 削除後 |
|------|--------|-------------------------|
| **GUI 表示** | ~2.2s | ~2.2s（変わらず） |
| `multi-user.target` 到達 | 7.5s | ~2.5s（見た目の改善） |
| tailscaled 接続確立 | 7.5s 後 | ~2.5s 後 |

GUI 起動時間の短縮目的では wait-online 削除は無効。ただし tailscale 接続確立タイミングの前倒しには有効。

---


### 14. 【最終まとめ 2026-07】ファーム段の全解明と最適化の完了

2026-07 の追加調査（UART キャプチャによるブートローダ実測含む）で最適化は一区切り。

#### 最終的な起動時間の内訳（電源 → GUI ≈ 10.5s + モニタ同期）

| 段階 | 時間 | 状態 |
|------|------|------|
| ファームウェア (電源→Starting OS) | **7.3s** | UART で全内訳解明。単独犯なし = Pi5 固有の積み上げ（EEPROM ロード 1.3s / SDRAM トレーニング 1.3s / RP1+PCIe 1.5s / XHCI+NVMe 0.6s / ファイル+EDID 1.1s / カーネル読込 0.8s）。**これ以上は削れない床** |
| kernel | 0.9s | NVMe 化で 3.4s→0.9s（SD 時代から -2.5s） |
| userspace → GUI 表示 | 2.0s | weston @0.5s、window @2.8s(モノトニック)。律速は PyQt6 の import ~1.6s |

#### 2026-07 に実施・判明したこと

- **時計問題の根治**: RTC 無し → 起動時刻が 2025 のまま → tailscale の TLS が証明書エラー。
  timesyncd を network-online 後の起動に変更（§4 の遅延方式は廃止）。移行時に
  「drop-in では Before= をリセットできない」systemd の仕様で ordering cycle を作り込み、
  UART コンソールで発見 → unit 本体を sed する方式で根治
- **wait-online --any 化**: eth0 未接続時の 120s タイムアウト事故を解消（§13 注記）
- **EEPROM ノブ実測**: `DISABLE_HDMI=1` **-256ms**（採用）、`boot_partition=1` -29ms、
  `BOOT_UART` は ±0（デバッグ用に 1 のまま）。`PSU_MAX_CURRENT=5000` は設定済みだった
- **カーネル gzip 圧縮は棄却**: ブートローダの展開が ~8.5MB/s と遅く **+938ms 悪化**
  （NVMe の読込 33MB/s に完敗。遅い SD なら勝つ可能性はある）
- **socket-first 化は効果ゼロ**: 重い C 拡張 import が GIL を掴み、スレッド分離しても
  socket bind が 2.4s まで進まない。旧設計でも import は weston と並行済みだった
- **A/B レイアウト化で -380ms**（予想外のボーナス）: autoboot.txt 経由の
  boot_partition 直行の方が旧レイアウトのスキャンより速い。Starting OS 7674→7293ms

#### 残存する低 ROI 候補（未実施）

1. ブートスプラッシュ — 実速度は不変だが「画面に反応が出るまで」を ~6s にできる体感対策
2. python-can の pkg_resources 排除（import ~-0.2〜0.4s）
3. カーネルスリム化（27.5MB → 読込 -0.2〜0.3s）

これ以上の劇的短縮（例: 5 秒起動）は Pi5 のクローズドなブートローダ（VPU 上で動作、
署名検証あり、置換不可）の制約により **SoC 変更なしには不可能**という結論。

#### 追試（2026-07-27）: ブートローダの追加ノブ探索 — 全て効果なし + 重要な発見

A/B レイアウト上（ベースライン 7.29s）で未検証ノブを総当たり:

| ノブ | 内容 | 結果 |
|------|------|------|
| `force_eeprom_read=0` | HAT EEPROM (I2C) プローブのスキップ | ±0 |
| `disable_poe_fan=1` | PoE ファンプローブのスキップ | ±0 |
| `hdmi_ignore_edid` | EDID 読取りスキップ | ±0 |
| `NET_INSTALL_ENABLED=0` (EEPROM) | ネットワークインストール無効化 | ±0 |

**重要な発見: ファーム段には同一設定・同温度でも ±0.3s の自然変動がある**
（同日中に 7.28s と 7.57s を観測、設定リバートでも戻らず、SoC 温度も同等）。
SDRAM トレーニングや PCIe リンクトレーニングの収束時間のばらつきと推定。

⚠️ この発見により、**単発ブート比較で得た過去の小さな差分（DISABLE_HDMI の
-256ms 等）は変動幅内の可能性が高い**。今後ファーム段の A/B 比較をする場合は
複数回サンプリングが必須。

> **【訂正 2026-08-04】この ±0.3s は現行構成では再現しない。** コールド 6 回 +
> ウォーム 5 回の計 11 ブートで幅 57ms（σ 14.6ms）。当時の変動は自然変動ではなく
> 状態依存（EEPROM 更新残骸の有無など）だった可能性が高い。詳細は §15。
> ただし「複数回サンプリングが必須」という方針自体は維持する。

**最終結論**: 設定レベルの削減は完全に枯渇。ファーム段 = 7.3±0.3s が床。
残る唯一の実レバーはカーネルスリム化（読込 0.8s の圧縮、-0.2〜0.3s、ビルド側）。
また DISABLE_HDMI は診断画面のみ抑止で EDID 読取りは走る（UART で確認）。

#### カーネルスリム化 実施（2026-07-27）: Image -36%、初の Starting OS 7秒切り

slim-aggressive.cfg で未使用ビルトインを一掃（KVM/NFS/F2FS/SUSPEND+HIBERNATION/
USB_GADGET/PROFILING+KPROBES/FTRACE/TOUCHSCREEN）:

- **Image: 27.5MB → 17.4MB（-36%）** — FTRACE 無効化が全関数のトレース用
  スタブを消すため、単純な機能削除の合計より大きく効いた
- **Starting OS: 7.3s 帯 → 6.97s**（読込セグメント短縮。自然変動 ±0.3s は
  あるが、読込バイト数の物理的減少なので効果は確実）
- **kernel init: 913ms → 726ms（-187ms）**
- CAN/GUI/tailscale 全て正常動作を OTA 経由で実機確認

これにより 電源→GUI ≈ **9.6s + モニタ同期**（初の 10 秒圏内）。
デバッグカーネルが必要になったら slim-aggressive.cfg の行を外して OTA で差し替え。

#### PID1 mountinfo レートリミッタ問題の解明と修正（2026-07-28）: 二峰性消滅、8.65s へ

C++ 版アプリ（kmm.service 直接起動）でブートを計測すると、電源→UI が
9.06s ↔ 9.42s の**二峰性**（発生率 ~50%）を示した。区間分解の結果、
/data の fsck 完了 → `Mounting /data...` の間に **0.6〜0.95s の journal
完全沈黙**があり、デバイス無関係の tmpfs マウントまで巻き添えになることから
ストレージではなく PID 1 自体の停止と特定。

`systemd.log_level=debug` ブートで原因確定:

```
[1.015] Event source (mount-monitor-dispatch) entered rate limit state.
[1.922] Event source (mount-monitor-dispatch) left rate limit state.
```

**systemd の mountinfo 監視イベントにはレートリミッタ（デフォルト 5 回/秒）
があり**、起動初期の sandbox 付きサービス群（userdbd/resolved 等）が作る
名前空間マウントのストームで発動 → 発動中はマウントユニット処理が凍結 →
fsck が終わっても data.mount のジョブが配れず、local-fs → basic → weston の
チェーン全体が ~0.9s 遅延していた。二峰性はストームがリミットを超えるか
どうかのタイミング運。upstream も承知の問題で、mount.c に
「as it stalls the boot sequence on busy systems」というコメントと共に
環境変数の逃げ道が用意されている。

**修正**: kernel cmdline に `SYSTEMD_DEFAULT_MOUNT_RATE_LIMIT_BURST=100`
を追加（カーネルが解釈しない KEY=VALUE は PID1 の環境変数になる）。

**結果（6 ブート連続）**: ギャップ全回 <10ms、shown 1.63〜1.69s（幅 66ms）、
電源→UI ≈ **8.65s**。副次効果として、以前観測していた「weston 完了→kmm
配送の 0.45s 遅延」も消滅 — burst=5 では起動ラッシュ中ずっとリミットの
出入りを繰り返し、通常優先度より高い mount-monitor がジョブ配送を妨げて
いたと考えられる。二峰性・配送遅延の両方がこの 1 行で解決した。

#### HDMI リンク前倒し実験と EEPROM 更新残骸の発見（2026-07-29）

**DISABLE_HDMI=0（ファーム段で表示初期化）を実測 A/B** — 目的はモニタの
同期 (~2.2s) をファーム段と並走させる体感短縮:

| | =1 (現行) | =0 (実験) |
|---|---|---|
| firmware | 6.999s | **7.841s (+0.84s)** |
| 電源→UI (客観) | 8.62s | 9.51s |
| 体感 (目視) | 9.7s | 10.1s |

以前の「-0.25s」という見積りに反し、このモニタとの EDID/モード確定で
+0.84s かかり、**客観・体感の両方で悪化 → 不採用**（DISABLE_HDMI=1 維持）。
現行構成の HDMI 信号開始は fbcon の初モードセット（電源から ~7.5s、
カーネル起点 0.49s）で、OS 側の前倒し余地はほぼない。体感を詰めるなら
モニタ側設定（スタンバイ深度・入力自動検出）が残りのレバー。

**副産物**: rpi-eeprom-config --apply が /boot に残す pieeprom.upd/.sig/
recovery.bin を、ブートローダが毎ブート timestamp 照合して skip しており
**+~0.27s/boot** かかっていた（UART: "SELF-UPDATE ... skip" @5.77s）。
kart-eeprom-setup が設定一致時に残骸を自動削除するよう修正。

### 15. 【全段実測 2026-08-04】UART + systemd による 11 ブート計測、変動幅の訂正

UART（CH340, 115200）をホスト PC に常設し、ファーム段を自己申告値
`Starting OS NNNN ms` で採取。カーネル / userspace は systemd の monotonic
タイムスタンプで採取。**コールド 6 回 + ウォーム 5 回**を計測した。

#### 電源 → GUI 表示 = 8588ms (8.59s)

| 段階 | 平均 | σ | n |
|------|------|-----|---|
| ファームウェア | 7001ms | 14.6 | 11 |
| カーネル | 701ms | 3.6 | 6 |
| userspace → GUI | 886ms | — | 6 |

`kmm.service` は `Type=notify` で初回ウィンドウ表示時に READY を返すため、
`ActiveEnterTimestampMonotonic` が「画面にピクセルが出た時刻」そのものになる。

#### ファーム段の内訳（11 ブート平均、合計 7000ms）

| 区間 | 所要 | σ |
|------|------|-----|
| 電源 → 最初の UART 出力（EEPROM ロード） | 1645ms | 2 |
| BOOTSYS → SDRAM 初期化開始 | 162ms | 2 |
| **SDRAM トレーニング** | **1830ms** | **14** |
| OTP → RP1 ファームロード | 668ms | 2 |
| RP1 → PCI2 init | 632ms | 2 |
| PCI2 → BOOTLOADER 段 | 57ms | 2 |
| BOOTLOADER → NVMe 認識 | 215ms | 3 |
| NVMe → config.txt 読取 | 67ms | 2 |
| config.txt → カーネル読込開始（DTB/overlay/EDID） | 1113ms | 2 |
| カーネル読込 (17,377,792 バイト) | 498ms | 2 |
| 後処理 → Starting OS | 113ms | 3 |

**変動源は SDRAM トレーニング段のみ。** 他の全区間は σ 2〜3ms で決定論的。

#### §14 追試の「±0.3s の自然変動」は再現せず

| | n | 平均 | σ | 幅 |
|---|---|------|-----|-----|
| コールドブート | 6 | 7003.2ms | 15.1 | 52ms |
| ウォームリブート | 5 | 6997.4ms | 13.2 | 34ms |
| 全体 | 11 | 7000.5ms | 14.6 | 57ms |

コールド生データ: `7003 / 7002 / 6976 / 7028 / 7006 / 7004 ms`
ウォーム生データ: `7004 / 7002 / 7005 / 7005 / 6971 ms`

コールドとウォームの差は 5.8ms で各々の σ より小さく、区別がつかない。
SDRAM 段もコールド 1832ms / ウォーム 1827ms でほぼ同一 —
**ウォームリブートで SDRAM トレーニングが短縮されることはない**。

§14 の追試（2026-07-27）が観測した 7.28s / 7.57s の差（±0.3s）は、今回の
11 ブートでは全く再現しない。当時から変わった点として、A/B レイアウト移行、
カーネルスリム化、**EEPROM 更新残骸の掃除**（§ 2026-07-29 の副産物）がある。
今回のログには `[nvme] pieeprom.upd not found` が出ており、残骸照合（+0.27s）は
発生していない。当時の変動は「自然変動」ではなく**状態依存の差**だった可能性が高い。

⚠️ ただし「ファーム段の A/B 比較は複数回サンプリングする」という方針自体は維持する。
今回それを実行した結果として、この訂正に至っている。

#### 副次的に確認できたこと

- **A/B スロット選択が機能している**: `Read autoboot.txt bytes 64` →
  `Select partition ... result 2` → `Trying partition: 2` で BOOTA へ直行。
  §14 の「A/B レイアウト化で -380ms」の挙動を UART で追認
- **`DISABLE_HDMI=1` でも EDID は読んでいる**: `HDMI0 edid block 0` 以降の
  ダンプが出る。§14 の注記どおり「診断画面のみ抑止」で、EDID 読取りは走る
- **`systemd-analyze` の総時間は GUI 到達時間ではない**: 約 9.4s と表示されるが
  内訳の 5.6〜7.9s は `systemd-networkd-wait-online`（eth0 の PHY オートネゴ +
  DHCP 待ち）。`--any` のドロップインは正しく適用されており設定不具合ではない。
  `kmm.service` は `network-online.target` に依存しないため GUI は影響を受けないが、
  `tailscaled.service` は `After=network-online.target` なので tailnet 復帰が
  6〜8 秒遅れる

#### 計測スクリプト

UART をホスト側 monotonic タイムスタンプ付きで記録する方式を用いた
（ブートローダ自身のタイムスタンプは段によってカウンタがリセットされ、
そのままでは通しの時系列にならないため）。ホスト実測（`reboot: Restarting
system` → `Starting OS`）7.011s とファーム自己申告 7.004ms が一致し、
自己申告値がリセット直後起点であることを確認済み。

### 16. slim-modular.cfg（2026-08-07）: =y→=m 移動 + KALLSYMS_ALL 削除、A/B OTA で実測 -30ms

第 3 弾のカーネル削減。原理は「削除」より「読む主体の変更」: ファームは
Image を ~35MB/s でしか読めないが、起動後のカーネルは NVMe から 500MB/s 超で
読める。組み込みをモジュール化すればバイトがファーム段から userspace 段へ移る。

内容 (slim-modular.cfg):
- 完全削除: IPV6 (製品判断。元 =m なので Image には中立)、KALLSYMS_ALL
  (シンボルテーブル、削減の最大単品)、LATENCYTOP (KALLSYMS_ALL を select
  していた)、SWAP+ZSWAP、LOGO、INPUT_MOUSEDEV/KEYBOARD
- =y→=m: SCSI + BLK_DEV_SD + USB_STORAGE / VFAT+FAT+NLS×3 (/boot は
  userspace マウントなので自動ロードで足りる) / XHCI_HCD+XHCI_PCI /
  HID+HID_GENERIC+USB_HID
- Image: 17,377,792 → 16,099,840 (-1248KiB, -7.4%)

適用時に踏んだ「黙って負ける」2 メカニズム (どちらもエラーにならない):
1. **select による強制**: LATENCYTOP=y が KALLSYMS_ALL を select。fragment で
   `# CONFIG_KALLSYMS_ALL is not set` と書いても =y に戻る。select 元を消す
2. **KERNEL_FEATURES の適用順**: meta-raspberrypi が cfg/fs/vfat.scc を
   KERNEL_FEATURES で注入しており SRC_URI fragment より後に適用される。
   `KERNEL_FEATURES:remove = "cfg/fs/vfat.scc"` が必要
検出手段は最終 .config の実測確認のみ (bitbake -e にも出ない)。

計測 (A/B OTA 経由 — ota-update.sh で slot B へ配信 → tryboot → commit、
それ自体が A/B 更新フローの初の実運用検証になった。1.5GB を 87.7MB/s):

| | 旧 17.4MB (n=11) | 新 16.1MB (n=6) | 差 |
|---|---|---|---|
| Starting OS | 7000.5ms σ14.6 | 6970.2ms σ16.0 | **-30ms** (有意) |
| カーネル読込 | 498ms | 466ms | -32ms (予測 -37ms と整合) |
| カーネル init | 701ms | 702ms | ±0 |
| GUI 到達 | 1587ms σ24 | 1593ms σ36 (n=4) | +6ms (ノイズ) |

電源→GUI ≈ **8.56s**。init が ±0 なのは、モジュール化した SCSI/xhci/HID の
ロードが weston のクリティカルパス外で並行処理されている証拠。vfat の
自動ロード (/boot)、LTE 用 USB スタック、tailscale (IPv4 のみ) の動作を
実機で確認済み。

**結論: RPi5 の設定レベル削減はこれで枯渇。** 残 16.1MB の大半は
ext4/NVMe/DRM+SND/MMC/ネットコアの不可侵領域。次の 30ms を探すより、
i.MX 側の 46.6MB (arm64 defconfig 未スリム) に取り組む方が桁違いに効く。
