//
//  YTMProbe.x
//  YTMProbe
//
//  YouTube Music に注入して「ViviMusic から再生を駆動できるか」を
//  確かめるための検証専用 tweak。
//
//  ── なぜ ViviMusic 本体に手を入れないのか ──────────────────
//
//  ViviMusic の UI を移植してから「そもそも再生を駆動できなかった」
//  と分かると、労力が丸ごと無駄になる。SigProbe / QSProbe と同じで、
//  先に最小の検証物を作り、成立を確かめてから本体に進む。
//
//  ── この tweak が確かめること ────────────────────────────
//
//  Step 1  注入した dylib が読み込まれ、アプリが落ちないこと
//  Step 2  必要なクラスとセレクタが実在すること (名前が推定なので)
//  Step 3  videoId を渡して実際に再生が始まること   ← 本命
//
//  Step 3 が通れば「ViviMusic の UI + 公式の再生エンジン」という
//  構成が成立する。通らなければ、その時点で撤退できる。
//
//  ── 安全側に倒した設計 ──────────────────────────────────
//
//  ・元の挙動は一切変えない。フローティングボタンを 1 個足すだけ。
//  ・呼び出す前に必ず respondsToSelector: で存在を確認する。
//    推定した宣言が外れていても落ちないようにするため。
//  ・結果はすべて画面上のログビューに出す。実機に Xcode を繋げない
//    環境なので、コンソールに頼らない。
//

#import "YTMHeaders.h"
#import <objc/runtime.h>
#import <Security/Security.h>

// MARK: - 前方宣言

//
// ── なぜここに置くか ────────────────────────────────────────
//
// C は「定義より前で呼ぶ」ことを許さない。宣言が無いまま呼ぶと
//
//   error: call to undeclared function
//   error: implicit conversion of 'int' to 'NSArray *' is disallowed with ARC
//   error: static declaration follows non-static declaration
//
// が一度に出る (暗黙の宣言が int を返すとみなされるため)。
//
// ObjC クラスも同じで、`@interface` より前で使うと
//
//   error: use of undeclared identifier 'YTMProbeSettings'
//
// になる。実際 v0.2.2 でこれを踏んだ (パネルの onHooks が
// YTMProbeSettings の @interface より前にあった)。
//
// この tweak は「実機で分かったことを受けて機能を足す」進め方をするので、
// 定義の物理的な位置に依存しないよう、**関数もクラスもすべてここで宣言する。**
// 以後、何かを追加したらまずここに 1 行足すこと。
//

// ── ObjC クラス ─────────────────────────────────────────────

/// 画面上に出す簡易ログ (SideStore/LiveContainer では
/// Xcode のコンソールが使えないため)。
@interface YTMProbeLog : NSObject
+ (void)add:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
+ (NSString *)allText;
+ (void)setSink:(void (^_Nullable)(NSString *))sink;
@end

/// 偽装フックの有効/無効と、起動失敗の検知。
@interface YTMProbeSettings : NSObject
+ (BOOL)enabled:(NSString *)group;
+ (void)setEnabled:(BOOL)on forGroup:(NSString *)group;
+ (NSArray<NSString *> *)allGroups;
+ (void)disableAll;
/// 前回の起動が完走しなかったか。
+ (BOOL)didPreviousLaunchFail;
/// 起動を始めたことを記録する。
+ (void)markLaunchStarted;
/// 起動が完走したことを記録する。
+ (void)markLaunchCompleted;
@end

/// 操作パネル。
@interface YTMProbePanel : UIView
@property (nonatomic, strong) UITextView *logView;
@end

// ── 静的関数 ─────────────────────────────────────────────────

/// 指定セレクタを実装しているクラスをランタイムから探す。
static NSArray<NSString *> *YTMProbeClassesImplementing(SEL selector,
                                                        BOOL instanceMethod,
                                                        NSUInteger limit);

/// キーウィンドウを取る (UIApplication.keyWindow は非推奨のため自前)。
static UIWindow *_Nullable YTMProbeKeyWindow(void);

/// セレクタを動的に組み立てて呼ぶ (ARC の performSelector 制約を回避)。
static id YTMProbeInvoke(id target,
                         SEL selector,
                         id _Nullable object,
                         BOOL returnsObject);

/// `dispatchCommand:fromSender:completion:` に応答するものを探す。
static id YTMProbeFindCommandRouter(void);

/// オブジェクトグラフを辿って、目的のセレクタに応答するものを探す。
static id YTMProbeSearchGraph(id root, SEL selector, int depth,
                              NSMutableSet *visited);

/// AppDelegate の openURL ハンドラを直接叩く。
static void YTMProbeOpenURL(NSString *urlString);

/// 複数の URL 形式を順に試して再生させる。
static void YTMProbePlayViaURL(NSString *videoID);

/// URL を扱えそうなメソッドを持つクラスをランタイムから列挙する。
static void YTMProbeDumpURLHandlers(void);

/// 注入先が YouTube Music か (そうでなければ YouTube 本体)。
static BOOL YTMProbeHostIsMusic(void);

/// 名乗るべき公式の bundle ID。ホストに合わせて返す。
static NSString *YTMProbeOriginalBundleID(void);

/// パネルを画面に出す。AppDelegate のフックから呼ぶ。
static void YTMProbeInstallPanel(void);

/// Keychain の access group を実行時に問い合わせる。
static NSString *_Nullable YTMProbeAccessGroupID(void);

/// 自分自身の NSBundle か (他のバンドルまで偽装すると壊れる)。
static BOOL YTMProbeIsMainBundle(NSBundle *bundle);

/// 推定した宣言が実在するかを確かめる。
static void YTMProbeVerifySymbols(void);

/// videoId を渡して再生を開始させる。
static void YTMProbePlayVideo(NSString *videoID);

/// オブジェクトグラフを辿って、目的のセレクタに応答するものを探す。
///
/// ── なぜ必要か (v0.2.4) ──────────────────────────────────
///
/// `dispatchCommand:fromSender:completion:` の実装クラスは
/// `YTELMDispatcher` だと分かったが、**インスタンスの取り方**が不明。
/// AppDelegate の直下のプロパティには居なかった。
///
/// そこで AppDelegate / SceneDelegate から ivar とプロパティを
/// 辿って探す。深さは浅く抑える (深追いすると副作用のあるゲッターを
/// 大量に踏み、時間もかかる)。
///
/// - Parameters:
///   - root: 探索の起点。
///   - selector: 応答してほしいセレクタ。
///   - depth: 残りの深さ。
///   - visited: 巡回防止。
static id YTMProbeSearchGraph(id root,
                              SEL selector,
                              int depth,
                              NSMutableSet *visited) {
    if (!root || depth < 0) return nil;

    NSValue *key = [NSValue valueWithNonretainedObject:root];
    if ([visited containsObject:key]) return nil;
    [visited addObject:key];
    if (visited.count > 400) return nil;   // 打ち切り

    if ([root respondsToSelector:selector]) return root;

    Class cls = [root class];
    NSString *clsName = NSStringFromClass(cls);
    // アプリ由来のオブジェクトだけを辿る。
    // Foundation のコレクション等まで辿ると発散する。
    if (!([clsName hasPrefix:@"YT"] || [clsName hasPrefix:@"ML"]
          || [clsName hasPrefix:@"SSO"] || [clsName hasPrefix:@"GPC"])) {
        return nil;
    }

    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        const char *type = ivar_getTypeEncoding(ivars[i]);
        // オブジェクト型の ivar だけを見る。
        if (!type || type[0] != '@') continue;
        id value = nil;
        @try {
            value = object_getIvar(root, ivars[i]);
        } @catch (NSException *e) {
            continue;
        }
        if (!value) continue;
        id found = YTMProbeSearchGraph(value, selector, depth - 1, visited);
        if (found) {
            free(ivars);
            return found;
        }
    }
    free(ivars);
    return nil;
}


// MARK: - 画面上のログ

/// 実機で結果を見るための簡易ログ。
///
/// SideStore 環境では Xcode のコンソールが使えないので、
/// アプリ内にオーバーレイを出して、そこへ書き出す。
// (YTMProbeLog の宣言は冒頭の前方宣言に移した)
@implementation YTMProbeLog

static NSMutableArray<NSString *> *gLines = nil;
static void (^gSink)(NSString *) = nil;

+ (void)initialize {
    if (self == [YTMProbeLog class]) {
        gLines = [NSMutableArray array];
    }
}

+ (void)add:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"%@  %@",
                      [f stringFromDate:[NSDate date]], body];

    @synchronized (gLines) {
        [gLines addObject:line];
        if (gLines.count > 500) [gLines removeObjectAtIndex:0];
    }
    NSLog(@"[YTMProbe] %@", body);

    if (gSink) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (gSink) gSink(line); });
    }
}

+ (NSString *)allText {
    @synchronized (gLines) {
        return [gLines componentsJoinedByString:@"\n"];
    }
}

+ (void)setSink:(void (^)(NSString *))sink {
    gSink = [sink copy];
}

@end

// MARK: - Step 2: シンボルの実在確認

/// 推定で書いた宣言が実際に存在するかを確かめる。
///
/// YouTube Music は毎週更新されるので、名前が変わっていないかを
/// 起動のたびに見る。ここで「なし」が出たものは
/// YTMHeaders.h の宣言を直す必要がある。
static void YTMProbeVerifySymbols(void) {
    [YTMProbeLog add:@"===== シンボル確認 ====="];

    // ── v0.3.1: ホストごとに見るクラスを分ける ──────────────
    //
    // YTM* は YouTube Music にしか無い。YouTube 本体で確認すると
    // 「なし」が 5 件並んで不足件数が水増しされ、本当の問題
    // (dispatchCommand が無い等) が埋もれる。
    NSArray<NSString *> *common = @[
        @"GPBMessage",
        @"GPBExtensionDescriptor",
        @"YTICommand",
        @"YTIWatchEndpoint",
        @"YTIWatchEndpointRoot",
        @"YTCommandRouter",
        @"YTAccountScopedCommandRouter",
        @"YTELMDispatcher",
    ];
    NSArray<NSString *> *hostOnly = YTMProbeHostIsMusic()
        ? @[@"YTMAppDelegate",
            @"YTMSceneDelegate",
            @"YTMNavigationController",
            @"YTMWatchViewController",
            @"YTMQueuePersistenceController"]
        : @[@"YTAppDelegate",
            @"YTURLHandler",
            @"YTAppDeepLinkCommandHandler",
            @"YTWatchController"];
    NSArray<NSString *> *classNames =
        [common arrayByAddingObjectsFromArray:hostOnly];
    [YTMProbeLog add:@"  (ホスト: %@)",
                      YTMProbeHostIsMusic() ? @"YouTube Music" : @"YouTube 本体"];

    NSUInteger missing = 0;
    for (NSString *name in classNames) {
        Class cls = NSClassFromString(name);
        [YTMProbeLog add:@"  %@ %@", cls ? @"OK  " : @"なし", name];
        if (!cls) missing++;
    }

    // watchEndpoint の extension が取れるか。
    // これが取れないと YTICommand に載せられない。
    Class rootCls = NSClassFromString(@"YTIWatchEndpointRoot");
    SEL watchSel = NSSelectorFromString(@"watchEndpoint");
    if (rootCls && [rootCls respondsToSelector:watchSel]) {
        [YTMProbeLog add:@"  OK   +[YTIWatchEndpointRoot watchEndpoint]"];
    } else {
        [YTMProbeLog add:@"  なし +[YTIWatchEndpointRoot watchEndpoint]"];
        missing++;
    }

    // dispatchCommand の存在。
    SEL dispatchSel =
        NSSelectorFromString(@"dispatchCommand:fromSender:completion:");
    BOOL anyRouter = NO;
    for (NSString *name in @[@"YTCommandRouter", @"YTAccountScopedCommandRouter"]) {
        Class cls = NSClassFromString(name);
        BOOL ok = cls && [cls instancesRespondToSelector:dispatchSel];
        [YTMProbeLog add:@"  %@ -[%@ dispatchCommand:fromSender:completion:]",
                          ok ? @"OK  " : @"なし", name];
        if (ok) anyRouter = YES; else missing++;
    }

    // ── v0.2.0: 応答しないときはランタイムを総当たりする ──────
    //
    // クラスはあるのにセレクタに応答しない = 別のクラスが実装している。
    // 名前を推測するより、実際に実装を持つクラスを探すほうが確実。
    if (!anyRouter) {
        [YTMProbeLog add:@"  → 実装クラスをランタイムから探す…"];
        NSArray<NSString *> *impls =
            YTMProbeClassesImplementing(dispatchSel, YES, 30);
        if (impls.count == 0) {
            [YTMProbeLog add:@"  → 実装クラスが 1 つも見つからない"];
        } else {
            for (NSString *name in impls) {
                [YTMProbeLog add:@"  → 実装あり: %@", name];
            }
        }
    }

    // YTIWatchEndpoint に videoId を書けるか。
    Class endpointCls = NSClassFromString(@"YTIWatchEndpoint");
    BOOL canSetVideoID =
        endpointCls && [endpointCls instancesRespondToSelector:@selector(setVideoId:)];
    [YTMProbeLog add:@"  %@ -[YTIWatchEndpoint setVideoId:]",
                      canSetVideoID ? @"OK  " : @"なし"];
    if (!canSetVideoID) missing++;

    // ── v0.2.5: フック対象のセレクタが実在するかを確かめる ──────
    //
    // Logos は **存在しないメソッドを %hook すると新規追加してしまう**。
    // 呼ばれないまま何も起きないので、「フックしたのに効かない」という
    // 分かりにくい失敗になる。
    //
    // 実際 v0.2.0〜v0.2.4 の SpoofSSO がこれだった。
    // `initWithClientID:supportedAccountTypes:` は存在しないセレクタで、
    // 有効にしてもログインは通らないままだった。
    //
    // 同じ失敗を繰り返さないよう、フック先が実在するかを毎回確かめる。
    [YTMProbeLog add:@"----- フック対象の実在確認 -----"];
    NSArray<NSArray *> *targets = @[
        @[@"YTVersionUtils",        @"appID",                 @NO],
        @[@"GPCDeviceInfo",         @"bundleId",              @NO],
        @[@"GULAppEnvironmentUtil", @"isFromAppStore",        @NO],
        @[@"SSOConfiguration",      @"applicationIdentifier", @YES],
        @[@"SSOKeychainHelper",     @"accessGroup",           @NO],
        @[@"NSBundle",              @"bundleIdentifier",      @YES],
    ];
    for (NSArray *t in targets) {
        NSString *clsName = t[0];
        NSString *selName = t[1];
        BOOL isInstance = [t[2] boolValue];
        Class cls = NSClassFromString(clsName);
        SEL sel = NSSelectorFromString(selName);
        BOOL exists = cls && (isInstance
            ? (class_getInstanceMethod(cls, sel) != NULL)
            : (class_getClassMethod(cls, sel) != NULL));
        [YTMProbeLog add:@"  %@ %@%@ %@]",
                          exists ? @"OK  " : @"なし",
                          isInstance ? @"-[" : @"+[",
                          clsName, selName];
    }
    [YTMProbeLog add:@"  (「なし」はフックしても効きません)"];

    [YTMProbeLog add:@"===== 確認終わり (不足 %lu 件) =====", (unsigned long)missing];
}

// MARK: - CommandRouter の実体を探す

/// `dispatchCommand:fromSender:completion:` を持つオブジェクトを探す。
///
/// クラスは分かっていても、**インスタンスの取り方が分からない**。
/// AppDelegate や SceneDelegate のプロパティを総当たりで見て、
/// それらしいものを拾う。
///
/// 見つからなければ、プロパティ一覧をログに出して手掛かりにする。
static id YTMProbeFindCommandRouter(void) {
    SEL dispatchSel =
        NSSelectorFromString(@"dispatchCommand:fromSender:completion:");

    // 探索の起点になりそうなオブジェクト
    NSMutableArray *roots = [NSMutableArray array];
    id appDelegate = [UIApplication sharedApplication].delegate;
    if (appDelegate) [roots addObject:appDelegate];

    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.delegate) [roots addObject:scene.delegate];
    }

    for (id root in roots) {
        [YTMProbeLog add:@"探索: %@", NSStringFromClass([root class])];

        // まず素直に commandRouter を聞いてみる
        for (NSString *key in @[@"commandRouter", @"accountScopedCommandRouter"]) {
            SEL sel = NSSelectorFromString(key);
            if (![root respondsToSelector:sel]) continue;
            id candidate = nil;
            @try {
                candidate = [root valueForKey:key];
            } @catch (NSException *e) {
                [YTMProbeLog add:@"  %@ の取得で例外: %@", key, e.reason];
                continue;
            }
            if (candidate && [candidate respondsToSelector:dispatchSel]) {
                [YTMProbeLog add:@"  見つかった: %@ = %@",
                                  key, NSStringFromClass([candidate class])];
                return candidate;
            }
        }

        // 見つからないので、プロパティを総当たりで見る。
        //
        // v0.2.0: 名前を決め打ちせず、**実際に dispatchCommand に
        // 応答するオブジェクトを返すプロパティ**を探す。
        // 実機で `commandRouter` が見つからなかったため。
        unsigned int count = 0;
        objc_property_t *props = class_copyPropertyList([root class], &count);
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (unsigned int i = 0; i < count; i++) {
            NSString *propName = @(property_getName(props[i]));
            [names addObject:propName];

            // 値を取って、それが dispatchCommand に応答するか見る。
            // 副作用のあるゲッターを踏む恐れがあるので例外は握る。
            id value = nil;
            @try {
                value = [root valueForKey:propName];
            } @catch (NSException *e) {
                continue;
            }
            if (value && [value respondsToSelector:dispatchSel]) {
                [YTMProbeLog add:@"  見つかった(総当たり): %@ = %@",
                                  propName, NSStringFromClass([value class])];
                free(props);
                return value;
            }
        }
        free(props);
        [YTMProbeLog add:@"  プロパティ(%u): %@", count,
                          [names componentsJoinedByString:@", "]];
    }

    // ── v0.2.4: オブジェクトグラフを辿る ────────────────────
    //
    // 直下のプロパティに居なかったので、ivar を辿って深く探す。
    // 実装クラスが YTELMDispatcher だと分かっているので、
    // どこかに保持されているはず。
    [YTMProbeLog add:@"直下に無い。オブジェクトグラフを辿る…"];
    for (id root in roots) {
        NSMutableSet *visited = [NSMutableSet set];
        id found = YTMProbeSearchGraph(root, dispatchSel, 4, visited);
        if (found) {
            [YTMProbeLog add:@"  見つかった(グラフ探索): %@ (%lu 個辿った)",
                              NSStringFromClass([found class]),
                              (unsigned long)visited.count];
            return found;
        }
        [YTMProbeLog add:@"  %@ から辿ったが見つからず (%lu 個)",
                          NSStringFromClass([root class]),
                          (unsigned long)visited.count];
    }

    [YTMProbeLog add:@"CommandRouter が見つからない"];
    return nil;
}

// MARK: - ランタイム総当たり探索

/// 指定セレクタを実装しているクラスを、ロード済みの全クラスから探す。
///
/// ── なぜ必要か (v0.2.0) ──────────────────────────────────────
///
/// 実機で確かめたところ、`YTCommandRouter` クラスは存在するのに
/// `dispatchCommand:fromSender:completion:` に応答しなかった。
///
///   OK   YTCommandRouter
///   なし -[YTCommandRouter dispatchCommand:fromSender:completion:]
///
/// バイナリの文字列表にセレクタはあるので、**別のクラスが実装している**
/// ということ。`YTCommandRouter` はプロトコル的な基底で、実体は
/// `〜Impl` のような別名になっている可能性が高い。
///
/// 名前を推測して当てるより、ランタイムを総当たりするほうが確実で、
/// YouTube Music が更新されて名前が変わっても追随できる。
///
/// - Parameters:
///   - selector: 探すセレクタ。
///   - instanceMethod: インスタンスメソッドを探すなら YES。
///   - limit: ログに出す件数の上限。
/// - Returns: 見つかったクラス名。
static NSArray<NSString *> *YTMProbeClassesImplementing(SEL selector,
                                                        BOOL instanceMethod,
                                                        NSUInteger limit) {
    NSMutableArray<NSString *> *found = [NSMutableArray array];

    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return found;

    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        const char *rawName = class_getName(cls);
        if (!rawName) continue;
        NSString *name = @(rawName);

        // アプリ由来のクラスだけを見る。
        // 全クラスを respondsToSelector: に掛けると、初期化していない
        // クラスに触れて落ちることがあるため、名前で先に絞る。
        if (!([name hasPrefix:@"YT"] || [name hasPrefix:@"GPB"]
              || [name hasPrefix:@"SSO"] || [name hasPrefix:@"ML"])) {
            continue;
        }

        BOOL responds = instanceMethod
            ? (class_getInstanceMethod(cls, selector) != NULL)
            : (class_getClassMethod(cls, selector) != NULL);
        if (responds) {
            [found addObject:name];
            if (found.count >= limit) break;
        }
    }
    free(classes);
    return found;
}

// MARK: - ウィンドウ探索

/// キーウィンドウを取る。
///
/// `UIApplication.keyWindow` は iOS 13 で非推奨になっており、
/// Theos は既定で `-Werror` なので使うとビルドが止まる。
/// シーンを辿って自前で探す。
static UIWindow *_Nullable YTMProbeKeyWindow(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *candidate in windowScene.windows) {
            if (candidate.isKeyWindow) return candidate;
        }
    }
    // キーウィンドウが決まっていないこともあるので、最初のものに落とす。
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.windows.firstObject) return windowScene.windows.firstObject;
    }
    return nil;
}

// MARK: - 動的呼び出しのヘルパ

/// セレクタを動的に組み立てて呼ぶ。
///
/// ── なぜ performSelector: を使わないのか ────────────────────
///
/// ARC 下で `performSelector:` に **コンパイル時に決まらないセレクタ**
/// を渡すと、次のエラーになる。
///
///   error: performSelector may cause a leak because its selector is
///          unknown [-Werror,-Warc-performSelector-leaks]
///
/// ARC は戻り値を retain すべきか (メソッド名が alloc/copy/new/init で
/// 始まるか) をセレクタ名から判断する。名前が実行時にしか分からないと
/// 判断できないので、警告になる。Theos は既定で -Werror なのでビルドが
/// 止まる。
///
/// 警告を抑制する手もあるが、実際にリークしうるのは事実なので
/// `NSInvocation` に寄せる。こちらは戻り値の扱いを明示できる。
/// `dispatchCommand:` の呼び出しでも既に NSInvocation を使っており、
/// 方式が揃うという利点もある。
///
/// - Parameters:
///   - target: 呼び出し先。クラスメソッドならクラスを渡す。
///   - selector: 呼ぶセレクタ。
///   - object: 引数。不要なら nil。
///   - returnsObject: 戻り値をオブジェクトとして受け取るか。
/// - Returns: `returnsObject` が YES のとき戻り値。それ以外は nil。
static id YTMProbeInvoke(id target,
                         SEL selector,
                         id _Nullable object,
                         BOOL returnsObject) {
    if (!target || !selector) return nil;
    if (![target respondsToSelector:selector]) return nil;

    NSMethodSignature *sig = [target methodSignatureForSelector:selector];
    if (!sig) return nil;

    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = target;
    inv.selector = selector;
    if (object && sig.numberOfArguments > 2) {
        [inv setArgument:&object atIndex:2];
    }

    @try {
        [inv invoke];
    } @catch (NSException *e) {
        [YTMProbeLog add:@"%@ の呼び出しで例外: %@",
                          NSStringFromSelector(selector), e.reason];
        return nil;
    }

    if (!returnsObject) return nil;
    // 戻り値がオブジェクトでない場合に取り出すと壊れるので型を見る。
    if (strcmp(sig.methodReturnType, @encode(id)) != 0) return nil;

    void *raw = NULL;
    [inv getReturnValue:&raw];
    // getReturnValue: は retain しないので、ここで ARC の管理下に移す。
    // メソッド名が alloc/copy/new/init で始まらない前提
    // (この tweak が呼ぶのは setVideoId: と watchEndpoint だけ)。
    return (__bridge id)raw;
}

// MARK: - Step 3-A: URL 経由で再生させる（主経路）

//
// ── なぜこちらを先に試すのか (v0.2.4) ──────────────────────
//
// 当初は `YTIWatchEndpoint` を protobuf で組んで `CommandRouter` に
// 投げる方式だけを考えていた。しかし実機で分かったことが 2 つある。
//
//   1. `dispatchCommand:fromSender:completion:` の実装は
//      `YTELMDispatcher` だけ。しかもインスタンスの取り方が不明。
//   2. YouTube Music は URL スキームと openURL ハンドラを持っている。
//
//      CFBundleURLSchemes:
//        youtubemusic / vnd.youtube.music / youtubemusicsdk …
//      ハンドラ:
//        application:openURL:options: / scene:openURLContexts:
//
// URL を投げるほうが圧倒的に単純で、壊れにくい。
// protobuf のフィールド番号にも、非公開クラスの内部構造にも
// 依存しない。YouTube Music が更新されても URL の形は変わりにくい。
//
// ViviMusic から再生を駆動する本番でも、この経路で足りるなら
// そのほうがずっと保守しやすい。
//
// ── 試す URL の形 ────────────────────────────────────────
//
//   https://music.youtube.com/watch?v=<id>   Universal Link
//   youtubemusic://watch?v=<id>              独自スキーム
//   vnd.youtube.music://<id>                 旧来の形
//
// どれが効くかは実機で確かめる。
//

/// AppDelegate の openURL ハンドラを直接叩いて再生させる。
///
/// ── v0.3.1 で直した点 ────────────────────────────────────
///
/// YouTube 本体では `application:openURL:options:` が AppDelegate に
/// 無かった (`application:openURL:options: が無い` が 3 回出た)。
///
/// バイナリにセレクタ自体は存在するので、**実装しているのが
/// YTAppDelegate ではない**ということ。YouTube は
/// `YTURLHandler` という専用クラスを持っており、そちらが
/// 処理している可能性が高い。
///
/// 決め打ちをやめ、
///
///   1. AppDelegate と SceneDelegate
///   2. それらのオブジェクトグラフ
///   3. ランタイム全体
///
/// の順に、実際に応答するものを探す。セレクタの形も
/// 4 種類を順に試す (古い形が残っていることがある)。
static void YTMProbeOpenURL(NSString *urlString) {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        [YTMProbeLog add:@"URL を作れない: %@", urlString];
        return;
    }

    UIApplication *app = [UIApplication sharedApplication];

    // 試すセレクタ。上から順に、新しい形 → 古い形。
    NSArray<NSString *> *selNames = @[
        @"application:openURL:options:",
        @"application:openURL:sourceApplication:annotation:",
        @"application:handleOpenURL:",
        @"handleURL:",
    ];

    for (NSString *selName in selNames) {
        SEL sel = NSSelectorFromString(selName);

        // 応答するオブジェクトを探す。
        id target = nil;
        if ([app.delegate respondsToSelector:sel]) {
            target = app.delegate;
        } else {
            // AppDelegate に無ければグラフを辿る。
            NSMutableSet *visited = [NSMutableSet set];
            target = YTMProbeSearchGraph(app.delegate, sel, 4, visited);
        }
        if (!target) continue;

        NSMethodSignature *sig = [target methodSignatureForSelector:sel];
        if (!sig) continue;

        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        inv.target = target;
        inv.selector = sel;

        // 引数の並びがセレクタごとに違うので個別に詰める。
        NSDictionary *options = @{};
        NSString *source = nil;
        id annotation = nil;
        NSUInteger argc = sig.numberOfArguments;
        if ([selName isEqualToString:@"handleURL:"]) {
            [inv setArgument:&url atIndex:2];
        } else {
            [inv setArgument:&app atIndex:2];
            if (argc > 3) [inv setArgument:&url atIndex:3];
            if (argc > 4) {
                if ([selName hasSuffix:@"options:"]) {
                    [inv setArgument:&options atIndex:4];
                } else {
                    [inv setArgument:&source atIndex:4];
                }
            }
            if (argc > 5) [inv setArgument:&annotation atIndex:5];
        }

        @try {
            [inv invoke];
        } @catch (NSException *e) {
            [YTMProbeLog add:@"  %@ で例外: %@", selName, e.reason];
            continue;
        }

        BOOL handled = NO;
        if (strcmp(sig.methodReturnType, @encode(BOOL)) == 0) {
            [inv getReturnValue:&handled];
        }
        [YTMProbeLog add:@"  %@ → %@ (%@ / %@)",
                          urlString,
                          handled ? @"受理" : @"拒否",
                          NSStringFromClass([target class]),
                          selName];
        return;
    }

    [YTMProbeLog add:@"  %@ → 応答するハンドラが見つからない", urlString];
}

/// URL を扱えそうなメソッドを持つクラスを、ランタイムから列挙する。
///
/// 決め打ちのセレクタがどれも当たらなかったときの手掛かり。
/// 「URL」を含むメソッドを持つ YT 系クラスを出す。
static void YTMProbeDumpURLHandlers(void) {
    [YTMProbeLog add:@"----- URL を扱えそうなメソッド -----"];

    // まず AppDelegate 自身のメソッドを全部出す。
    id appDelegate = [UIApplication sharedApplication].delegate;
    Class cls = [appDelegate class];
    [YTMProbeLog add:@"  AppDelegate = %@", NSStringFromClass(cls)];
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        if ([name.lowercaseString containsString:@"url"]
            || [name hasPrefix:@"application:"]) {
            [names addObject:name];
        }
    }
    free(methods);
    if (names.count) {
        for (NSString *n in names) [YTMProbeLog add:@"    -%@", n];
    } else {
        [YTMProbeLog add:@"    (URL 関連のメソッドなし)"];
    }

    // 次に、YT 系クラスで openURL 系を実装しているものを探す。
    NSArray<NSString *> *selNames = @[
        @"application:openURL:options:",
        @"application:openURL:sourceApplication:annotation:",
        @"application:handleOpenURL:",
        @"handleURL:",
    ];
    for (NSString *selName in selNames) {
        SEL sel = NSSelectorFromString(selName);
        NSArray<NSString *> *impls = YTMProbeClassesImplementing(sel, YES, 12);
        if (impls.count == 0) {
            [YTMProbeLog add:@"  %@ : 実装クラスなし", selName];
        } else {
            [YTMProbeLog add:@"  %@ : %@", selName,
                              [impls componentsJoinedByString:@", "]];
        }
    }
    [YTMProbeLog add:@"----- ここまで -----"];
}

/// 複数の URL 形式を順に試す。
static void YTMProbePlayViaURL(NSString *videoID) {
    [YTMProbeLog add:@"===== URL 経由で再生を試す: %@ =====", videoID];
    // ホストごとに使える URL スキームが違う。
    //   YouTube Music : youtubemusic / vnd.youtube.music
    //   YouTube 本体  : youtube / vnd.youtube
    NSArray<NSString *> *candidates = YTMProbeHostIsMusic()
        ? @[[NSString stringWithFormat:@"https://music.youtube.com/watch?v=%@", videoID],
            [NSString stringWithFormat:@"youtubemusic://watch?v=%@", videoID],
            [NSString stringWithFormat:@"vnd.youtube.music://%@", videoID]]
        : @[[NSString stringWithFormat:@"https://www.youtube.com/watch?v=%@", videoID],
            [NSString stringWithFormat:@"youtube://watch?v=%@", videoID],
            [NSString stringWithFormat:@"vnd.youtube://%@", videoID]];
    for (NSString *candidate in candidates) {
        YTMProbeOpenURL(candidate);
    }
    // どれも通らなかったときのために、手掛かりを出しておく。
    YTMProbeDumpURLHandlers();
    [YTMProbeLog add:@"===== 画面を見て、再生が始まったか確認してください ====="];
}

// MARK: - Step 3-B: 再生させてみる（protobuf 経路）

/// videoId を渡して再生を開始させる。**これが本命。**
///
/// 手順:
///   1. YTIWatchEndpoint を作って videoId を入れる
///   2. YTICommand を作って watchEndpoint extension に載せる
///   3. CommandRouter に投げる
static void YTMProbePlayVideo(NSString *videoID) {
    [YTMProbeLog add:@"===== 再生を試す: %@ =====", videoID];

    Class endpointCls = NSClassFromString(@"YTIWatchEndpoint");
    Class commandCls  = NSClassFromString(@"YTICommand");
    Class rootCls     = NSClassFromString(@"YTIWatchEndpointRoot");
    if (!endpointCls || !commandCls || !rootCls) {
        [YTMProbeLog add:@"必要なクラスが無い。中止"];
        return;
    }

    // 1. エンドポイントを組む
    id endpoint = [[endpointCls alloc] init];
    SEL setVideoID = @selector(setVideoId:);
    if (![endpoint respondsToSelector:setVideoID]) {
        [YTMProbeLog add:@"setVideoId: が無い。中止"];
        return;
    }
    YTMProbeInvoke(endpoint, setVideoID, videoID, NO);
    [YTMProbeLog add:@"エンドポイント作成: %@", endpoint];

    // 2. extension に載せる
    SEL watchSel = NSSelectorFromString(@"watchEndpoint");
    if (![rootCls respondsToSelector:watchSel]) {
        [YTMProbeLog add:@"watchEndpoint extension が取れない。中止"];
        return;
    }
    id extension = YTMProbeInvoke(rootCls, watchSel, nil, YES);
    if (!extension) {
        [YTMProbeLog add:@"watchEndpoint extension が nil。中止"];
        return;
    }

    id command = [[commandCls alloc] init];
    @try {
        [command setExtension:extension value:endpoint];
    } @catch (NSException *e) {
        [YTMProbeLog add:@"setExtension:value: で例外: %@", e.reason];
        return;
    }
    [YTMProbeLog add:@"コマンド作成: %@", command];

    // 3. 投げる
    id router = YTMProbeFindCommandRouter();
    if (!router) {
        [YTMProbeLog add:@"CommandRouter が無いので投げられない"];
        return;
    }

    UIView *sender = YTMProbeKeyWindow().rootViewController.view;
    SEL dispatchSel =
        NSSelectorFromString(@"dispatchCommand:fromSender:completion:");
    NSMethodSignature *sig = [router methodSignatureForSelector:dispatchSel];
    if (!sig) {
        [YTMProbeLog add:@"dispatchCommand のシグネチャが取れない。中止"];
        return;
    }

    void (^completion)(BOOL) = ^(BOOL success) {
        [YTMProbeLog add:@"===== 結果: %@ =====",
                          success ? @"成功 (再生が始まったはず)" : @"失敗"];
    };

    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = router;
    inv.selector = dispatchSel;
    [inv setArgument:&command atIndex:2];
    [inv setArgument:&sender atIndex:3];
    [inv setArgument:&completion atIndex:4];

    @try {
        [inv invoke];
        [YTMProbeLog add:@"dispatchCommand を呼んだ"];
    } @catch (NSException *e) {
        [YTMProbeLog add:@"dispatchCommand で例外: %@", e.reason];
    }
}

// MARK: - 操作パネル

/// 画面隅に出すパネル。ボタンとログを載せる。
// (YTMProbePanel の宣言は冒頭の前方宣言に移した)
@implementation YTMProbePanel

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return self;

    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
    self.layer.cornerRadius = 12;
    self.clipsToBounds = YES;

    UIButton *verify = [UIButton buttonWithType:UIButtonTypeSystem];
    [verify setTitle:@"シンボル確認" forState:UIControlStateNormal];
    [verify addTarget:self action:@selector(onVerify)
     forControlEvents:UIControlEventTouchUpInside];

    UIButton *play = [UIButton buttonWithType:UIButtonTypeSystem];
    [play setTitle:@"再生を試す" forState:UIControlStateNormal];
    [play addTarget:self action:@selector(onPlay)
   forControlEvents:UIControlEventTouchUpInside];

    UIButton *copy = [UIButton buttonWithType:UIButtonTypeSystem];
    [copy setTitle:@"ログをコピー" forState:UIControlStateNormal];
    [copy addTarget:self action:@selector(onCopy)
   forControlEvents:UIControlEventTouchUpInside];

    UIButton *playURL = [UIButton buttonWithType:UIButtonTypeSystem];
    [playURL setTitle:@"URL再生" forState:UIControlStateNormal];
    [playURL addTarget:self action:@selector(onPlayURL)
      forControlEvents:UIControlEventTouchUpInside];

    UIButton *hooks = [UIButton buttonWithType:UIButtonTypeSystem];
    [hooks setTitle:@"フック" forState:UIControlStateNormal];
    [hooks addTarget:self action:@selector(onHooks)
    forControlEvents:UIControlEventTouchUpInside];

    UIButton *hide = [UIButton buttonWithType:UIButtonTypeSystem];
    [hide setTitle:@"閉じる" forState:UIControlStateNormal];
    [hide addTarget:self action:@selector(onHide)
   forControlEvents:UIControlEventTouchUpInside];

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:
                            @[verify, playURL, play, hooks, copy, hide]];
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.distribution = UIStackViewDistributionFillEqually;
    buttons.spacing = 8;

    self.logView = [[UITextView alloc] init];
    self.logView.backgroundColor = [UIColor clearColor];
    self.logView.textColor = [UIColor whiteColor];
    self.logView.font = [UIFont monospacedSystemFontOfSize:9
                                                    weight:UIFontWeightRegular];
    self.logView.editable = NO;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
                          @[buttons, self.logView]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
        [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8],
        [buttons.heightAnchor constraintEqualToConstant:32],
    ]];

    __weak typeof(self) weakSelf = self;
    [YTMProbeLog setSink:^(NSString *line) {
        [weakSelf appendLine:line];
    }];
    self.logView.text = [YTMProbeLog allText];

    return self;
}

- (void)appendLine:(NSString *)line {
    // line 自体は使わない。表示は毎回まるごと入れ替えるため。
    // (引数を残しているのは sink の形を変えたくないから)
    (void)line;
    self.logView.text = [YTMProbeLog allText];
    NSRange end = NSMakeRange(self.logView.text.length, 0);
    [self.logView scrollRangeToVisible:end];
}

- (void)onVerify {
    YTMProbeVerifySymbols();
}

- (void)onPlay {
    // 実験用の固定 videoId。
    // ViviMusic のログで 1 MiB 制限に当たっていたもの。
    YTMProbePlayVideo(@"nIQko_MvspU");
}

- (void)onPlayURL {
    // URL 経由の再生。protobuf を組む必要がなく、こちらが主経路。
    YTMProbePlayViaURL(@"nIQko_MvspU");
}

- (void)onHooks {
    // 有効にするフックを 1 つずつ選ぶ。
    //
    // 起動時にしか掛けられないので、ここでの変更は次回起動で反映する。
    // 「安全な順」に並べてあるので、上から 1 つずつ試すのが早い。
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:@"偽装フック"
                         message:@"次回起動から反映されます。\n"
                                  "上から順に 1 つずつ試してください。"
                  preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSString *group in [YTMProbeSettings allGroups]) {
        BOOL on = [YTMProbeSettings enabled:group];
        NSString *title = [NSString stringWithFormat:@"%@ %@",
                           on ? @"[有効]" : @"[無効]", group];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            [YTMProbeSettings setEnabled:!on forGroup:group];
            [YTMProbeLog add:@"%@ を %@ にした (次回起動から)",
                              group, !on ? @"有効" : @"無効"];
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"すべて無効に戻す"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) {
        [YTMProbeSettings disableAll];
        [YTMProbeLog add:@"偽装フックをすべて無効にした (次回起動から)"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"閉じる"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    // iPad では popover の出所を指定しないと落ちる。
    sheet.popoverPresentationController.sourceView = self;
    sheet.popoverPresentationController.sourceRect =
        CGRectMake(CGRectGetMidX(self.bounds), 0, 1, 1);

    UIViewController *root = YTMProbeKeyWindow().rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    [root presentViewController:sheet animated:YES completion:nil];
}

- (void)onCopy {
    [UIPasteboard generalPasteboard].string = [YTMProbeLog allText];
    [YTMProbeLog add:@"ログをコピーした"];
}

- (void)onHide {
    self.hidden = YES;
}

@end

// MARK: - フックの設定と安全装置

//
// ── なぜ必要か (v0.2.2) ──────────────────────────────────────
//
// 偽装フックをまとめて有効にしたら LiveContainer で起動時に落ちた。
// どれが原因かを実機で切り分ける必要があるが、
//
//   ・起動時に落ちるので、パネルまで辿り着けない
//   ・毎回ビルドし直すのは 1 往復が長すぎる
//
// そこで次の 2 つを入れる。
//
//   1. フックごとの有効/無効を UserDefaults に保存し、
//      パネルから切り替えて次回起動で反映する
//   2. **起動が完走しなかったら、次の起動で全部無効に戻す**
//
// 2 が無いと、落ちる設定にした瞬間に二度と起動できなくなり、
// 入れ直すしかなくなる。
//

// (YTMProbeSettings の宣言は冒頭の前方宣言に移した)
@implementation YTMProbeSettings

static NSString *const kPrefix = @"YTMProbe.hook.";
static NSString *const kLaunchPendingKey = @"YTMProbe.launchPending";

+ (NSArray<NSString *> *)allGroups {
    // 疑わしい順ではなく、**安全な順**に並べる。
    // 上から 1 つずつ入れて試すため。
    //
    // ── 実機で分かったこと (v0.2.4) ──────────────────────
    //
    // 上の 4 つを同時に有効にしても起動できた。
    // **クラッシュの原因は SpoofBundleID だと確定した。**
    //
    //   -[__NSPlaceholderArray initWithObjects:count:]:
    //     attempt to insert nil object from objects[0]
    //
    // %hook NSBundle はプロセス内のすべての NSBundle に効くため、
    // LiveContainer 自身が巻き添えになったと見られる。実際、
    // 実行時に取れた Keychain access group は
    //
    //   48A5LFNW96.com.kdt.livecontainer.shared.91
    //
    // で、これは **LiveContainer のもの**。ゲストアプリの
    // NSBundle が LiveContainer のものと入れ替わる環境なので、
    // mainBundle 判定では絞りきれていない。
    //
    // 残してあるのは、SideStore で直接入れた場合に試すため。
    // LiveContainer では有効にしないこと。
    //
    return @[@"SpoofAppID",        // YouTube Music 自身のクラスのみ。影響が狭い
             @"SpoofSSO",          // ログイン阻止の直接の対策
             @"RealKeychainGroup", // 偽装ではなく本物を問い合わせるだけ
             @"SpoofAppStore",     // レシート不在で nil を掴む恐れ
             @"SpoofBundleID"];    // ★ LiveContainer では落ちる。有効にしない
}

+ (BOOL)enabled:(NSString *)group {
    return [[NSUserDefaults standardUserDefaults]
            boolForKey:[kPrefix stringByAppendingString:group]];
}

+ (void)setEnabled:(BOOL)on forGroup:(NSString *)group {
    [[NSUserDefaults standardUserDefaults]
        setBool:on forKey:[kPrefix stringByAppendingString:group]];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (void)disableAll {
    for (NSString *g in [self allGroups]) {
        [self setEnabled:NO forGroup:g];
    }
}

+ (BOOL)didPreviousLaunchFail {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kLaunchPendingKey];
}

+ (void)markLaunchStarted {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kLaunchPendingKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (void)markLaunchCompleted {
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kLaunchPendingKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end

// MARK: - サイドロード時の身元偽装

//
// ── なぜ必要か (v0.2.0) ──────────────────────────────────────
//
// 実機で Google ログインが弾かれた。
//
//   「ログインできませんでした」
//   「Google で安全性を確認できないため、このアプリにはログインできません。」
//
// 原因は bundle ID を `dev.vivimusic.ytmprobe` に変えたこと。
// Google の OAuth クライアントは
//
//   client_id 755973059757-iigsfdoqt2c4qm209soqp2dlrh33almr
//   bundle    com.google.ios.youtubemusic
//
// の組で登録されており、bundle ID が違うと認証サーバーが拒否する。
//
// **YouTube Music は未ログインでは 1 曲も再生できない**ことを
// 実測で確認済み (ゲスト scope のメディアキャッシュが 1 つも
// 作られなかった)。つまりログインが通らないとこの検証自体が成立しない。
//
// ── 何を偽装し、何を偽装しないか ────────────────────────────
//
// 偽装するのは **アプリが自分自身に対して答える文字列** だけ。
//
//   NSBundle.bundleIdentifier
//   NSBundle.infoDictionary[CFBundleIdentifier]
//   YTVersionUtils.appID
//   SSOConfiguration._applicationIdentifier
//   GULAppEnvironmentUtil.isFromAppStore
//
// 偽装「できない」ものは、実行時に本物を問い合わせる。
//
//   Keychain access group … Team ID から導出されカーネルが強制する
//   App Attest の証明書   … Apple が署名し App ID が焼き込まれる
//
// この線引きは YTLite の Sideloading.x と同じ考え方。
// App Attest は偽装できないままだが、tweak IPA が普通に動いている
// 実績から、通常の再生には要求されていないと見ている。
//

/// 公式の bundle ID。ここに戻して名乗る。
// ── v0.3.0: ホストを実行時に見分ける ────────────────────────
//
// YouTube Music では **未ログインだと 1 曲も再生できない**ことが
// 実機で確定した。URL は 3 形式とも「受理」を返したが、画面は
// オンボーディング (「楽しめる音楽は 1 億曲以上」+ ログインボタン)
// のまま動かなかった。
//
// そしてログインは App Attest の壁で通らない。
//
//   YTM で再生する → ログインが要る
//   ログインする   → App Attest が要る
//   App Attest     → サイドロード再署名では原理的に不可能
//
// 一方 **YouTube 本体は未ログインで全機能が使える**。
// YTLite / YTKillerPlus などの tweak が未ログインで動いており、
// しかも 1 MiB 制限に当たっていない。ログインが要らないなら
// App Attest の壁を丸ごと迂回できる。
//
// 必要なクラスは両アプリで共通だった (同じ内部フレームワークを
// 共有している)。違うのは AppDelegate の名前と bundle ID だけ。
//
//   YouTube Music : YTMAppDelegate / com.google.ios.youtubemusic
//   YouTube       : YTAppDelegate  / com.google.ios.youtube
//
// 同じ dylib で両方に注入できるよう、実行時に見分ける。

/// 注入先が YouTube Music か (そうでなければ YouTube 本体)。
static BOOL YTMProbeHostIsMusic(void) {
    static BOOL isMusic = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // NSBundle は偽装フックの影響を受けうるので、
        // 実行ファイル名で見分ける。こちらは書き換えていない。
        isMusic = (NSClassFromString(@"YTMAppDelegate") != nil);
    });
    return isMusic;
}

/// 名乗るべき公式の bundle ID。ホストに合わせて返す。
static NSString *YTMProbeOriginalBundleID(void) {
    return YTMProbeHostIsMusic() ? @"com.google.ios.youtubemusic"
                                 : @"com.google.ios.youtube";
}

/// 後方互換のため名前は残す。中身はホスト依存になった。
#define kYTMOriginalBundleID (YTMProbeOriginalBundleID())

/// 自分自身の NSBundle か。他のバンドルまで偽装すると壊れる。
static BOOL YTMProbeIsMainBundle(NSBundle *bundle) {
    return bundle == [NSBundle mainBundle];
}

/// Keychain の access group を実行時に問い合わせる。
///
/// access group は Team ID から導出され、カーネルが entitlement を見て
/// 強制する。偽装できないので、ダミー項目を通して**本物を聞く**。
static NSString *_Nullable YTMProbeAccessGroupID(void) {
    static NSString *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *query = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrAccount: @"bundleSeedID",
            (__bridge id)kSecAttrService: @"",
            (__bridge id)kSecReturnAttributes: (__bridge id)kCFBooleanTrue,
        };
        CFDictionaryRef result = NULL;
        OSStatus status =
            SecItemCopyMatching((__bridge CFDictionaryRef)query,
                                (CFTypeRef *)&result);
        if (status == errSecItemNotFound) {
            // 無ければ一度作って、割り当てられた access group を読む。
            status = SecItemAdd((__bridge CFDictionaryRef)query,
                                (CFTypeRef *)&result);
        }
        if (status == errSecSuccess && result) {
            NSDictionary *attrs = (__bridge_transfer NSDictionary *)result;
            cached = attrs[(__bridge id)kSecAttrAccessGroup];
            [YTMProbeLog add:@"Keychain access group: %@", cached];
        } else {
            [YTMProbeLog add:@"Keychain access group を取得できない (status=%d)",
                              (int)status];
        }
    });
    return cached;
}

//
// ── v0.2.2: フックをグループに分けた理由 ──────────────────
//
// v0.2.0 で偽装フックをまとめて有効にしたところ、LiveContainer で
// 起動時にクラッシュした。
//
//   -[__NSPlaceholderArray initWithObjects:count:]:
//     attempt to insert nil object from objects[0]
//
// スタックは YouTube Music の内部で、どのフックが引き金かは
// 外からは分からない。偽装している値のどれかが nil を生んでいる。
//
// まとめて有効/無効にするだけでは切り分けられないので、
// **1 つずつ切り替えられる** ようにグループを分けた。
// 実機のパネルから選び、次回起動で反映する。
//
// 既定はすべて無効。v0.1.5 (正常に起動していた版) と同じ状態から
// 始めて、1 つずつ入れて原因を特定する。
//

// ── NSBundle の bundle ID ──────────────────────────────────
//
// **最も疑わしい。** %hook NSBundle はプロセス内のすべての
// NSBundle に効く。LiveContainer 環境では LiveContainerShared 自身も
// NSBundle を使うため、巻き添えになりうる。
//
// `bundle == [NSBundle mainBundle]` で絞ってはいるが、
// LiveContainer はゲストアプリのバンドルを差し替えるので、
// 起動の早い段階では mainBundle が LiveContainer 自身を指す
// 可能性がある。その場合 LiveContainer の bundle ID を
// YouTube Music のものと偽ることになり、内部の照合が壊れる。
%group SpoofBundleID

%hook NSBundle

- (NSString *)bundleIdentifier {
    return YTMProbeIsMainBundle(self) ? kYTMOriginalBundleID : %orig;
}

- (NSDictionary *)infoDictionary {
    NSDictionary *original = %orig;
    if (!YTMProbeIsMainBundle(self)) return original;
    if (!original) return original;
    NSMutableDictionary *patched = [original mutableCopy];
    patched[@"CFBundleIdentifier"] = kYTMOriginalBundleID;
    return patched;
}

%end

%end  // group SpoofBundleID

// ── アプリ ID を返すユーティリティ ─────────────────────────
//
// NSBundle と違い、YouTube Music 自身のクラスなので影響範囲が狭い。
// 先にこちらだけを試すのが安全。
%group SpoofAppID

%hook YTVersionUtils

+ (NSString *)appID {
    return kYTMOriginalBundleID;
}

%end

%hook GPCDeviceInfo

+ (NSString *)bundleId {
    return kYTMOriginalBundleID;
}

%end

%end  // group SpoofAppID

// ── Firebase 系の環境判定 ──────────────────────────────────
//
// サイドロードだと機能を落とすのを防ぐ。
// ただし YES を返すと「App Store 版だからレシートがあるはず」と
// 判断する経路に入り、レシートが無くて nil を掴む恐れがある。
// **今回のクラッシュの候補のひとつ。**
%group SpoofAppStore

%hook GULAppEnvironmentUtil

+ (BOOL)isFromAppStore {
    return YES;
}

%end

%end  // group SpoofAppStore

// ── Google サインインの設定 ────────────────────────────────
//
// `applicationIdentifier` が OAuth クライアントの登録と一致しないと
// 認証が拒否される。ログイン阻止の直接の対策。
//
// ── v0.2.5 で直した点 ──────────────────────────────────────
//
// v0.2.0〜v0.2.4 では `initWithClientID:supportedAccountTypes:` を
// フックしていたが、**このセレクタは存在しなかった** (私の推定違い)。
// Logos は存在しないメソッドを %hook すると新規追加してしまい、
// 呼ばれないまま何も起きない。SpoofSSO を有効にしてもログインが
// 通らなかったのはこのため。
//
// バイナリを調べ直したところ、実際にあるのは:
//
//   T@"NSString",C,N,V_applicationIdentifier   readonly プロパティ
//   applicationIdentifier                       ゲッター
//   initWithClientID:allowMultiActiveAccounts:enableNoAccountMode:
//     enableIncognitoMode:enableIncognitoWipeout:showDefaultAccountSelector:
//     sharedContainerForProfileEnabled:omitAppNameInButtonsAndVoiceOver:
//     applicationIdentifier:
//
// init は引数が 9 個もあり、フックすると壊しやすい。
// **ゲッターを直接差し替える**ほうが単純で確実。
// 誰がいつ呼んでも公式の bundle ID が返る。
%group SpoofSSO

%hook SSOConfiguration

- (NSString *)applicationIdentifier {
    NSString *original = %orig;
    // 何が返っていたかを一度だけ記録する。効いているかの確認用。
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [YTMProbeLog add:@"SSOConfiguration.applicationIdentifier: %@ → %@",
                          original ?: @"(nil)", kYTMOriginalBundleID];
    });
    return kYTMOriginalBundleID;
}

%end

%end  // group SpoofSSO

// ── Keychain の access group ───────────────────────────────
//
// 偽装ではなく、実行時に本物を問い合わせて返す。
// 取得できなければ %orig に落とすので、単体では安全なはず。
//
// ただし LiveContainer では Keychain の扱いが通常と異なるため、
// SecItemAdd が予期しない結果を返す可能性がある。
%group RealKeychainGroup

%hook SSOKeychainHelper

+ (NSString *)accessGroup {
    NSString *real = YTMProbeAccessGroupID();
    return real ?: %orig;
}

%end

// SSOKeychainCore は存在しないクラスだった (実機で確認)。
// 存在しないメソッドを %hook すると Logos が新規追加してしまうので外す。

%end  // group RealKeychainGroup

// MARK: - パネルの差し込み

// パネルの差し込みは AppDelegate ごとに書く必要がある。
// %hook はクラス名を静的に取るので、共通化できない。
// 中身は YTMProbeInstallPanel() に寄せてある。

%group HostMusic

%hook YTMAppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)options {
    BOOL result = %orig;
    [YTMProbeLog add:@"YTMAppDelegate 起動を検知 (YouTube Music)"];
    YTMProbeInstallPanel();
    return result;
}

%end

%end  // group HostMusic

%group HostYouTube

%hook YTAppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)options {
    BOOL result = %orig;
    [YTMProbeLog add:@"YTAppDelegate 起動を検知 (YouTube 本体)"];
    YTMProbeInstallPanel();
    return result;
}

%end

%end  // group HostYouTube

/// パネルを画面に出す。AppDelegate のフックから呼ぶ。
///
/// %hook はクラス名を静的に取るため AppDelegate ごとに書く必要があるが、
/// 中身は同じなのでここに寄せる。
static void YTMProbeInstallPanel(void) {

    // UI ができあがるのを待ってからパネルを出す。
    // 起動直後だとウィンドウがまだ無い。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIWindow *window = YTMProbeKeyWindow();
        if (!window) {
            [YTMProbeLog add:@"ウィンドウが見つからずパネルを出せない"];
            return;
        }

        CGRect bounds = window.bounds;
        CGRect frame = CGRectMake(12,
                                  bounds.size.height - 260,
                                  bounds.size.width - 24,
                                  240);
        YTMProbePanel *panel = [[YTMProbePanel alloc] initWithFrame:frame];
        panel.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        [window addSubview:panel];
        [YTMProbeLog add:@"パネルを表示した"];

        // ここまで来たら起動は完走とみなす。
        // これを記録しないと、次回起動で「前回落ちた」と判断されて
        // 設定が戻ってしまう。
        [YTMProbeSettings markLaunchCompleted];

        // 起動時に一度だけシンボル確認を回す
        YTMProbeVerifySymbols();
    });
}

// MARK: - 入口

%ctor {
    // App Store からの正規インストールでは何もしない。
    // (レシートがあるかどうかで判定する。YTLite の Sideloading.x と同じ考え方)
    BOOL isAppStoreApp = [[NSFileManager defaultManager]
        fileExistsAtPath:[NSBundle mainBundle].appStoreReceiptURL.path];

    [YTMProbeLog add:@"YTMProbe 読み込み (AppStore=%@ / bundle=%@)",
                      isAppStoreApp ? @"はい" : @"いいえ",
                      [NSBundle mainBundle].bundleIdentifier];

    %init;

    // ── v0.3.0: ホストに応じて AppDelegate のフックを選ぶ ────────
    //
    // YouTube Music と YouTube 本体では AppDelegate の名前が違う。
    // 存在しないほうを %init すると Logos が空のクラスを作ってしまうので、
    // 実在するほうだけを有効にする。
    if (NSClassFromString(@"YTMAppDelegate")) {
        %init(HostMusic);
        [YTMProbeLog add:@"ホスト: YouTube Music"];
    } else if (NSClassFromString(@"YTAppDelegate")) {
        %init(HostYouTube);
        [YTMProbeLog add:@"ホスト: YouTube 本体 "
                          "(未ログインで再生できるので App Attest を迂回できる)"];
    } else {
        [YTMProbeLog add:@"⚠ 既知の AppDelegate が無い。パネルを出せない"];
    }

    // ── v0.2.2: 偽装フックは 1 つずつ有効にする ────────────────
    //
    // まとめて入れたら LiveContainer で起動時に落ちたため、
    // パネルから選んだものだけを次回起動で有効にする方式にした。
    //
    // 正規インストールでは何もしない (壊す理由が無い)。
    if (isAppStoreApp) {
        [YTMProbeLog add:@"App Store 版なので偽装フックは入れない"];
        return;
    }

    // 前回の起動が完走していなければ、その設定が原因とみて全部戻す。
    // これが無いと、落ちる設定にした瞬間に二度と起動できなくなる。
    if ([YTMProbeSettings didPreviousLaunchFail]) {
        [YTMProbeLog add:@"⚠ 前回の起動が完走しなかった。"
                          "偽装フックをすべて無効に戻す"];
        [YTMProbeSettings disableAll];
    }
    [YTMProbeSettings markLaunchStarted];

    NSMutableArray<NSString *> *on = [NSMutableArray array];
    if ([YTMProbeSettings enabled:@"SpoofAppID"]) {
        %init(SpoofAppID);        [on addObject:@"SpoofAppID"];
    }
    if ([YTMProbeSettings enabled:@"SpoofSSO"]) {
        %init(SpoofSSO);          [on addObject:@"SpoofSSO"];
    }
    if ([YTMProbeSettings enabled:@"RealKeychainGroup"]) {
        %init(RealKeychainGroup); [on addObject:@"RealKeychainGroup"];
    }
    if ([YTMProbeSettings enabled:@"SpoofAppStore"]) {
        %init(SpoofAppStore);     [on addObject:@"SpoofAppStore"];
    }
    if ([YTMProbeSettings enabled:@"SpoofBundleID"]) {
        %init(SpoofBundleID);     [on addObject:@"SpoofBundleID"];
    }

    [YTMProbeLog add:@"有効な偽装フック: %@",
                      on.count ? [on componentsJoinedByString:@", "] : @"なし"];
}
