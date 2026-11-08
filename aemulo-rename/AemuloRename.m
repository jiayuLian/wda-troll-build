// AemuloRename.m — Aemulo 2.0 卡片重命名（TrollStore 零依赖注入版）
//
// 目标 App：com.amywhile.Aemulo，2.0 build 1432
// 注入方式：dylib 放进 Payload/Aemulo.app/Frameworks/，主二进制加一条 LC_LOAD_DYLIB。
//
// 不依赖 CydiaSubstrate / ElleKit —— 只用 objc/runtime 的 method_setImplementation。
// 不 hook 任何 Swift 私有方法，只挂 UIViewController 的 viewDidLoad / viewDidAppear
// 这两个公开生命周期，然后在 Home 页导航栏塞一个「改名」按钮。
//
// 数据来源：/var/mobile/Containers/Shared/AppGroup/group.amywhile.aemulo/TagDatabase.sqlite3
// 主表：MiFareTagTable / EMVTagTable / AmiiboTagTable / NDEFTagTable /
//       GenericATag / GenericBTag / GenericFTag，都有 uuid + name 两列。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sqlite3.h>
#include <string.h>

// 版本标记：CI 用它做硬断言，认版本别认文件大小
static NSString *const kAGVer = @"AG_VER_V5";

static NSString *const kAGGroupID = @"group.amywhile.aemulo";
static NSString *const kAGDBName = @"TagDatabase.sqlite3";

#pragma mark - 数据库路径

// App Group 容器路径。entitlement 拿不到时退化为扫目录。
static NSString *AGDatabasePath(void) {
    static NSString *cached = nil;
    if (cached) return cached;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *group = [fm containerURLForSecurityApplicationGroupIdentifier:kAGGroupID];
    if (group) {
        NSString *p = [[group URLByAppendingPathComponent:kAGDBName] path];
        if ([fm fileExistsAtPath:p]) {
            cached = p;
            return cached;
        }
    }
    // 兜底：AppGroup 根目录下逐个找（进程有该 group 权限时才读得到）
    NSString *base = @"/var/mobile/Containers/Shared/AppGroup";
    for (NSString *sub in [fm contentsOfDirectoryAtPath:base error:NULL]) {
        NSString *p = [base stringByAppendingPathComponent:
                       [sub stringByAppendingPathComponent:kAGDBName]];
        if ([fm fileExistsAtPath:p]) {
            cached = p;
            return cached;
        }
    }
    NSLog(@"[AemuloRename] TagDatabase.sqlite3 not found");
    return nil;
}

#pragma mark - 数据库读写

static NSString *const kAGTables[] = {
    @"MiFareTagTable", @"EMVTagTable", @"AmiiboTagTable", @"NDEFTagTable",
    @"GenericATag", @"GenericBTag", @"GenericFTag",
};
static const NSUInteger kAGTableCount = sizeof(kAGTables) / sizeof(kAGTables[0]);

// 返回 @[@{table, uuid, name, uid}]，按名字排序。uid 有就带（hex 文本）。
static NSArray<NSDictionary *> *AGLoadCards(NSString *dbPath) {
    NSMutableArray *out = [NSMutableArray array];
    if (!dbPath) return out;

    sqlite3 *db = NULL;
    if (sqlite3_open_v2(dbPath.fileSystemRepresentation, &db,
                        SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        NSLog(@"[AemuloRename] open(readonly) failed: %s", sqlite3_errmsg(db));
        if (db) sqlite3_close(db);
        return out;
    }
    sqlite3_busy_timeout(db, 2000);

    for (NSUInteger i = 0; i < kAGTableCount; i++) {
        NSString *table = kAGTables[i];
        // hex(uid) 只在有 uid 列的表上成立，没有就退回两列
        NSString *sql = [NSString stringWithFormat:
                         @"SELECT uuid, name, hex(uid) FROM \"%@\" ORDER BY name COLLATE NOCASE", table];
        sqlite3_stmt *st = NULL;
        BOOL hasUID = YES;
        if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &st, NULL) != SQLITE_OK) {
            hasUID = NO;
            sql = [NSString stringWithFormat:
                   @"SELECT uuid, name FROM \"%@\" ORDER BY name COLLATE NOCASE", table];
            if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &st, NULL) != SQLITE_OK) continue;
        }
        while (sqlite3_step(st) == SQLITE_ROW) {
            const char *uuid = (const char *)sqlite3_column_text(st, 0);
            const char *name = (const char *)sqlite3_column_text(st, 1);
            const char *uid = hasUID ? (const char *)sqlite3_column_text(st, 2) : NULL;
            if (!uuid) continue;
            [out addObject:@{
                @"table": table,
                @"uuid": [NSString stringWithUTF8String:uuid],
                @"name": name ? [NSString stringWithUTF8String:name] : @"",
                @"uid": (uid && hasUID) ? [NSString stringWithUTF8String:uid] : @"",
            }];
        }
        sqlite3_finalize(st);
    }
    sqlite3_close(db);
    return out;
}

static BOOL AGRenameCard(NSString *dbPath, NSString *table, NSString *uuid, NSString *newName) {
    if (!dbPath.length || !table.length || !uuid.length) return NO;

    sqlite3 *db = NULL;
    if (sqlite3_open_v2(dbPath.fileSystemRepresentation, &db,
                        SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
        NSLog(@"[AemuloRename] open(readwrite) failed: %s", sqlite3_errmsg(db));
        if (db) sqlite3_close(db);
        return NO;
    }
    sqlite3_busy_timeout(db, 5000);

    // 表名来自上面的白名单常量（不是用户输入），可以直接拼
    NSString *sql = [NSString stringWithFormat:@"UPDATE \"%@\" SET name = ?1 WHERE uuid = ?2", table];
    sqlite3_stmt *st = NULL;
    BOOL ok = NO;
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_text(st, 1, newName.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 2, uuid.UTF8String, -1, SQLITE_TRANSIENT);
        int rc = sqlite3_step(st);
        ok = (rc == SQLITE_DONE);
        // changes==0 可能是"新名字和旧名字一样"，回查一次再定成败
        if (ok && sqlite3_changes(db) == 0) {
            sqlite3_stmt *chk = NULL;
            NSString *q = [NSString stringWithFormat:@"SELECT name FROM \"%@\" WHERE uuid = ?1", table];
            if (sqlite3_prepare_v2(db, q.UTF8String, -1, &chk, NULL) == SQLITE_OK) {
                sqlite3_bind_text(chk, 1, uuid.UTF8String, -1, SQLITE_TRANSIENT);
                if (sqlite3_step(chk) == SQLITE_ROW) {
                    const char *cur = (const char *)sqlite3_column_text(chk, 0);
                    ok = cur && strcmp(cur, newName.UTF8String) == 0;
                } else {
                    ok = NO;
                }
                sqlite3_finalize(chk);
            } else {
                ok = NO;
            }
        }
        if (!ok) NSLog(@"[AemuloRename] update rc=%d changes=%d err=%s",
                       rc, sqlite3_changes(db), sqlite3_errmsg(db));
        sqlite3_finalize(st);
    } else {
        NSLog(@"[AemuloRename] prepare failed: %s", sqlite3_errmsg(db));
    }
    sqlite3_close(db);
    return ok;
}

// 删除一张卡：只删这一行，其它字段不动
static BOOL AGDeleteCard(NSString *dbPath, NSString *table, NSString *uuid) {
    if (!dbPath.length || !table.length || !uuid.length) return NO;

    sqlite3 *db = NULL;
    if (sqlite3_open_v2(dbPath.fileSystemRepresentation, &db,
                        SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
        NSLog(@"[AemuloRename] delete open failed: %s", sqlite3_errmsg(db));
        if (db) sqlite3_close(db);
        return NO;
    }
    sqlite3_busy_timeout(db, 5000);

    NSString *sql = [NSString stringWithFormat:@"DELETE FROM \"%@\" WHERE uuid = ?1", table];
    sqlite3_stmt *st = NULL;
    BOOL ok = NO;
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_text(st, 1, uuid.UTF8String, -1, SQLITE_TRANSIENT);
        ok = (sqlite3_step(st) == SQLITE_DONE) && (sqlite3_changes(db) > 0);
        if (!ok) NSLog(@"[AemuloRename] delete failed changes=%d err=%s",
                       sqlite3_changes(db), sqlite3_errmsg(db));
        sqlite3_finalize(st);
    } else {
        NSLog(@"[AemuloRename] delete prepare failed: %s", sqlite3_errmsg(db));
    }
    sqlite3_close(db);
    return ok;
}

// 导出库：走 SQLite 在线备份接口，App 正在写也能拿到一致的快照
static NSString *AGExportDatabase(NSString *dbPath) {
    if (!dbPath.length) return nil;

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *name = [NSString stringWithFormat:@"TagDatabase-%@.sqlite3",
                      [df stringFromDate:[NSDate date]]];
    NSString *dst = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    [[NSFileManager defaultManager] removeItemAtPath:dst error:NULL];

    sqlite3 *from = NULL;
    if (sqlite3_open_v2(dbPath.fileSystemRepresentation, &from,
                        SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        NSLog(@"[AemuloRename] export open failed: %s", sqlite3_errmsg(from));
        if (from) sqlite3_close(from);
        return nil;
    }
    sqlite3_busy_timeout(from, 5000);

    BOOL ok = NO;
    sqlite3 *to = NULL;
    if (sqlite3_open_v2(dst.fileSystemRepresentation, &to,
                        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL) == SQLITE_OK) {
        sqlite3_backup *bk = sqlite3_backup_init(to, "main", from, "main");
        if (bk) {
            int rc = sqlite3_backup_step(bk, -1);
            sqlite3_backup_finish(bk);
            ok = (rc == SQLITE_DONE);
        }
        sqlite3_close(to);
    }
    sqlite3_close(from);

    if (!ok) {
        NSLog(@"[AemuloRename] export failed");
        [[NSFileManager defaultManager] removeItemAtPath:dst error:NULL];
        return nil;
    }
    NSLog(@"[AemuloRename] exported %@", dst);
    return dst;
}

#pragma mark - 汉化

// 词典：英文原文 → 中文。只做整串精确匹配 + 少量前缀规则，
// 不动卡片名之类用户数据（除非恰好等于"Name"这种 UI 词）。
static NSString *AGTranslate(NSString *s) {
    if (!s.length) return s;
    static NSDictionary<NSString *, NSString *> *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            // 主流程 / 读卡
            @"Present Tag to Read":        @"将标签贴近手机",
            @"Present Phone to Reader":    @"将手机贴近读卡器",
            @"Read Tag":                   @"读取标签",
            @"Standard Reader":            @"标准读卡器",
            @"Ultralight Reader":          @"Ultralight 读卡器",
            @"Amiibo Reader":              @"Amiibo 读卡器",
            @"MiFare Dictionary Attack":   @"MiFare 字典攻击",
            @"Manually Create":            @"手动创建",
            @"Connecting to chip":         @"正在连接芯片",
            @"Scanning":                   @"扫描中",
            @"Scan":                       @"扫描",
            @"Emulate":                    @"模拟",
            @"Start":                      @"开始",
            @"Stop":                       @"停止",
            // 通用
            @"Save":                       @"保存",
            @"Save and Close":             @"保存并关闭",
            @"Discard and Close":          @"放弃并关闭",
            @"Discard":                    @"放弃",
            @"Cancel":                     @"取消",
            @"Close":                      @"关闭",
            @"Back":                       @"返回",
            @"Done":                       @"完成",
            @"Edit":                       @"编辑",
            @"Delete":                     @"删除",
            @"Add":                        @"添加",
            @"Name":                       @"名称",
            @"Date":                       @"日期",
            @"Date Added":                 @"添加时间",
            @"Type":                       @"类型",
            @"Favourite":                  @"收藏",
            @"Favorite":                   @"收藏",
            @"Favourites":                 @"收藏",
            @"Favorites":                  @"收藏",
            @"Sort By":                    @"排序方式",
            @"Sort By Name":               @"按名称排序",
            @"Enable Haptics":             @"触感反馈",
            @"General":                    @"通用",
            @"Settings":                   @"设置",
            @"Reader Settings":            @"读卡器设置",
            @"Language Preference":        @"语言偏好",
            @"Change Log":                 @"更新日志",
            @"About":                      @"关于",
            @"Version":                    @"版本",
            @"Beta":                       @"测试版",
            @"Tags":                       @"标签",
            @"Cards":                      @"卡片",
            @"Home":                       @"主页",
            @"Tag Info":                   @"标签信息",
            @"Unknown Tag Type":           @"未知标签类型",
            @"Sign in with Chariz":        @"使用 Chariz 登录",
            @"Made with love":             @"用爱制作",
            // 设置项 / 提示
            @"Added Key Path":             @"已添加密钥路径",
            @"Amiibo Key Path":            @"Amiibo 密钥路径",
            @"Invalid Key Path":           @"密钥路径无效",
            @"key_retail.bin is invalid size. Should be 160 bytes.": @"key_retail.bin 大小不对，应为 160 字节。",
            @"key_retain.bin does not match expected file hash.":    @"key_retain.bin 与预期哈希不符。",
            @"Which tag types to search for. If unsure leave all enabled.": @"选择要搜索的标签类型，不确定就全部保持开启。",
            @"Type A":                     @"A 型",
            @"Type B":                     @"B 型",
            @"Type ACM":                   @"ACM 型",
            @"Type V":                     @"V 型",
            @"Type ISO 15693":             @"ISO 15693",
            // 错误
            @"Failed to create database connection": @"无法创建数据库连接",
            @"Failed to load changelogs":  @"更新日志加载失败",
            @"Error Connecting to Socket": @"连接失败",
            @"Failed to initialise chip.": @"芯片初始化失败。",
            @"Failed to communicate with chip.": @"与芯片通信失败。",
            @"Failed to reset chip.":      @"芯片复位失败。",
            @"Failed to reset chip":       @"芯片复位失败",
            @"Failed to make socket.":     @"创建连接失败。",
            @"Client has invalid IOKit permissions.": @"客户端 IOKit 权限无效。",
            @"No tag detected":            @"未检测到标签",
            @"Not supported":              @"不支持",
            @"Unsupported":                @"不支持",
            @"Unknown":                    @"未知",
            @"Error":                      @"错误",
            @"OK":                         @"好",
        };
    });
    NSString *hit = map[s];
    if (hit) return hit;
    if ([s hasPrefix:@"Failed with: "])
        return [@"失败：" stringByAppendingString:[s substringFromIndex:13]];
    return s;
}

// —— UIView 文本入口全部过一遍词典 ——
static void (*AGOrigSetText)(id, SEL, NSString *);
static NSString *AGNameForUIDText(NSString *s);
static void AGSetText(id self, SEL _cmd, NSString *text) {
    NSString *out = AGTranslate(text);
    // 不限定 cell 类型：主页 cell 的类名不一定叫 TagCell，
    // 只要文本整体就是一个 UID 且库里有对应备注名，就换成备注名。
    if (out == text && [self isKindOfClass:[UILabel class]]) {
        NSString *n = AGNameForUIDText(text);
        if (n.length) out = n;
    }
    AGOrigSetText(self, _cmd, out);
}

static void (*AGOrigSetAttrText)(id, SEL, NSAttributedString *);
static void AGSetAttrText(id self, SEL _cmd, NSAttributedString *text) {
    if (!text.length) { AGOrigSetAttrText(self, _cmd, text); return; }
    NSString *zh = AGTranslate(text.string);
    if (zh == text.string || [zh isEqualToString:text.string]) { AGOrigSetAttrText(self, _cmd, text); return; }
    NSMutableAttributedString *m = [text mutableCopy];
    [m replaceCharactersInRange:NSMakeRange(0, m.length) withString:zh];
    AGOrigSetAttrText(self, _cmd, m);
}

static void (*AGOrigButtonTitle)(id, SEL, NSString *, UIControlState);
static void AGButtonTitle(id self, SEL _cmd, NSString *title, UIControlState state) {
    AGOrigButtonTitle(self, _cmd, AGTranslate(title), state);
}

static void (*AGOrigNavTitle)(id, SEL, NSString *);
static void AGNavTitle(id self, SEL _cmd, NSString *title) {
    AGOrigNavTitle(self, _cmd, AGTranslate(title));
}

// UIViewController:-setTitle: 和 UINavigationItem:-setTitle: 是两个不同的实现，
// 必须各存一份原始 IMP，否则第二次 swizzle 会把第一次的指针覆盖掉。
static void (*AGOrigVCTitle)(id, SEL, NSString *);
static void AGVCTitle(id self, SEL _cmd, NSString *title) {
    AGOrigVCTitle(self, _cmd, AGTranslate(title));
}

static void (*AGOrigBarItemTitle)(id, SEL, NSString *);
static void AGBarItemTitle(id self, SEL _cmd, NSString *title) {
    AGOrigBarItemTitle(self, _cmd, AGTranslate(title));
}

static void (*AGOrigPlaceholder)(id, SEL, NSString *);
static void AGPlaceholder(id self, SEL _cmd, NSString *text) {
    AGOrigPlaceholder(self, _cmd, AGTranslate(text));
}

static void (*AGOrigSegmentTitle)(id, SEL, NSString *, NSInteger);
static void AGSegmentTitle(id self, SEL _cmd, NSString *title, NSInteger idx) {
    AGOrigSegmentTitle(self, _cmd, AGTranslate(title), idx);
}

static id (*AGOrigAlert)(id, SEL, NSString *, NSString *, UIAlertControllerStyle);
static id AGAlert(id self, SEL _cmd, NSString *title, NSString *message, UIAlertControllerStyle style) {
    return AGOrigAlert(self, _cmd, AGTranslate(title), AGTranslate(message), style);
}

static id (*AGOrigAction)(id, SEL, NSString *, UIAlertActionStyle, void (^)(UIAlertAction *));
static id AGAction(id self, SEL _cmd, NSString *title, UIAlertActionStyle style, void (^handler)(UIAlertAction *)) {
    return AGOrigAction(self, _cmd, AGTranslate(title), style, handler);
}

static void __attribute__((unused)) AGSwizzleTextSetters(void) {
    struct { Class cls; SEL sel; void *impl; void **orig; BOOL classMethod; } table[] = {
        { [UILabel class], @selector(setText:), (void *)AGSetText, (void **)&AGOrigSetText, NO },
        { [UILabel class], @selector(setAttributedText:), (void *)AGSetAttrText, (void **)&AGOrigSetAttrText, NO },
        { [UIButton class], @selector(setTitle:forState:), (void *)AGButtonTitle, (void **)&AGOrigButtonTitle, NO },
        { [UINavigationItem class], @selector(setTitle:), (void *)AGNavTitle, (void **)&AGOrigNavTitle, NO },
        { [UIViewController class], @selector(setTitle:), (void *)AGVCTitle, (void **)&AGOrigVCTitle, NO },
        { [UIBarButtonItem class], @selector(setTitle:), (void *)AGBarItemTitle, (void **)&AGOrigBarItemTitle, NO },
        { [UITextField class], @selector(setPlaceholder:), (void *)AGPlaceholder, (void **)&AGOrigPlaceholder, NO },
        { [UISegmentedControl class], @selector(setTitle:forSegmentAtIndex:), (void *)AGSegmentTitle, (void **)&AGOrigSegmentTitle, NO },
        { [UIAlertController class], @selector(alertControllerWithTitle:message:preferredStyle:), (void *)AGAlert, (void **)&AGOrigAlert, YES },
        { [UIAlertAction class], @selector(actionWithTitle:style:handler:), (void *)AGAction, (void **)&AGOrigAction, YES },
    };
    for (size_t i = 0; i < sizeof(table) / sizeof(table[0]); i++) {
        Method m = table[i].classMethod
            ? class_getClassMethod(table[i].cls, table[i].sel)
            : class_getInstanceMethod(table[i].cls, table[i].sel);
        if (!m) continue;
        *table[i].orig = (void *)method_getImplementation(m);
        method_setImplementation(m, (IMP)table[i].impl);
    }
}

#pragma mark - 主页列表显示备注名

@class AGCardListVC;

// 主页每行的标题是 UID（源码里由 String 插值拼成 "0x"+hex，二进制里抓不到格式串），
// name 只在 Tag Info 页出现。所以只能在文本落到 UILabel 的那一刻把它换成备注名。
// 映射表直接从库里现取，不依赖 Aemulo 自己的内存缓存。
static NSMutableDictionary<NSString *, NSString *> *AGNameMap = nil;
static NSTimeInterval AGNameMapAt = 0;

static BOOL AGIsUIDText(NSString *s) {
    if (s.length < 5 || s.length > 21) return NO;
    if (![s hasPrefix:@"0x"] && ![s hasPrefix:@"0X"]) return NO;
    static NSCharacterSet *hex = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    });
    for (NSUInteger i = 2; i < s.length; i++) {
        if (![hex characterIsMember:[s characterAtIndex:i]]) return NO;
    }
    return YES;
}

// "0xc30ac319" 和 "0xC30AC319" 要落到同一个键上
static NSString *AGUIDKey(NSString *s) {
    return [@"0x" stringByAppendingString:[[s substringFromIndex:2] uppercaseString]];
}

static void AGRebuildNameMap(void) {
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    for (NSDictionary *c in AGLoadCards(AGDatabasePath())) {
        NSString *uid = c[@"uid"];      // SQLite hex()，大写无前缀
        NSString *name = c[@"name"];
        if (!uid.length || !name.length) continue;
        m[[@"0x" stringByAppendingString:[uid uppercaseString]]] = name;
        // 4 字节 UID 有的地方会补零到 8 位，两种写法都登记
        if (uid.length < 8) {
            NSString *pad = [uid uppercaseString];
            while (pad.length < 8) pad = [@"0" stringByAppendingString:pad];
            m[[@"0x" stringByAppendingString:pad]] = name;
        }
    }
    AGNameMap = m;
    AGNameMapAt = [NSDate date].timeIntervalSince1970;
}

static NSString *AGNameForUIDText(NSString *s) {
    if (!AGIsUIDText(s)) return nil;
    if (!AGNameMap) AGRebuildNameMap();
    NSString *hit = AGNameMap[AGUIDKey(s)];
    if (hit) return hit;
    // 没命中可能刚改完名 / 刚加了卡：5 秒节流重建一次
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - AGNameMapAt > 5) {
        AGRebuildNameMap();
        hit = AGNameMap[AGUIDKey(s)];
    }
    return hit;
}

static void AGFixLabelsIn(UIView *v) {
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        if (AGIsUIDText(l.text)) {
            NSString *n = AGNameForUIDText(l.text);
            if (n.length && AGOrigSetText) AGOrigSetText(l, @selector(setText:), n);
        }
        return;
    }
    for (UIView *s in v.subviews) AGFixLabelsIn(s);
}

// 兜底：文本可能在加入 cell 之前就设好了，那时 superview 链上还没有 cell。
// 每次 cell 布局完再扫一遍，成本只有几个 label。
static void (*AGOrigCellLayout)(id, SEL);
static void AGCellLayout(id self, SEL _cmd) {
    AGOrigCellLayout(self, _cmd);
    // 任意 cell 都扫，不只 TagCell：逐个 label 只做一次前缀判断，开销可以忽略
    if (![self isKindOfClass:[UITableViewCell class]]) return;
    if (!AGNameMap) AGRebuildNameMap();
    if (!AGNameMap.count) return;
    AGFixLabelsIn((UIView *)self);
}

static void AGReloadTablesIn(UIView *v) {
    if ([v isKindOfClass:[UITableView class]]) {
        UITableView *tv = (UITableView *)v;
        // 自己的卡片管理页不在这里刷，免得正在弹窗时被 reload 打断。
        // 用 objc_getClass 取类对象：这时候 AGCardListVC 还只是前置声明
        Class listCls = objc_getClass("AGCardListVC");
        if (!listCls || ![tv.dataSource isKindOfClass:listCls]) [tv reloadData];
        return;
    }
    for (UIView *s in v.subviews) AGReloadTablesIn(s);
}

static void AGRefreshOtherTables(void) {
    AGRebuildNameMap();
    for (UIWindow *w in UIApplication.sharedApplication.windows) AGReloadTablesIn(w);
}

#pragma mark - 列表页

@interface AGCardListVC : UITableViewController
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *cards;
@property (nonatomic, copy) NSString *dbPath;
- (void)done;
- (void)reload;
- (void)exportDB;
- (void)toast:(NSString *)title message:(NSString *)message;
@end

@implementation AGCardListVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"卡片管理";
    self.dbPath = AGDatabasePath();
    self.cards = [NSMutableArray array];

    UIRefreshControl *rc = [[UIRefreshControl alloc] init];
    [rc addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = rc;

    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                          target:self
                                                                          action:@selector(done)];
    UIBarButtonItem *exportItem = [[UIBarButtonItem alloc] initWithTitle:@"导出"
                                                                   style:UIBarButtonItemStylePlain
                                                                  target:self
                                                                  action:@selector(exportDB)];
    self.navigationItem.rightBarButtonItems = @[done, exportItem];
    [self reload];
}

- (void)done {
    AGRefreshOtherTables();
    if (self.navigationController) [self.navigationController popViewControllerAnimated:YES];
    else [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)reload {
    self.cards = [AGLoadCards(self.dbPath) mutableCopy];
    [self.tableView reloadData];
    [self.refreshControl endRefreshing];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.cards.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (!self.dbPath) return @"找不到 TagDatabase.sqlite3，改名不可用。";
    if (!self.cards.count) return @"这张库里还没有卡片。";
    return @"点一行改名，左滑删除，右上角导出库。主页列表会立刻显示新名字；若某行还是 UID，下拉主页刷新或重开 App。";
}

- (void)toast:(NSString *)title message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                                 message:message
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)exportDB {
    NSString *path = AGExportDatabase(self.dbPath);
    if (!path) {
        [self toast:@"导出失败" message:@"找不到数据库，或它正被占用。"];
        return;
    }
    UIActivityViewController *av =
        [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]]
                                           applicationActivities:nil];
    av.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
    [self presentViewController:av animated:YES completion:nil];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *c = self.cards[indexPath.row];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *del =
        [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                title:@"删除"
                                              handler:^(UIContextualAction *action, UIView *src,
                                                        void (^completion)(BOOL)) {
        UIAlertController *ac =
            [UIAlertController alertControllerWithTitle:@"删除这张卡？"
                                                message:[NSString stringWithFormat:@"%@\n%@",
                                                         c[@"name"], c[@"uuid"]]
                                         preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *a) { completion(NO); }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) {
            BOOL ok = AGDeleteCard(weakSelf.dbPath, c[@"table"], c[@"uuid"]);
            if (ok) {
                [weakSelf reload];
                AGRefreshOtherTables();
            } else {
                [weakSelf toast:@"删除失败" message:@"数据库可能被占用，下拉刷新后重试。"];
            }
            completion(ok);
        }]];
        [weakSelf presentViewController:ac animated:YES completion:nil];
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"AGCardCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                            reuseIdentifier:cid];
    NSDictionary *c = self.cards[indexPath.row];
    cell.textLabel.text = c[@"name"];

    NSString *table = c[@"table"];
    NSString *shortTable = [table stringByReplacingOccurrencesOfString:@"TagTable" withString:@""];
    if ([table isEqualToString:@"GenericATag"]) shortTable = @"GenericA";
    if ([table isEqualToString:@"GenericBTag"]) shortTable = @"GenericB";
    if ([table isEqualToString:@"GenericFTag"]) shortTable = @"GenericF";

    NSString *uid = c[@"uid"];
    cell.detailTextLabel.text = uid.length
        ? [NSString stringWithFormat:@"%@ · %@", shortTable, uid]
        : shortTable;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *c = self.cards[indexPath.row];

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"重命名卡片"
                                                                message:c[@"uuid"]
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = c[@"name"];
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        tf.placeholder = @"新名字";
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakAC = ac;
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
        NSString *input = weakAC.textFields.firstObject.text ?: @"";
        NSString *name = [input stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!name.length) return;

        BOOL ok = AGRenameCard(weakSelf.dbPath, c[@"table"], c[@"uuid"], name);
        if (!ok) {
            UIAlertController *err = [UIAlertController alertControllerWithTitle:@"写入失败"
                                                                        message:@"数据库可能被占用，下拉刷新后重试。"
                                                                 preferredStyle:UIAlertControllerStyleAlert];
            [err addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [weakSelf presentViewController:err animated:YES completion:nil];
            return;
        }
        NSMutableDictionary *m = [c mutableCopy];
        m[@"name"] = name;
        [weakSelf.cards replaceObjectAtIndex:indexPath.row withObject:m];
        [weakSelf.tableView reloadRowsAtIndexPaths:@[indexPath]
                                  withRowAnimation:UITableViewRowAnimationFade];
        // 主页列表的标题是 UID，改完名要重刷一遍才会走我们的替换
        AGRefreshOtherTables();
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end

#pragma mark - 入口

@interface AGRenamEntry : NSObject
+ (instancetype)shared;
- (void)open;
- (void)handleLongPress:(UILongPressGestureRecognizer *)g;
@end

static UIViewController *AGTopViewController(void) {
    UIWindow *key = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w.isKeyWindow) { key = w; break; }
    }
    UIViewController *vc = key.rootViewController;
    while (vc) {
        UIViewController *next = nil;
        if (vc.presentedViewController) next = vc.presentedViewController;
        else if ([vc isKindOfClass:[UINavigationController class]])
            next = ((UINavigationController *)vc).visibleViewController;
        else if ([vc isKindOfClass:[UITabBarController class]])
            next = ((UITabBarController *)vc).selectedViewController;
        if (!next || next == vc) break;
        vc = next;
    }
    return vc;
}

@implementation AGRenamEntry

+ (instancetype)shared {
    static AGRenamEntry *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[AGRenamEntry alloc] init]; });
    return s;
}

- (void)open {
    UIViewController *top = AGTopViewController();
    if (!top) return;
    if ([top isKindOfClass:[AGCardListVC class]]) return;

    AGCardListVC *list = [[AGCardListVC alloc] initWithStyle:UITableViewStyleInsetGrouped];
    if (top.navigationController) {
        [top.navigationController pushViewController:list animated:YES];
    } else {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:list];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [top presentViewController:nav animated:YES completion:nil];
    }
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) [self open];
}

@end

#pragma mark - swizzle

static void (*AGOrigViewDidLoad)(id, SEL);
static void (*AGOrigViewDidAppear)(id, SEL, BOOL);
static const void *kAGGestureKey = &kAGGestureKey;

static BOOL AGIsTagListController(UIViewController *vc) {
    NSString *cls = NSStringFromClass([vc class]);
    // Swift 类名可能是 _TtC6Aemulo18HomeViewController，也可能是 Aemulo.HomeViewController，
    // 两种都含这个子串
    return [cls containsString:@"HomeViewController"] || [cls containsString:@"TagList"];
}

static void AGInstallEntry(UIViewController *vc) {
    if (!AGIsTagListController(vc)) return;

    // 每次出现都检查一遍：App 自己可能在 viewWillAppear 里重设 rightBarButtonItems
    NSArray *existing = vc.navigationItem.rightBarButtonItems ?: @[];
    for (UIBarButtonItem *i in existing) {
        if ([i.title isEqualToString:@"改名"]) return;
    }

    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithTitle:@"改名"
                                                             style:UIBarButtonItemStylePlain
                                                            target:[AGRenamEntry shared]
                                                            action:@selector(open)];
    NSMutableArray *items = [NSMutableArray arrayWithArray:existing];
    [items insertObject:item atIndex:0];
    vc.navigationItem.rightBarButtonItems = items;

    // 兜底入口：窗口上双指长按，导航栏被藏起来时也能进
    UIWindow *win = vc.view.window;
    if (win && !objc_getAssociatedObject(win, kAGGestureKey)) {
        objc_setAssociatedObject(win, kAGGestureKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UILongPressGestureRecognizer *lp =
            [[UILongPressGestureRecognizer alloc] initWithTarget:[AGRenamEntry shared]
                                                          action:@selector(handleLongPress:)];
        lp.numberOfTouchesRequired = 2;
        lp.minimumPressDuration = 0.8;
        [win addGestureRecognizer:lp];
    }
}

static void AGViewDidLoad(id self, SEL _cmd) {
    AGOrigViewDidLoad(self, _cmd);
    if ([self isKindOfClass:[UIViewController class]]) AGInstallEntry((UIViewController *)self);
}

static void AGViewDidAppear(id self, SEL _cmd, BOOL animated) {
    AGOrigViewDidAppear(self, _cmd, animated);
    if ([self isKindOfClass:[UIViewController class]]) AGInstallEntry((UIViewController *)self);
}

// 双指长按：窗口级兜底入口。不依赖 Swift 侧是否调用了 super，构造期就挂上。
static void AGAttachWindowGesture(void) {
    UIWindow *key = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w.isKeyWindow) { key = w; break; }
    }
    if (!key && UIApplication.sharedApplication.windows.count)
        key = UIApplication.sharedApplication.windows.firstObject;
    if (!key || objc_getAssociatedObject(key, kAGGestureKey)) return;

    objc_setAssociatedObject(key, kAGGestureKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:[AGRenamEntry shared]
                                                      action:@selector(handleLongPress:)];
    lp.numberOfTouchesRequired = 2;
    lp.minimumPressDuration = 0.8;
    lp.cancelsTouchesInView = NO;
    [key addGestureRecognizer:lp];
    NSLog(@"[AemuloRename] window gesture attached");
}

__attribute__((constructor))
static void AGInit(void) {
    NSLog(@"[AemuloRename] loaded · %@ · substrate-free", kAGVer);
    AGSwizzleTextSetters();

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) { AGAttachWindowGesture(); }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) { AGAttachWindowGesture(); }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) {
        // 从后台回来时库可能被 Aemulo 改过（比如新拷了卡），重建映射
        AGRebuildNameMap();
    }];

    Method m1 = class_getInstanceMethod([UIViewController class], @selector(viewDidLoad));
    if (m1) {
        AGOrigViewDidLoad = (void *)method_getImplementation(m1);
        method_setImplementation(m1, (IMP)AGViewDidLoad);
    }
    Method m2 = class_getInstanceMethod([UIViewController class], @selector(viewDidAppear:));
    if (m2) {
        AGOrigViewDidAppear = (void *)method_getImplementation(m2);
        method_setImplementation(m2, (IMP)AGViewDidAppear);
    }

    // 主页 cell 布局完再扫一遍 UID → 名字，兜住"先设文本后加 cell"的情况
    Method m3 = class_getInstanceMethod([UITableViewCell class], @selector(layoutSubviews));
    if (m3) {
        AGOrigCellLayout = (void *)method_getImplementation(m3);
        method_setImplementation(m3, (IMP)AGCellLayout);
    }
}
