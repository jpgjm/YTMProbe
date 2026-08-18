//
//  YTMHeaders.h
//  YTMProbe
//
//  YouTube Music (com.google.ios.youtubemusic) の内部クラス宣言。
//
//  ── どこから来た宣言か ──────────────────────────────────────
//
//  すべて YouTube Music 8.21.3 の本体バイナリ (arm64 / 146MB) から
//  抽出した ObjC のシンボル名に基づく。公式のヘッダは存在しないので、
//  ここでの宣言は「呼び出しに必要な最小限の形」を手で書いたもの。
//
//  引数や戻り値の型は推定を含む。実際の型が違っていても ObjC の
//  メッセージ送信は通ってしまうため、**必ず実機で確かめること。**
//  そのために YTMProbe は起動時にクラスとセレクタの存在を確認し、
//  ログに残すようにしてある。
//
//  ── バージョン依存 ──────────────────────────────────────────
//
//  YouTube Music はほぼ毎週更新される。クラス名やセレクタが変われば
//  ここも追随が要る。`YTMProbeVerifySymbols()` が起動時に
//  「見つからないもの」を列挙するので、更新のたびに最初に見る。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - GPBMessage (Google Protocol Buffers for ObjC)

/// protobuf の実体。InnerTube のコマンドやエンドポイントはすべてこれ。
@interface GPBMessage : NSObject
- (instancetype)init;
@end

/// extension の識別子。`YTICommand` に `watchEndpoint` を載せるのに使う。
@interface GPBExtensionDescriptor : NSObject
@end

@interface GPBMessage (YTMProbeExtensions)
- (void)setExtension:(GPBExtensionDescriptor *)extension value:(nullable id)value;
- (nullable id)getExtension:(GPBExtensionDescriptor *)extension;
- (BOOL)hasExtension:(GPBExtensionDescriptor *)extension;
@end

#pragma mark - InnerTube のコマンドとエンドポイント

/// InnerTube の「コマンド」。extension で具体的な動作がぶら下がる。
@interface YTICommand : GPBMessage
@end

/// 「この動画を再生しろ」を表すエンドポイント。
///
/// videoId だけでも動くはずだが、公式は playlistId / index / params も
/// 併せて送っている。まずは videoId だけで試し、駄目なら足していく。
@interface YTIWatchEndpoint : GPBMessage
@property (nonatomic, copy) NSString *videoId;
@property (nonatomic, copy) NSString *playlistId;
@property (nonatomic, copy) NSString *params;
@end

/// `YTICommand` に `watchEndpoint` を載せるための extension を持つ。
///
/// 命名規則は GPB の慣例どおり `<メッセージ名>Root` + クラスメソッド。
/// バイナリに `YTIWatchEndpointRoot_watchEndpoint` があることを確認済み。
@interface YTIWatchEndpointRoot : NSObject
+ (GPBExtensionDescriptor *)watchEndpoint;
@end

#pragma mark - コマンドの実行

/// コマンドを実際に処理するところ。
///
/// ── 実機で分かったこと (v0.2.4) ──────────────────────────
///
/// `YTCommandRouter` クラスは存在するのに
/// `dispatchCommand:fromSender:completion:` に応答しなかった。
/// ランタイム総当たりで探したところ、実装を持つのは
/// **`YTELMDispatcher` ただ 1 つ**だった。
///
/// ELM は YouTube の UI フレームワーク (Elements) のことらしく、
/// `YTCommandRouter` はプロトコル的な基底に過ぎないと思われる。
@interface YTCommandRouter : NSObject
- (void)dispatchCommand:(GPBMessage *)command
             fromSender:(nullable id)sender
             completion:(nullable void (^)(BOOL success))completion;
@end

/// `dispatchCommand:fromSender:completion:` の唯一の実装クラス。
/// ランタイム探索で判明した。
@interface YTELMDispatcher : NSObject
- (void)dispatchCommand:(GPBMessage *)command
             fromSender:(nullable id)sender
             completion:(nullable void (^)(BOOL success))completion;
@end

/// アカウントに紐づくコマンド実行。ログイン中はこちらが要るかもしれない。
@interface YTAccountScopedCommandRouter : NSObject
- (void)dispatchCommand:(GPBMessage *)command
             fromSender:(nullable id)sender
             completion:(nullable void (^)(BOOL success))completion;
@end

#pragma mark - アプリの骨格

/// YouTube Music の AppDelegate。
///
/// `commandRouter` を持っている見込み。持っていなければ
/// YTMProbe が起動時にプロパティ一覧をダンプするので、そこから探す。
@interface YTMAppDelegate : UIResponder <UIApplicationDelegate>
@end

/// YouTube 本体 (com.google.ios.youtube) の AppDelegate。
///
/// YouTube Music は未ログインだと再生できず、ログインは App Attest で
/// 拒否される。一方 YouTube 本体は未ログインで全機能が使えるので、
/// こちらをホストにすれば App Attest の壁を迂回できる。
/// 必要なクラスは両アプリで共通 (同じ内部フレームワークを共有)。
@interface YTAppDelegate : UIResponder <UIApplicationDelegate>
@end

@interface YTMSceneDelegate : UIResponder <UIWindowSceneDelegate>
@end

/// ルートのナビゲーション階層。UI を差し込むときの足場になる。
@interface YTMNavigationController : UINavigationController
@end

#pragma mark - 再生とキュー

/// 再生画面。キューの永続化もここが持つ。
@interface YTMWatchViewController : UIViewController
- (void)resetWatchNextViewController;
@end

/// キューの保存と復元。
@interface YTMQueuePersistenceController : NSObject
- (void)restoreQueueWithCompletion:(nullable void (^)(void))completion;
- (void)clearPersistedQueue;
@end

#pragma mark - サイドロード時の身元偽装に使うクラス

/// アプリ ID を返すユーティリティ。Google 系 SDK が参照する。
@interface YTVersionUtils : NSObject
+ (NSString *)appID;
@end

/// 端末情報。bundle ID も持つ。
@interface GPCDeviceInfo : NSObject
+ (NSString *)bundleId;
@end

/// Firebase 系の環境判定。サイドロードだと機能を落とすことがある。
@interface GULAppEnvironmentUtil : NSObject
+ (BOOL)isFromAppStore;
@end

/// Google サインインの設定。
///
/// `applicationIdentifier` が OAuth クライアントの登録と一致しないと
/// 認証が拒否される。
///
/// バイナリ上の実際の形 (v0.2.5 で確認):
///   T@"NSString",C,N,V_applicationIdentifier   readonly プロパティ
///   applicationIdentifier                       ゲッター
///
/// init は引数が 9 個あり壊しやすいので、ゲッターを差し替える。
@interface SSOConfiguration : NSObject
@property (nonatomic, copy, readonly) NSString *applicationIdentifier;
@end

/// Keychain の access group を返す。
/// access group は Team ID から導出されカーネルが強制するため、
/// 偽装せず実行時に本物を問い合わせる。
@interface SSOKeychainHelper : NSObject
+ (NSString *)accessGroup;
@end

// SSOKeychainCore は YouTube Music に存在しないクラスだった (実機で確認)。

NS_ASSUME_NONNULL_END
