# 08 — 暗ブート調査(SPL ロゴ後に真っ黒)の経緯と結論

**結論**: コールド起動で GUI が出ない「暗ブート」は、表示ハード(LCDIFv3 / HDMI PHY)でも
カーネル(takeover パッチ)でもなく、**weston 12.0.4.imx の kiosk-shell が「入力 seat が
できる前に commit したクライアント」を表示レイヤに載せない**バグだった。修正は
weston 側(13.0.1 へ切り替え、または 12 用パッチ)で、製品カーネルのまま
「weston を card0 直後に起動」する構成でも 10 コールド暗 0/10。
確定した機序と修正は [06-splash.md](06-splash.md) の該当節、未了事項は
[open-issues.md](open-issues.md) #9/#10。ここには**調査の道筋**を残す(どこで誤診し、
何が決め手になったか)。

## 1. 症状と計測条件

- 電源投入後、SPL スプラッシュ(ロゴ)は出るが、その後 GUI が出ず真っ黒のまま。
  `systemctl restart weston` で 100% 復旧。systemd 上は全ユニット active で無症状。
- 発生率は構成依存: 製品配置(weston は coldplug 完了後に起動)で 2〜3 割、
  「weston を card0 直後に起動」(30-boot-time #10 の -0.35s 構成、以下 **Y**)で ほぼ 100%。
- 判定は必ず 3 段 AprilTag パターン(tools/lcd-validation): SPL ロゴ → KLGO 形式の
  タグ画像、kart-splash-wl → `wl-image-view weston.raw`、kmm → `wl-image-view gui.raw`。
  カメラ輝度での明暗判定は GUI の暗部と黒が重なり使えない。
- 再現は製品カーネル(g276209957d88、BOOTA の `falcon.itb`)で行う。`uname -r` で確認。

## 2. 誤診の経緯(何を信じて、なぜ違ったか)

| 段階 | 観測 | 当時の解釈 | 実際 |
|---|---|---|---|
| 暗ブート板を生きたまま観測 | LCDIFv3 は DISP_ON/EN 全て ON、`INT_ENABLE_D0=0`、DRM の vblank カウンタ不動 | 走査エンジンが止まる latched wedge | 走査は正常。IRQ は DRM の `drm_vblank_offdelay`(5s)で使用者が居なくなり切れただけ(/proc/interrupts は commit 後 ~305 回 = 5s×60Hz で静止) |
| `INT_ENABLE_D0` に VS_BLANK を手で立ててもカウンタが動かない | IRQ 未武装は症状で走査停止が真因 | DRM 側 `vblank->enabled` が偽なら `drm_handle_vblank` はカウントしない。走査停止の証拠にならない |
| restart weston(完全 disable→enable)だけが直す | ハードの完全リセットが治療 | restart 時は udev 済みで seat が即座にできるから直る |
| drm-image-view(自作の最小 KMS クライアント)は同時刻でも 20/20 明 | 手続き(commit の種類)の差 | compositor を通らないので kiosk-shell の穴と無縁 |
| trace カーネル(ftrace / tracepoint)で暗率が変わる | 観測者効果でハードの競合が動く | udev 列挙とクライアント起動の相対タイミングが動いていた |
| カーネル 0018(初回 enable 後に走査検証)で製品配置 20 コールド暗 0/20 | 修正できた | 40ms のホールドで seat 生成がクライアント commit に間に合っただけ。Y では 10/10 暗 |

カーネル側の実験パッチ 0015〜0020(fb 切替のみ / handover reset / PLL 待ち / 走査検証と
回復 / pixclk 無停止 / PHY・PVI 維持)は Y で全て暗。weston の commit を blocking にする
パッチ(0002)も暗 10/10。これらは全て「表示ハードが止まる」前提の対策で、前提が誤りだった。

## 3. 決め手になった実験(実施順)

1. **strace で weston の DRM ioctl 列を採取**(製品カーネルのまま、非摂動)。暗 8 本と
   明(weston を 1s 遅らせた)1 本で、初回 ATOMIC までの列は完全同一。暗は ATOMIC 1 発の後
   DRM ioctl を一切出さない。
2. **LD_PRELOAD シム(`drm-atomic-dump`)で ATOMIC の中身をダンプ**: 暗/明でプロパティ・
   mode blob ともバイト同一。差は時刻だけ(暗 1.76s、明 2.89s)。
3. **初回 commit をシムで書き換え**(legacy SETCRTC 化 / blocking・event 無し / VRR・max bpc
   除去): 全て暗 3/3 → ioctl の形は無関係。
4. **環境の入れ替え**: drm-image-view を weston.service の中で(User=kart、seatd/kmm 稼働)
   走らせると明 3/3、weston を root + builtin seat で走らせると暗 3/3、drm-image-view に
   seatd 相当の VT ioctl を足しても明 6/6 → 差は weston プロセス内部。
5. **背景色を緑にして暗ブート**: 画面は緑(3/3)。**CRTC は weston の初回フレームを正常に
   走査している**。「暗」= weston の黒い背景が正しく表示され、二度と repaint されない状態。
6. **シムで DRM イベントの read を記録**: 暗でも初回 commit の FLIP_COMPLETE を weston は
   受信している(+40ms)。カーネル完全無罪。
7. **weston を `--logger-scopes=log,drm-backend,timeline` で起動**: 暗ブートでは
   初回 commit(1.78s)→ クライアント 2 つの commit_damage(1.78s)→ flip 完了(1.82s)→
   2 回目 repaint の scene graph に**クライアントのビューが無い**(背景ビューのみ)→ idle。
   明(1s 遅延)では 2 回目 repaint にクライアントのビューがある。
8. **kiosk-shell.c(12.0.4.imx)を読む**: `desktop_surface_committed()` はビューをレイヤに
   載せる処理を `kiosk_shell_surface_activate()` の中でしか行わず、それは
   `if (seat && kiosk_seat)` 条件付き。seat は libinput の udev 列挙(event0 = 2.1〜2.2s)で
   できる。Y ではクライアント commit(1.78s)が先 → is_mapped=true のままレイヤに入らない。
   明の 1s 遅延は event0 2.87s < commit 2.95s で seat が先。weston 13 は
   `kiosk_shell_output_set_active_surface_tree` で seat 非依存に載せるため該当しない。

## 4. 修正と検証

2 通りとも製品カーネル + Y + 3 段パターンで 10 コールド。GUI 段のクライアントは
weston READY + 300ms 後に起動(製品では Qt の kmm が splash より遅く map するのを模擬)。

| 修正 | 暗 | 表示順 | KLGO→splash | KLGO→GUI |
|---|---|---|---|---|
| なし(12.0.4.imx) | 8/8、11/11 | — | — | — |
| 12.0.4.imx + `0003-kiosk-shell-map-without-seat.patch` | 0/10 | SPL→splash→GUI 10/10 | 2.02〜2.13s | 2.46〜2.56s |
| **poky weston 13.0.1、パッチ無し** | 0/10 | SPL→splash→GUI 10/10 | 2.05〜2.13s | 2.45〜2.56s |

- 0003: seat が無くても normal_layer に挿入して damage、seat 生成時に最上位ビューを
  activate。12 に留まる場合の修正。PV が 12 のときだけ当たる。
- 13.0.1: `imx8mp-debix.conf` の `PREFERRED_VERSION_weston:imx8mp-debix = "13.0.1"`。
  meta-freescale は `:imx-nxp-bsp ??= "12.0.4.imx"` なので、machine オーバーライド付きの
  代入でないと負ける。GPU 不使用(pixman)のためフォーク固有機能は使っておらず、
  G2D の RDEPENDS 細工も不要になる。8MM/RPi5 と同じ weston に揃う。**こちらを採用**。

## 5. 未検証・残作業

- 製品配置(Y でない通常の起動位置)、本物の kart-splash-wl と Qt の kmm、フルイメージ
  経由(焼き直し/OTA)、電源→GUI の再計測(30-boot-time)。
- 実機は手載せ状態(open-issues「暫定状態」参照): weston 13 一式、weston-Y unit、
  kmm の検証用 drop-in、3 段パターン。次のフルイメージで正規化。
- ツリーの実験残骸(カーネル 0015〜0020、trace-debug.cfg、kas overlay 群)は削除済み。
  診断ツール(`drm-image-view`、`drm-atomic-dump`、`wl-image-view --delay-ms`)は残してある。

## 6. 教訓

- 「表示が出ない」は最初に **ハードが走査しているか**(背景色を変える)と
  **コンポジタが何を合成したか**(weston の timeline / drm-backend scope)を見る。
  レジスタ・クロック・カーネルトレースはその後。今回はこの順序を逆にして 2 日を失った。
- DRM の vblank カウンタと IRQ 回数は「使用者がいる間だけ」動く。走査の生死の指標にならない。
- カーネルにトレースを足すと userspace のタイミング(udev 列挙 vs クライアント起動)が
  動く。「観測者効果」を見たら、まず userspace のレースを疑う。
- 起動を速くするほどコンポジタ内部のレースが露出する。card0 直後起動(#10)は
  この修正が前提。
