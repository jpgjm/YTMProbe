# YTMProbe

YouTube Music (`com.google.ios.youtubemusic`) に注入して、
**ViviMusic から公式の再生エンジンを駆動できるか**を確かめる検証専用の tweak。

## なぜ作るのか

ViviMusic は 2026-08 以降、googlevideo の 1 MiB 制限に当たって
再生ができなくなっている。rev.85〜87 で切り分けた結果はこう。

| 候補 | 結果 |
| --- | --- |
| サインイン状態 | 公式アプリのコンテナを 3 回取得して比較 → 無関係 |
| `visitorData` の鮮度・分離 | 同一 `visitorData` で 7.25 MiB 取得を確認 → 無関係 |
| リクエスト形状 (SABR/UMP) | `StreamerContext.visitorData` / poToken 紐づけ統一 / `elapsed_wall_time_ms` / `buffered_ranges` 累積をすべて直しても `StreamProtectionStatus = 2` は解けず、取得量は 1,105 KiB でバイト単位まで同一 → 無関係 |

一方、YTLite / YTKillerPlus のような **公式バイナリに dylib を注入した
tweak は 1 MiB 制限に当たっていない**。リクエストを組み立てているのが
Google 自身のコードだから。

そこで「ViviMusic の UI + 公式の再生エンジン」という構成が成立するかを
確かめる。**成立しなければ、その時点で撤退できる。**

## この tweak が確かめること

| Step | 内容 |
| --- | --- |
| 1 | 注入した dylib が読み込まれ、アプリが落ちない |
| 2 | 必要なクラスとセレクタが実在する (名前は推定なので) |
| 3 | `videoId` を渡して実際に再生が始まる ← **本命** |

Step 3 が通れば設計が確定する。ViviMusic 本体には一切触らない。
SigProbe / QSProbe と同じで、先に最小の検証物で成立を確かめる。

## 仕組み

バイナリから抽出した ObjC のシンボルを使う。C++ 層
(`youtube::media::SingleSabrFetcher` など) には触れない。

```
YTMAppDelegate                             起動を検知してパネルを出す
  └ YTCommandRouter                        コマンドの実行先
      └ dispatchCommand:fromSender:completion:
           ↑ ここに YTICommand を投げる

YTIWatchEndpoint { videoId }               「この動画を再生しろ」
  └ YTIWatchEndpointRoot.watchEndpoint     YTICommand に載せる extension
```

`setVideoId:` で `videoId` を入れ、`setExtension:value:` で `YTICommand`
に載せ、`YTCommandRouter` に投げる。これが「再生しろ」の正規ルート。

`YTCommandRouter` の**インスタンスの取り方**が未確定なので、
AppDelegate と SceneDelegate のプロパティを総当たりで探す。
見つからなければプロパティ一覧をログに出して手掛かりにする。

## 安全側に倒した設計

- **元の挙動を変えない。** フローティングパネルを 1 個足すだけ。
- 呼ぶ前に必ず `respondsToSelector:` で存在を確認する。
  推定した宣言が外れていても落ちないようにするため。
- 結果はすべて画面上のログビューに出す。SideStore 環境では
  Xcode のコンソールが使えないため。
- App Store からの正規インストールでは何もしない
  (`appStoreReceiptURL` の有無で判定)。

## 使い方

### ビルド

GitHub Actions の `Build YTMProbe IPA` を手動実行する。

| 入力 | 内容 |
| --- | --- |
| `ipa_url` | 復号済み YouTube Music IPA の URL (必須) |
| `display_name` | ホーム画面の名前 (既定: `YTM Probe`) |
| `bundle_id` | 公式と併存させるなら変える (既定: `dev.vivimusic.ytmprobe`) |

IPA はリポジトリに置かない。サイズ (197 MB) と配布の問題があるため。

ワークフローは注入前に次を検証する。ここで弾かれたら入力を見直す。

- ZIP であること
- `Payload/YouTubeMusic.app/` があること
- **`cryptid = 0`** であること (暗号化されたままだと動かない)
- dylib が **arm64** であること

### 実機で

1. SideStore で入れて起動する
2. 3 秒後に画面下部にパネルが出る
3. **「シンボル確認」** を押す → 推定した宣言が実在するか
4. **「再生を試す」** を押す → 固定の `videoId` で再生を試みる
5. **「ログをコピー」** で結果を取り出す

## 見るべきところ

### シンボル確認

```
  OK   YTICommand
  OK   YTIWatchEndpoint
  なし YTIWatchEndpointRoot        ← 名前が変わっている。要修正
  OK   -[YTCommandRouter dispatchCommand:fromSender:completion:]
===== 確認終わり (不足 1 件) =====
```

`なし` が出たものは `YTMHeaders.h` の宣言を直す。
YouTube Music はほぼ毎週更新されるので、更新のたびにここを最初に見る。

### 再生

```
エンドポイント作成: <YTIWatchEndpoint: ...>
コマンド作成: <YTICommand: ...>
探索: YTMAppDelegate
  見つかった: commandRouter = YTCommandRouter
dispatchCommand を呼んだ
===== 結果: 成功 (再生が始まったはず) =====
```

`CommandRouter が見つからない` で止まった場合は、
その直前に出るプロパティ一覧が手掛かりになる。

## v0.1.1 のビルド修正

初回ビルドが 2 件のエラーで止まった。

```
error: performSelector may cause a leak because its selector is unknown
       [-Werror,-Warc-performSelector-leaks]
```

ARC は戻り値を retain すべきか (メソッド名が alloc/copy/new/init で
始まるか) を **セレクタ名から** 判断する。名前が実行時にしか
分からないと判断できないので警告になる。Theos は既定で `-Werror`
なのでビルドが止まる。

警告を抑制するのではなく `NSInvocation` に寄せた。戻り値の扱いを
明示でき、`dispatchCommand:` で既に使っている方式とも揃う。

- `YTMProbeInvoke(target, selector, object, returnsObject)` を追加
- `setVideoId:` と `watchEndpoint` の呼び出しを置き換え

あわせて `-Werror` で止まりうる箇所を先回りして直した。

- `UIApplication.keyWindow` (iOS 13 で非推奨) を使わない
  `YTMProbeKeyWindow()` に統一
- ログ sink の未使用引数を `(void)line;` で明示

`Makefile` には、この tweak では避けようがない警告だけを個別に
外す指定を入れてある (`-Wno-deprecated-declarations` /
`-Wno-arc-performSelector-leaks` / `-Wno-unused-parameter`)。
**`-Werror` 自体は残す。** それ以外の警告はビルドを止めてよい。

## v0.1.2 のワークフロー修正

コンパイルとリンクは通ったが、Theos が最後に `ldid` で dylib へ
署名するところで止まった。

```
Compiling YTMProbe.x (arm64)…     OK
Linking tweak YTMProbe (arm64)…   OK
Generating debug symbols…          OK
Signing YTMProbe…
bash: ldid: command not found      <-- ここ
```

macOS runner に `ldid` は入っていない。ワークフローの不備。

- `brew install ldid` のステップを Theos の前に追加
- SDK 取得を「特定版を試して駄目なら全部」から「全部入れて一覧を出す」
  に変更。`TARGET` が要求する版が無いときに気付けるようにした
- `Verify dylib` で `*.unsigned` を拾わないよう明示。
  署名に失敗しても中間物だけ残ることがあり、それを注入すると
  実機で起動時に落ちる
- 見つからなかったときは `.theos` の中身を出して手掛かりにする

## v0.1.3 のワークフロー修正

SDK の配置で止まった。

```
cp: /tmp/sdks/AppleTVOS10.2.sdk/.../IOKit.framework: No such file or directory
Error: Process completed with exit code 1
```

原因は 2 つ。

**① macOS の `cp -r` はシンボリックリンクを追跡する**

BSD 版の `cp -r` はリンク先をたどってコピーする
(リンクのまま運ぶのは `-R`)。`theos/sdks` はフレームワーク内で
相対シンボリックリンクを多用しており、リポジトリ単体では解決
できないものが混じっているため、そこで止まる。

実測: `iPhoneOS16.5.sdk` だけでもシンボリックリンクが 72 個ある。

`rsync -a` に変更した。リンクをリンクのまま運ぶので通る。

**② tvOS / watchOS まで取っていた**

必要なのは iOS SDK だけ。`sparse-checkout` で `iPhoneOS*.sdk` に絞った。

```bash
git clone --depth=1 --filter=blob:none --sparse https://github.com/theos/sdks.git
git sparse-checkout set --no-cone 'iPhoneOS*.sdk'
```

実測: iOS SDK 8 個で 1.2 GB。全部取ると数 GB になる。

### あわせて Makefile を調整

`TARGET` の SDK 版を固定していると、取得できた SDK に追随できない。
無い版を指定すると Theos が黙って別の版に落とすことがあり、
後から分かりにくい失敗になる。

```make
YTMPROBE_SDK ?= latest
TARGET := iphone:clang:$(YTMPROBE_SDK):15.0
```

CI では取得できた中で最新を使う。ローカルで固定したいときは
`make YTMPROBE_SDK=16.5` で上書きできる。

## v0.1.4 のワークフロー修正

dylib のビルドは通った。IPA の検証で止まった。

```
Error: IPA ではありません (検出: application/x-ios-app)
```

`file --mime-type` は IPA を `application/zip` とは限らず
`application/x-ios-app` と判定する。`Payload/` を含む ZIP を
iOS アプリとして認識するため。手元の IPA でも再現した。

MIME 名を並べて許可しても取りこぼすので、**中身で判定**するよう変更。

- ZIP として開けるか (`unzip -tqq`)
- `Payload/YouTubeMusic.app/` があるか
- 本体バイナリが復号済みか (`cryptid = 0`)

ZIP として開けない場合は先頭 200 バイトを出す。URL が HTML や
エラーページを返しているとここで分かる。

### 注入後の検証を追加

`cyan` は dylib を入れ損ねても成功で終わることがある。
成果物を渡す前に中身を確かめる。

- `Payload/*.app/Frameworks/YTMProbe.dylib` があるか
- 本体バイナリに `LC_LOAD_DYLIB` が追加されたか (`otool -L`)
- bundle id と表示名が反映されたか

同梱されていても `LC_LOAD_DYLIB` が無ければ読み込まれない。
両方見る必要がある。

### 手元での実測

`cyan -i test.ipa -o out.ipa -uwes -n "YTM Probe" -b dev.vivimusic.ytmprobe`

```
[*] removed app extensions
[*] changed name to "YTM Probe"
[*] changed 79 localized names
[*] changed bundle id to "dev.vivimusic.ytmprobe"
[*] removed UISupportedDevices
[*] removed watch app
[*] fakesigned 1 item(s)
```

| | サイズ |
| --- | --- |
| 元 IPA | 76.4 MiB |
| 加工後 | 73.9 MiB |

`.appex` は 252 エントリすべて除去された。**無料 Personal Team は
App ID が週 10 個までで拡張ひとつごとに枠を消費する**ので、
`-e` は容量だけでなく枠の節約にも効く。

## v0.1.5 のワークフロー修正

`Install cyan` で止まった。

```
error: externally-managed-environment
× This environment is externally managed
```

macOS runner の Python は Homebrew 管理下にあり、PEP 668 の
「外部管理環境」になっている。素の `pip install` は弾かれる。

エラーメッセージは `--break-system-packages` を勧めるが、
Homebrew 自身が「Homebrew の導入を壊しうる」と警告している方法。
**venv を使う。** 隔離されるので副作用が無い。

```bash
python3 -m venv /tmp/cyanenv
/tmp/cyanenv/bin/python -m pip install <pyzule-rw>
echo "/tmp/cyanenv/bin" >> "$GITHUB_PATH"
```

`GITHUB_PATH` に通すので、以降のステップから `cyan` を直接呼べる。

手元で検証済み。`cyan v1.4.4` が入り、PATH 経由で IPA の加工まで通った。

ワークフロー内の他の `python3` は `plistlib` / `struct` しか使わず
pip を必要としないので、そのままでよい。

## v0.2.0 — 実機での初回結果と対応

注入は完全に成功した。パネルが出て、シンボル確認も走った。

```
YTMProbe 読み込み (AppStore=いいえ / bundle=dev.vivimusic.ytmprobe)
YTMAppDelegate 起動を検知
パネルを表示した
===== シンボル確認 =====
  OK   GPBMessage / GPBExtensionDescriptor / YTICommand
  OK   YTIWatchEndpoint / YTIWatchEndpointRoot
  OK   YTCommandRouter / YTAccountScopedCommandRouter
  OK   YTMAppDelegate / YTMSceneDelegate / YTMNavigationController
  OK   YTMWatchViewController / YTMQueuePersistenceController
  OK   +[YTIWatchEndpointRoot watchEndpoint]
  なし -[YTCommandRouter dispatchCommand:fromSender:completion:]
  なし -[YTAccountScopedCommandRouter dispatchCommand:fromSender:completion:]
  OK   -[YTIWatchEndpoint setVideoId:]
===== 確認終わり (不足 2 件) =====
```

問題は 2 つ。

### ① dispatchCommand の実装クラスが別

クラスは存在するのにセレクタに応答しない。バイナリの文字列表には
セレクタがあるので、**別のクラスが実装している**。`YTCommandRouter` は
プロトコル的な基底で、実体が `〜Impl` のような別名の可能性が高い。

名前を推測するより確実な方法として、**ランタイム総当たり**を入れた。

- `objc_copyClassList` で全クラスを走査し、
  `class_getInstanceMethod` で実装を持つクラスを探す
- 名前が `YT` / `GPB` / `SSO` / `ML` で始まるものだけに絞る
  (全クラスを `respondsToSelector:` に掛けると、初期化していない
  クラスに触れて落ちることがある)
- `CommandRouter` のインスタンス探索も、プロパティ名の決め打ちから
  「値を取って `dispatchCommand` に応答するか見る」総当たりに変更

YouTube Music が更新されて名前が変わっても追随できる。

### ② Google ログインが拒否される

```
ログインできませんでした
Google で安全性を確認できないため、このアプリにはログインできません。
```

原因は bundle ID を `dev.vivimusic.ytmprobe` に変えたこと。
Google の OAuth クライアントは

```
client_id  755973059757-iigsfdoqt2c4qm209soqp2dlrh33almr
bundle     com.google.ios.youtubemusic
```

の組で登録されており、bundle ID が違うと認証サーバーが拒否する。

**YouTube Music は未ログインでは 1 曲も再生できない**ことを実測で
確認済みなので、これが通らないと検証自体が成立しない。

そこで YTLite の `Sideloading.x` と同じ手法を入れた。

偽装するのは **アプリが自分自身に対して答える文字列** だけ。

| フック | 戻す値 |
| --- | --- |
| `NSBundle.bundleIdentifier` | `com.google.ios.youtubemusic` |
| `NSBundle.infoDictionary` | `CFBundleIdentifier` を差し替え |
| `YTVersionUtils.appID` | 同上 |
| `GPCDeviceInfo.bundleId` | 同上 |
| `SSOConfiguration._applicationIdentifier` | 同上 |
| `GULAppEnvironmentUtil.isFromAppStore` | `YES` |

偽装「できない」ものは実行時に本物を問い合わせる。

| | 理由 |
| --- | --- |
| Keychain access group | Team ID から導出されカーネルが強制する。ダミー項目を通して本物を聞く |
| App Attest の証明書 | Apple が署名し App ID が焼き込まれる。偽装不可 |

App Attest は偽装できないままだが、tweak IPA が普通に動いている
実績から、通常の再生には要求されていないと見ている。

これらは `%group Sideloading` にまとめ、**サイドロード時のみ**
有効にする (`appStoreReceiptURL` の有無で判定)。

### v0.2.1 のビルド修正

v0.2.0 で追加した `YTMProbeClassesImplementing` を、定義より前
(155 行目、定義は 279 行目) で呼んでいた。

```
error: call to undeclared function 'YTMProbeClassesImplementing'
error: implicit conversion of 'int' to 'NSArray<NSString *> *' is disallowed with ARC
error: incompatible integer to pointer conversion initializing ...
error: static declaration of ... follows non-static declaration
```

4 件出ているが原因はひとつ。C は宣言の無い関数を「int を返す」と
みなすため、ARC の型チェックと static 宣言の食い違いが連鎖する。

**ファイル冒頭に前方宣言をまとめた。** この tweak は「実機で分かった
ことを受けて関数を足す」進め方をするので、定義の物理的な位置に
依存しない形にしておく。

以後、静的関数を追加したら **まず冒頭の前方宣言に 1 行足すこと。**

現在の宣言 (8 個、すべて実定義とシグネチャ一致を確認済み):

```
YTMProbeClassesImplementing / YTMProbeKeyWindow / YTMProbeInvoke
YTMProbeFindCommandRouter   / YTMProbeAccessGroupID
YTMProbeIsMainBundle        / YTMProbeVerifySymbols / YTMProbePlayVideo
```

## v0.2.2 — 起動時クラッシュへの対応

LiveContainer で起動時に落ちた。

```
-[__NSPlaceholderArray initWithObjects:count:]:
  attempt to insert nil object from objects[0]
```

スタックは YouTube Music の内部で、どのフックが引き金かは外からは
分からない。v0.2.0 で追加した偽装フックのどれかが nil を生んでいる。

v0.1.5 (パネルが出てシンボル確認まで動いた版) との差分はこれだけなので、
偽装フックが原因なのは確実。

### 1 つずつ切り分けられるようにした

まとめて有効/無効にするだけでは特定できないので、5 つのグループに分けた。

| グループ | 内容 | 危険度 |
| --- | --- | --- |
| `SpoofAppID` | `YTVersionUtils.appID` / `GPCDeviceInfo.bundleId` | 低（YTM 自身のクラスのみ） |
| `SpoofSSO` | `SSOConfiguration._applicationIdentifier` | 低（ログイン対策の本命） |
| `RealKeychainGroup` | Keychain access group を実行時に問い合わせ | 中 |
| `SpoofAppStore` | `GULAppEnvironmentUtil.isFromAppStore` → YES | 中（レシート不在で nil を掴む恐れ） |
| `SpoofBundleID` | `NSBundle.bundleIdentifier` / `infoDictionary` | **高** |

`SpoofBundleID` が最も疑わしい。`%hook NSBundle` はプロセス内の
すべての NSBundle に効くため、LiveContainer 自身も巻き添えになる。
`bundle == [NSBundle mainBundle]` で絞ってはいるが、LiveContainer は
ゲストアプリのバンドルを差し替えるので、起動の早い段階では
mainBundle が LiveContainer 自身を指す可能性がある。

**既定はすべて無効。** v0.1.5 と同じ状態から始める。

### 起動できなくなる事故を防ぐ

起動時にしかフックは掛けられないので、落ちる設定にするとパネルまで
辿り着けず、二度と起動できなくなる。そこで安全装置を入れた。

- `%ctor` で「起動を始めた」を UserDefaults に記録
- パネルが出たら「完走した」に更新
- 次の起動時、記録が「started のまま」なら **全フックを無効に戻す**

```
⚠ 前回の起動が完走しなかった。偽装フックをすべて無効に戻す
```

これで、どの組み合わせを試しても入れ直しは不要。

### 使い方

パネルに「フック」ボタンを追加した。

1. 起動する（この時点では全部無効。v0.1.5 相当）
2. 「フック」→ 一番上の `SpoofAppID` を有効にする
3. アプリを終了して再起動
4. 落ちなければ次を有効にする。落ちたら自動で全部無効に戻るので、
   その 1 つが原因

一覧は **安全な順** に並べてある。上から 1 つずつ試すのが早い。

### v0.2.3 のビルド修正

v0.2.2 で追加した `YTMProbeSettings` を、`@interface` (713 行目) より前
(648 行目、パネルの `onHooks`) で使っていた。

```
error: use of undeclared identifier 'YTMProbeSettings'
```

v0.2.1 で静的関数について同じことを踏んだのに、ObjC クラスで
繰り返した。**関数もクラスも、宣言はすべて冒頭にまとめる**方針に
統一した (`YTMProbeLog` / `YTMProbeSettings` / `YTMProbePanel`)。

### check.py を追加

この環境では ObjC を実際にコンパイルできない (Foundation / UIKit が
無い) ため、ビルドエラーは GitHub Actions を 1 往復しないと分からない。
1 往復が長いので、**実際に踏んだ失敗をそのまま検査項目にした**
静的点検スクリプトを用意した。

```bash
python3 check.py
```

| 検査 | 由来 |
| --- | --- |
| 宣言より前で使っていないか | v0.2.1 / v0.2.3 で 2 回踏んだ |
| 前方宣言と実定義のシグネチャ一致 | 追加時のずれを防ぐ |
| `@interface` / `@implementation` の重複 | 冒頭へ移した際の消し忘れ |
| Logos の対応 (`%hook`/`%group`↔`%end`、`%group`↔`%init`) | |
| `-Werror` で止まる書き方 | v0.1.1 で踏んだ |
| 括弧の対応 / `@selector` の参照先 | |

コメント行は空行に潰してから判定するので、コメント内の記述を
「使用」と誤判定しない。

**コミット前に必ず走らせること。** 型エラーまでは見つけられないが、
今回の 3 回のビルド失敗はすべてこれで防げた。

## v0.2.4 — クラッシュ原因の特定と、より単純な再生経路

### クラッシュ原因は SpoofBundleID と確定

他の 4 つを同時に有効にしても起動できた。

```
有効な偽装フック: SpoofAppID, SpoofSSO, RealKeychainGroup, SpoofAppStore
YTMAppDelegate 起動を検知
Keychain access group: 48A5LFNW96.com.kdt.livecontainer.shared.91
パネルを表示した
```

`%hook NSBundle` はプロセス内のすべての NSBundle に効くため、
LiveContainer 自身が巻き添えになったと見られる。実行時に取れた
Keychain access group が **LiveContainer のもの**
(`com.kdt.livecontainer.shared.91`) であることがその傍証。
ゲストアプリのバンドルが差し替わる環境なので、`mainBundle` 判定では
絞りきれていない。

`SpoofBundleID` は残してあるが、**LiveContainer では有効にしないこと。**
SideStore で直接入れた場合に試す。

### dispatchCommand の実装クラスは YTELMDispatcher

ランタイム総当たりで判明した。

```
なし -[YTCommandRouter dispatchCommand:fromSender:completion:]
  → 実装クラスをランタイムから探す…
  → 実装あり: YTELMDispatcher
```

ELM は YouTube の UI フレームワーク (Elements) のことらしく、
`YTCommandRouter` はプロトコル的な基底に過ぎないと思われる。

ただし**インスタンスの取り方**が分からない。AppDelegate の直下には
居なかったので、ivar を辿るグラフ探索を追加した (深さ 4、400 個で打ち切り)。

### URL 経由の再生を主経路にした

Info.plist を見たところ、YouTube Music は URL スキームと
openURL ハンドラを持っていた。

```
CFBundleURLSchemes: youtubemusic / vnd.youtube.music /
                    vnd.youtube.music-broad-matching / youtubemusicsdk …
ハンドラ: application:openURL:options: / scene:openURLContexts:
```

**protobuf を組むより圧倒的に単純で壊れにくい。**
フィールド番号にも非公開クラスの内部構造にも依存せず、
YouTube Music が更新されても URL の形は変わりにくい。

パネルに「URL再生」ボタンを追加し、3 つの形を順に試す。

```
https://music.youtube.com/watch?v=<id>   Universal Link
youtubemusic://watch?v=<id>              独自スキーム
vnd.youtube.music://<id>                 旧来の形
```

ViviMusic から再生を駆動する本番でも、この経路で足りるなら
そのほうがずっと保守しやすい。

### check.py が実際に効いた

`YTMProbeSearchGraph` を追加した際、定義が前方宣言より前に来ていた。
ビルドする前に検出できた。

```
NG  static YTMProbeSearchGraph()  宣言 L172 / 使用 L123
```

## v0.2.5 — ログインが通らない原因

`SpoofSSO` を有効にしてもログインは拒否されたままだった。
原因は **フック先のセレクタが存在しなかった** こと。

```objc
// v0.2.0〜v0.2.4 (効いていなかった)
%hook SSOConfiguration
- (id)initWithClientID:(id)clientID supportedAccountTypes:(id)types { ... }
%end
```

`initWithClientID:supportedAccountTypes:` は私の推定で、
バイナリには存在しないセレクタだった。

**Logos は存在しないメソッドを `%hook` すると新規追加してしまう。**
呼ばれないまま何も起きないので、「フックしたのに効かない」という
分かりにくい失敗になる。エラーも警告も出ない。

### 実際にあるもの

```
T@"NSString",C,N,V_applicationIdentifier   readonly プロパティ
applicationIdentifier                       ゲッター
initWithClientID:allowMultiActiveAccounts:enableNoAccountMode:
  enableIncognitoMode:enableIncognitoWipeout:showDefaultAccountSelector:
  sharedContainerForProfileEnabled:omitAppNameInButtonsAndVoiceOver:
  applicationIdentifier:
```

init は引数が 9 個あり壊しやすいので、**ゲッターを直接差し替える**。
誰がいつ呼んでも公式の bundle ID が返る。

```objc
%hook SSOConfiguration
- (NSString *)applicationIdentifier {
    return @"com.google.ios.youtubemusic";
}
%end
```

初回呼び出し時に元の値をログへ残すので、効いているかが分かる。

### フック先の実在確認を追加

同じ失敗を繰り返さないよう、シンボル確認で **フックしている先が
実在するか** を毎回確かめるようにした。

```
----- フック対象の実在確認 -----
  OK   +[YTVersionUtils appID]
  OK   +[GPCDeviceInfo bundleId]
  OK   +[GULAppEnvironmentUtil isFromAppStore]
  なし -[SSOConfiguration applicationIdentifier]   ← これが出たら効かない
  ...
  (「なし」はフックしても効きません)
```

### check.py の誤検出を修正

括弧の対応を数えるとき、ログ文言に含まれる
`-[YTIWatchEndpoint setVideoId:]` の `]` を数えて誤検出していた。
文字列リテラルの中身を潰してから数えるようにした。

## v0.3.0 — ホストを YouTube 本体に切り替え

### YouTube Music は詰みだと確定した

未ログインで「URL再生」を試したところ、3 形式とも「受理」を返したが、
画面はオンボーディング (「楽しめる音楽は 1 億曲以上」+ ログインボタン)
のまま動かなかった。**未ログインでは 1 曲も再生できない。**

そしてログインは App Attest の壁で通らない。v0.2.5 で
`SSOConfiguration.applicationIdentifier` の偽装が効いた
(ログに `dev.vivimusic.ytmprobe → com.google.ios.youtubemusic` が出た)
にもかかわらず拒否されたことが、その証拠になっている。

```
YTM で再生する → ログインが要る
ログインする   → App Attest が要る
App Attest     → サイドロード再署名では原理的に不可能
```

### YouTube 本体なら壁を迂回できる

**YouTube 本体は未ログインで全機能が使える。** YTLite /
YTKillerPlus などの tweak が未ログインで動いており、しかも
1 MiB 制限に当たっていない。ログインが要らないなら App Attest の
壁は関係なくなる。

必要なクラスは両アプリで共通だった (同じ内部フレームワークを共有)。

```
YTAppDelegate / YTICommand / YTIWatchEndpoint / YTIWatchEndpointRoot
YTCommandRouter / YTELMDispatcher / GPBMessage / GPBExtensionDescriptor
YTVersionUtils / GPCDeviceInfo / GULAppEnvironmentUtil   すべてあり
```

違うのは AppDelegate の名前と bundle ID、URL スキームだけ。

| | YouTube Music | YouTube 本体 |
| --- | --- | --- |
| AppDelegate | `YTMAppDelegate` | `YTAppDelegate` |
| bundle id | `com.google.ios.youtubemusic` | `com.google.ios.youtube` |
| URL | `youtubemusic://` `vnd.youtube.music://` | `youtube://` `vnd.youtube://` |
| IPA (加工後) | 73.9 MiB | 98.3 MiB |
| ログイン | **必須** | 不要 |

### 同じ dylib で両対応にした

`YTMProbeHostIsMusic()` が `YTMAppDelegate` の有無で実行時に判別し、
bundle ID と URL スキームを切り替える。AppDelegate のフックは
`%hook` がクラス名を静的に取るため両方書き、`%ctor` で実在するほうだけを
`%init` する。中身は `YTMProbeInstallPanel()` に寄せた。

ワークフローに `host_app` 入力 (`youtube` / `youtubemusic`) を追加。
既定は `youtube`。

### あわせて SSOKeychainCore のフックを削除

実機の「フック対象の実在確認」で `なし` と出たクラス。
存在しないメソッドを `%hook` すると Logos が新規追加してしまうので外した。

### v0.3.1 — YouTube 本体の URL 入口を探す

ホスト切り替えは成功した。

```
ホスト: YouTube 本体 (未ログインで再生できるので App Attest を迂回できる)
YTAppDelegate 起動を検知 (YouTube 本体)
```

偽装フックも全部不要になった (`有効な偽装フック: なし`)。
未ログインで使うので、身元を偽る必要がそもそも無い。

ただし URL 再生が動かなかった。

```
application:openURL:options: が無い
```

バイナリにセレクタ自体は存在するので、**実装しているのが
YTAppDelegate ではない**。YouTube は `YTURLHandler` や
`YTAppDeepLinkCommandHandler` という専用クラスを持っている。

**変更点**

- 決め打ちをやめ、4 種類のセレクタを順に試す
  (`application:openURL:options:` /
   `application:openURL:sourceApplication:annotation:` /
   `application:handleOpenURL:` / `handleURL:`)
- AppDelegate に無ければ **オブジェクトグラフを辿って** 応答するものを探す
- どれも当たらなければ `YTMProbeDumpURLHandlers()` が手掛かりを出す
  - AppDelegate の URL 関連メソッド一覧
  - 各セレクタを実装しているクラスをランタイムから列挙

- シンボル確認をホスト別に分けた。`YTM*` は Music 専用なので
  YouTube 本体では見ない (「なし」が 5 件並んで本当の問題が埋もれていた)。
  YouTube 側では `YTURLHandler` / `YTAppDeepLinkCommandHandler` /
  `YTWatchController` を見る。

## 前提と注意

- **サインインが要る。** YouTube Music は未ログインでは 1 曲も
  再生できないことを実測で確認している
  (ゲスト scope のメディアキャッシュが 1 つも作られない)。
- YouTube Music はほぼ毎週更新される。クラス名やセレクタが変われば
  `YTMHeaders.h` の追随が要る。
- 復号済み IPA の入手経路を継続的に確保する必要がある。
  ここが詰まると運用が止まる。

## ライセンス

検証用のため未定。ViviMusic 本体 (GPL-3.0) のコードは含んでいない。

プロプライエタリなバイナリに注入したものを配布するとライセンス上の
問題になりうるので、**成果物は配布しない**方針で運用する。
