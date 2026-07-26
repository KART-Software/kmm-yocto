# A/B (tryboot) OTA アップデートの仕組み

2026-07-26 実装・実機検証済み。運用手順は [README](../README.md#ota-アップデートabssd-抜き差し不要) を参照。本書は**仕組みと設計判断**の記録。

## パーティションレイアウト

`meta-kart/wic/kart-rpi5-{nvme,sdcard}-ab.wks`:

| # | ラベル | FS | サイズ | 役割 |
|---|--------|----|--------|------|
| p1 | AUTOBOOT | FAT | 4M | `autoboot.txt` のみ（起動面セレクタ）。ビルド時に生成し rawcopy |
| p2 | BOOTA | FAT | 256M | firmware + kernel + config.txt/cmdline.txt（A面） |
| p3 | BOOTB | FAT | 256M | 同（B面）。工場イメージでは空 |
| p4 | — | — | — | 拡張パーティション |
| p5 | roota | ext4 | 1536M 固定 | rootfs A面（read-only 運用） |
| p6 | rootb | ext4 | 1536M 固定 | rootfs B面。工場イメージでは空 |
| p7 | data | ext4 | 128M | **A/B 共有**の永続領域（tailscale 識別・ログ）。OTA で消えない |

root を `--fixed-size` にしているのは **dd によるスロット間コピーが常に成立する**ようにするため。

## 起動面の選択フロー（ファームウェアの動作）

```
電源ON → EEPROM ブートローダ
  ├─ EEPROM 設定 BOOT_ORDER=0xf16 …… どのメディアか (NVMe→SD→リトライ)
  ├─ EEPROM 設定 boot_partition=1 …… 最初に見るパーティション（=p1 セレクタ）
  ▼
p1 の autoboot.txt を読む
  ├─ SoC レジスタの tryboot フラグが立っている?
  │    NO  → [all]     の boot_partition (2 or 3)   ← 恒久設定
  │    YES → [tryboot] の boot_partition、フラグをクリア ← 1回限り
  ▼
選ばれた BOOT 面の FAT から config.txt / kernel / cmdline.txt をロード
  └─ cmdline.txt の root= (p5 or p6) が rootfs 面を決める
```

**役割分担**（どこに何が保存されているか）:

| 場所 | 決めること | 書き換え頻度 |
|------|-----------|-------------|
| EEPROM (`BOOT_ORDER`/`boot_partition`) | メディアと入口 | ほぼ一度（`kart-eeprom-setup`） |
| p1 `autoboot.txt` | **A/B どちらか** + tryboot 分岐先 | OTA の commit ごと |
| SoC レジスタ (PM_RSTS) | 次の1回だけ [tryboot] を使うか | `reboot '0 tryboot'` ごと |
| 各 BOOT 面の `cmdline.txt` | その boot 面が対にする rootfs 面 | スロット書込みごと（updater が root= を修正） |

A/B 選択を EEPROM に置かない理由: EEPROM 書き換えは自己更新サイクルが必要で電源断に弱い。`autoboot.txt` はただの FAT ファイルなので commit = rename 一発、電源がバツンと切れるカート環境に向く。tryboot フラグが**揮発レジスタ**なのも肝で、「失敗したら何もしなくても旧面に戻る」が物理的に保証される。

## 状態のプリミティブな確認方法

ツール（`kart-ab-status`）は以下を読んでいるだけ:

```bash
cat /proc/cmdline                # root=...p5 → A面で稼働中 / p6 → B面
mount -o ro /dev/nvme0n1p1 /mnt && cat /mnt/autoboot.txt   # 恒久設定
od -An -tu1 /proc/device-tree/chosen/bootloader/tryboot    # この起動が tryboot だったか (1/0)
```

`kart-ab-commit` がやるのは「`autoboot.txt` の [all]/[tryboot] の boot_partition を、今動いている面が [all] になるよう書き換える（temp ファイル → rename）」だけ。

## OTA の書き込み方式（scripts/ota-update.sh）

ホスト主導。wic からスロットイメージを抽出し、tailscale SSH で非アクティブ面へ:

| 対象 | 方式 | 理由 |
|------|------|------|
| rootfs | **dd**（転送前にホスト側で `e2label` + `tune2fs -U random`） | 速い。ラベル/UUID をスロット固有に直してから送ることで **p5/p6 のラベル・UUID 重複を防ぐ**（デバイスに e2fsprogs 不要） |
| boot 面 | **ファイルコピー**（mount して rm+cp、`cmdline.txt` の root= を sed） | dd だと BOOTA/BOOTB の**ラベルごと複製されて衝突**するため。ラベルは /boot マウント（下記）が依存 |

転送量実測: **約 211MB/回**（boot 22MB + root 189MB、gzip、2026-07-26 のイメージ）。LTE 経由は要注意、サーキットでは LAN/direct 推奨。

## /boot のマウント

fstab では「アクティブ面の boot」を表現できないため、`kart-boot-mount.service`（oneshot）が `/proc/cmdline` の root= を見て `LABEL=BOOTA` / `LABEL=BOOTB` を `/boot` にマウントする。`tailscale-autoconnect`（authkey 読取り）より前に実行。

## フェイルセーフ

- **起動失敗（カーネルパニック・リセット）**: tryboot フラグはリセットで消える → ファームが自動で旧面から起動。ホスト側は何もしなくてよい
- **ハング**: systemd の `RuntimeWatchdogSec=15`（HW watchdog）が強制リセット → 同上
- **commit し忘れ**: 次の再起動で旧面に戻るだけ（安全側に倒れる）
- **電源断（書込み中）**: 書いていたのは非アクティブ面なので現用面は無傷。やり直せばよい

## 実機検証記録（2026-07-26）

- 初回移行フラッシュ: `--keep-data` で data 引き継ぎ成功（tailscale 同一ノード維持・旧ログ残存）
- OTA A→B → commit → B→A → commit の2周を tailscale 経由で完走
- 起動時間: Starting OS 7293ms（旧レイアウト 7674ms より **-380ms**。autoboot.txt 読取りコスト +50ms の予想に反し、セレクタ経由の方が速かった）
- 既知の無害な残骸: 初回 OTA（e2label 修正前）で書いた面のラベルが旧名のまま残ることがある。何もラベル roota/rootb を参照しないため実害なし、次にその面へ OTA した時点で自動修正

## 制約・将来拡張

- 差分更新なし（毎回フルイメージ 211MB）。頻度が上がったら rsync ベース or casync を検討
- 署名検証なし（チーム内運用前提）。必要になったら RAUC への移行を検討 — パーティションレイアウトはそのまま使える
- QEMU は A/B 非対応（ext4 単発イメージのまま）
