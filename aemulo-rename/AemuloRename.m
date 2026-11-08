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
static NSString *const kAGVer = @"AG_VER_V2";

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
    return @"点一行改名，左滑删除，右上角导出库。改动立即写入数据库；Aemulo 列表若没刷新，重启 App 生效。";
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

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) { AGAttachWindowGesture(); }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) { AGAttachWindowGesture(); }];

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
}
