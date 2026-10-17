#import "JevFloaty.h"
#import <Vision/Vision.h>

// ============================================================
// Jev 悬浮球（tweak 内自绘 UI，不依赖宿主 App 的任何内部结构）
// ============================================================

#pragma mark - 常量

static NSString *const kJevGroupID  = @"group.com.jevchat.jarvis";
static NSString *const kJevConfigKey = @"jev.config.v1";
static CGFloat const kBubbleSize = 46.0;
static CGFloat const kPanelWidth = 344.0;
static CGFloat const kPanelHeight = 348.0;

static UIColor *jevBrandColor(void) {
    // Jev 品牌青绿 #00C1D4
    return [UIColor colorWithRed:0.0 green:0xC1/255.0 blue:0xD4/255.0 alpha:1.0];
}

#pragma mark - 内置话术（与 Shared/JevPrompts.swift BUILTIN_TONES 逐字一致，中文）

static NSDictionary *jev_builtinTones(void) {
    return @{
        @"高情商话术": @"像公司里那个谁都说好的老同事：先接住对方情绪（「我理解」「确实」），再说事实和下一步，拒绝也带替代方案加一个具体时间点。不说教、不绕圈子、句尾不堆「呢/哦/啦」。",
        @"贴吧老哥 v1.0": @"贴吧老哥：一口网感口语，「有一说一」「绷不住了」「搁这」「这就去整」随手就来，自称我、管对方叫「哥/兄弟」，可以自嘲玩梗甚至摆烂，但不骂人。禁止「您好」「感谢」这类书面客套。",
        @"拒绝加班": @"态度平和但把话说死：明确今天做不完，**不给**「我尽量」「看情况」这种会被继续压的口子；必须给一个具体替代时间（比如「明早九点前」），并说清不用等今晚。道歉不超过一句，理由不超过一句。",
        @"卑微乙方": @"极度卑微的乙方：「好的好的」「收到收到」「实在抱歉」「麻烦您了」张口就来，全程称「您」，任何问题先认在自己头上，随叫随到。夸张到一眼看出是梗，但整句仍然能直接发出去。",
        @"稳如老狗": @"十年老工程师那种稳：不解释、不铺垫、不道歉，只给结论加一个时间点，句子短、主语是事不是情绪（「三点前给你」「已确认，没问题」），让对方觉得事情已经稳了。",
        @"已读乱回": @"敷衍但不失礼：一到六个字把对方接住（「在忙，你说」「嗯嗯」「好」），不承诺、不展开、不给时间点，让对方觉得回了又没法接着追问。",
        @"鱼塘主": @"海王海后式的推拉。每条回复里都要有一推一拉：先用一句淡淡的调侃把距离拉开，紧接着给一点真心的甜头，让人想再追问一句；对方提要求时先接住、再讲条件，事情不说死，收尾留个悬念。惜字如金，不解释、不道歉、不讨好，不揽活不背锅，嘴甜心硬。推是让对方多想一步，不是把人推开：不冷嘲热讽、不居高临下、不连环追问；对方好好说话时就别用推拉。不油腻、不露骨，整句要能直接发出去。不要照抄这段话里的任何措辞。",
        @"职场黑话": @"把简单的事说得很专业：对齐、抓手、闭环、颗粒度、拉通、复盘、赋能、沉淀、打法轮着用，一句话里至少两个；但整句要能看懂，不要堆到不知所云。",
        @"阴阳怪气": @"表面客气、话里带刺：多用「哦」「呢」「那就」「辛苦你了」配反问或夸张的客气，让对方不好发作又不能说你没礼貌。不要升级成直接骂人或人身攻击。",
        @"情绪价值": @"情绪价值为先。认同的是对方的感受和处境（累、委屈、烦），不是对方话里的结论——绝不顺着别人对 ta 的否定说话（「你妈说得对」这种最伤人）；对方和别人有冲突时站到对方这边，不评判谁对谁错。对方没问「怎么办」就别急着给方案、别总结、别讲道理，也绝不说「别想太多」「这没什么」「想开点」。认同要具体（点出对方做的哪一点），但不空泛吹捧、不说教、不写小作文；不知道关系就别加「宝贝」「亲爱的」，也不堆 emoji。整句要能直接发出去，不要照抄这段话里的任何措辞。",
        @"夸夸": @"像夸夸群里的金牌群友：夸人夸具体——抓住对方消息里的细节往高了夸（眼光、效率、品位都行），语气真诚热络，「绝了」「这也太强了」「服了」随手就来，可以带感叹号；夸完顺势把正事接住（该答应的答应、该给时间的给时间）。不空泛、不谄媚、不连用三个感叹号，别把夸说成阴阳怪气。",
        @"讨好型人格": @"把对方的心情放在自己前面：先问清需求再表态顺从（「都听你的」「你说怎样就怎样」），习惯性先自贬一句（「是我笨」「我反应慢」），末尾爱追一句「这样行吗」「你没生气吧」。答应得比能做到的快，宁可自己加班也不想让对方失望。语气软、句尾带语气词，但不卖惨、不写小作文、不真把自己说成一无是处，整句仍然要能直接发出去。",
        @"狗头军师": @"恋爱军师的口吻：先接住对方的情绪（看见感受，别急着讲道理），再看清关系局面，给一句真诚、有分寸、能直接发出去的话。温暖、清醒、站在自己这边，不油腻、不套路、不评判、不读心；对方含糊试探时给一步稳的推进，明确拒绝就体面收住，永远留住双方的尊严和自己的选择权。不写小作文、不堆辞藻，每条只推进一件事，不要照抄这段话里的任何措辞。",
    };
}

#pragma mark - 配置读取（与 JevStore 同键：App Group UserDefaults 里的 JSON）

static NSDictionary *jev_loadConfig(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kJevGroupID];
    NSData *data = [d dataForKey:kJevConfigKey];
    if (!data) return @{};
    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    return [obj isKindOfClass:NSDictionary.class] ? obj : @{};
}

/// 激活话术：配置 slots（去掉空串，最多 2 个）→ 内置/自定义合并取说明
static NSArray<NSString *> *jev_activeTones(NSDictionary *cfg) {
    NSMutableArray *names = [NSMutableArray array];
    NSArray *slots = cfg[@"slots"];
    if (![slots isKindOfClass:NSArray.class]) slots = @[@"高情商话术", @"稳如老狗"];
    for (id s in slots) {
        if (![s isKindOfClass:NSString.class]) continue;
        NSString *name = (NSString *)s;
        if (name.length == 0 || [name isEqualToString:@"不用"]) continue;
        [names addObject:name];
        if (names.count >= 2) break;
    }
    if (names.count == 0) names = [@[@"高情商话术", @"稳如老狗"] mutableCopy];
    return names;
}

static NSString *jev_toneInstruction(NSDictionary *cfg, NSString *name) {
    NSDictionary *custom = cfg[@"customTones"];
    if ([custom isKindOfClass:NSDictionary.class]) {
        NSString *v = custom[name];
        if ([v isKindOfClass:NSString.class] && v.length > 0) return v;
    }
    NSString *v = jev_builtinTones()[name];
    return v.length ? v : @"自然、得体地回一条，能直接发出去。";
}

/// OpenAI 兼容端点：base 带不带 /chat/completions、/v1、/v4 都能拼对
static NSString *jev_chatURL(NSString *rawBase) {
    NSString *b = [rawBase stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([b hasSuffix:@"/"]) b = [b substringToIndex:b.length - 1];
    NSArray *segs = [b componentsSeparatedByString:@"/"];
    NSString *last = [segs.lastObject lowercaseString];
    if ([last isEqualToString:@"completions"]) return b;
    return [b stringByAppendingString:@"/chat/completions"];
}

#pragma mark - 候选清洗（移植自 CandidateParser：编号 → 引号 → 风格前缀）

static NSString *jev_trim(NSString *s) {
    return [s stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *jev_stripRegex(NSString *s, NSString *pattern) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                        options:0 error:nil];
    if (!re) return s;
    NSRange m = [re rangeOfFirstMatchInString:s options:0
                                        range:NSMakeRange(0, s.length)];
    if (m.location != NSNotFound && m.length > 0 && m.location + m.length <= s.length) {
        return [s substringFromIndex:m.location + m.length];
    }
    return s;
}

static NSArray<NSString *> *jev_parseCandidates(NSString *raw, NSInteger limit) {
    NSMutableArray *out = [NSMutableArray array];
    NSCharacterSet *quotes = [NSCharacterSet characterSetWithCharactersInString:
                              @"\"'“”‘’「」『』"];
    NSArray *lines = [raw componentsSeparatedByCharactersInSet:
                      [NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        NSString *s = jev_trim(line);
        if (s.length == 0) continue;
        s = jev_stripRegex(s, @"^\\d+[.、)．]\\s*");
        if (s.length >= 2) {
            unichar first = [s characterAtIndex:0];
            unichar last = [s characterAtIndex:s.length - 1];
            if ([quotes characterIsMember:first] && [quotes characterIsMember:last]) {
                s = [s substringWithRange:NSMakeRange(1, s.length - 2)];
            }
        }
        s = jev_stripRegex(s, @"^[*_#\\s]*(稳妥|轻松|简短|简洁)[^，。！？；、,.!?;：:]{0,5}[*_#\\s]*[:：]\\s*");
        s = jev_stripRegex(s, @"^(简|稳|轻)\\s*(型|洁)?[*_#\\s]*[:：]\\s*");
        s = jev_trim(s);
        if (s.length > 0 && ![out containsObject:s]) {
            [out addObject:s];
            if (out.count >= limit) break;
        }
    }
    return out;
}

#pragma mark - 屏幕 OCR（与键盘版同一套规则：滤顶部导航/底部输入栏，从底部取 ≤14 行）

void jev_ocrScreenText(void (^completion)(NSString *text)) {
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            // 主窗口 = 正常层级（windowLevel==0）的窗口；我们自己的悬浮球是更高层级，不会被截进去
            UIWindow *window = nil;
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:UIWindowScene.class]) continue;
                UIWindowScene *ws = (UIWindowScene *)scene;
                for (UIWindow *w in ws.windows) {
                    if (w.windowLevel == 0) { window = w; break; }
                }
                if (window) break;
            }
            if (!window || window.bounds.size.width < 10 || window.bounds.size.height < 10) {
                completion(@""); return;
            }
            UIGraphicsImageRenderer *renderer =
                [[UIGraphicsImageRenderer alloc] initWithSize:window.bounds.size];
            UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
            }];
            if (!image) { completion(@""); return; }

            VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] init];
            req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
            req.recognitionLanguages = @[@"zh-Hans", @"zh-Hant", @"en-US"];
            req.usesLanguageCorrection = YES;
            VNImageRequestHandler *handler =
                [[VNImageRequestHandler alloc] initWithCGImage:image.CGImage options:@{}];
            NSError *error = nil;
            [handler performRequests:@[req] error:&error];
            if (error || req.results.count == 0) { completion(@""); return; }

            // Vision 坐标原点在左下、归一化 0-1：滤顶部导航（cy>0.90）与底部输入栏（cy<0.08）
            NSMutableArray *items = [NSMutableArray array];
            for (VNRecognizedTextObservation *obs in req.results) {
                VNRecognizedText *top = [[obs topCandidates:1] firstObject];
                if (!top) continue;
                CGFloat cy = obs.boundingBox.origin.y + obs.boundingBox.size.height * 0.5;
                if (cy < 0.08 || cy > 0.90) continue;
                [items addObject:@{@"cy": @(cy), @"text": top.string}];
            }
            [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                CGFloat ya = [a[@"cy"] doubleValue], yb = [b[@"cy"] doubleValue];
                if (ya > yb) return NSOrderedAscending;
                if (ya < yb) return NSOrderedDescending;
                return NSOrderedSame;
            }];
            NSMutableArray *lines = [NSMutableArray array];
            for (NSDictionary *it in items) {
                [lines addObject:it[@"text"]];
                if (lines.count >= 14) break;
            }
            completion([lines componentsJoinedByString:@"\n"]);
        });
    });
}

#pragma mark - 悬浮球

@interface JevFloaty ()
@property (nonatomic, strong) UIWindow *bubbleWindow;
@property (nonatomic, strong) UIWindow *panelWindow;
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UIButton *bubble;
@property (nonatomic, assign) CGFloat keyboardTop;     // 屏幕坐标，键盘顶部
@property (nonatomic, assign) BOOL panelOpen;
@property (nonatomic, strong) NSDictionary *config;    // 面板每次打开重读
@property (nonatomic, strong) NSArray<NSString *> *toneNames;
@property (nonatomic, strong) NSString *selectedTone;
@property (nonatomic, strong) UIScrollView *toneScroll;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIScrollView *candidateScroll;
@property (nonatomic, strong) UIStackView *candidateStack;
@property (nonatomic, weak) id kbShowObs;
@property (nonatomic, weak) id kbHideObs;
@end

@implementation JevFloaty

+ (instancetype)shared {
    static JevFloaty *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[JevFloaty alloc] init]; });
    return instance;
}

- (void)start {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    __weak typeof(self) weakSelf = self;
    if (!self.kbShowObs) {
        self.kbShowObs = [nc addObserverForName:UIKeyboardWillShowNotification object:nil
                                          queue:[NSOperationQueue mainQueue]
                                     usingBlock:^(NSNotification *note) {
            [weakSelf keyboardWillShow:note];
        }];
    }
    if (!self.kbHideObs) {
        self.kbHideObs = [nc addObserverForName:UIKeyboardWillHideNotification object:nil
                                          queue:[NSOperationQueue mainQueue]
                                     usingBlock:^(NSNotification *note) {
            [weakSelf keyboardWillHide];
        }];
    }
}

#pragma mark 窗口与场景

- (UIWindowScene *)mainScene {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)scene;
    }
    return nil;
}

/// 主窗口：正常层级（不含我们自己的悬浮窗）
- (UIWindow *)mainWindow {
    UIWindowScene *scene = [self mainScene];
    for (UIWindow *w in scene.windows) {
        if (w.windowLevel == 0 && w.bounds.size.width > 10) return w;
    }
    return scene.windows.firstObject;
}

#pragma mark 键盘事件

- (void)keyboardWillShow:(NSNotification *)note {
    CGRect kb = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    if (kb.size.height < 50) return;
    self.keyboardTop = CGRectGetMinY(kb);
    [self showBubble];
    if (self.panelOpen) [self placePanel];
}

- (void)keyboardWillHide {
    self.panelOpen = NO;
    self.bubbleWindow.hidden = YES;
    self.panelWindow.hidden = YES;
}

#pragma mark 悬浮球

- (void)showBubble {
    if (!self.bubbleWindow) {
        UIWindow *w = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        w.windowScene = [self mainScene];
        w.windowLevel = UIWindowLevelStatusBar + 1;   // 盖 App 内容，不盖键盘
        w.backgroundColor = [UIColor clearColor];
        w.userInteractionEnabled = YES;

        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(0, 0, kBubbleSize, kBubbleSize);
        b.layer.cornerRadius = kBubbleSize / 2;
        b.backgroundColor = [jevBrandColor() colorWithAlphaComponent:0.94];
        b.tintColor = [UIColor whiteColor];
        [b setImage:[UIImage systemImageNamed:@"sparkles"] forState:UIControlStateNormal];
        b.layer.shadowColor = [UIColor blackColor].CGColor;
        b.layer.shadowOpacity = 0.25;
        b.layer.shadowRadius = 6;
        b.layer.shadowOffset = CGSizeMake(0, 2);
        b.accessibilityLabel = @"Jev AI";
        [b addTarget:self action:@selector(bubbleTapped) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                       initWithTarget:self action:@selector(bubblePanned:)];
        [b addGestureRecognizer:pan];
        [w addSubview:b];
        self.bubble = b;
        self.bubbleWindow = w;
    }
    CGFloat x = UIScreen.mainScreen.bounds.size.width - kBubbleSize / 2 - 8;
    CGFloat y = self.keyboardTop - kBubbleSize / 2 - 10;
    self.bubble.center = CGPointMake(x, y);
    self.bubbleWindow.hidden = NO;
}

- (void)bubblePanned:(UIPanGestureRecognizer *)g {
    UIView *b = self.bubble;
    CGPoint p = [g translationInView:b.superview];
    b.center = CGPointMake(b.center.x + p.x, b.center.y + p.y);
    [g setTranslation:CGPointZero inView:b.superview];
    if (g.state == UIGestureRecognizerStateEnded) {
        CGRect scr = UIScreen.mainScreen.bounds;
        CGFloat x = (b.center.x < scr.size.width / 2) ? kBubbleSize / 2 + 8
                                                      : scr.size.width - kBubbleSize / 2 - 8;
        CGFloat minY = 90;
        CGFloat maxY = self.keyboardTop - kBubbleSize / 2 - 8;
        CGFloat y = MIN(MAX(b.center.y, minY), MAX(minY, maxY));
        [UIView animateWithDuration:0.2 animations:^{
            b.center = CGPointMake(x, y);
        }];
    }
}

- (void)bubbleTapped {
    self.panelOpen ? [self closePanel] : [self openPanel];
}

#pragma mark 面板

- (void)openPanel {
    self.config = jev_loadConfig();
    self.toneNames = jev_activeTones(self.config);
    self.selectedTone = self.toneNames.firstObject;
    self.panelOpen = YES;
    [self buildPanelIfNeeded];
    [self placePanel];
    [self refreshToneChips];
    [self setStatus:@"点「生成回复」自动读聊天内容出候选；或「粘贴剪贴板」" color:nil];
    [self clearCandidates];
    self.panelWindow.hidden = NO;
}

- (void)closePanel {
    self.panelOpen = NO;
    self.panelWindow.hidden = YES;
}

- (void)placePanel {
    CGRect scr = UIScreen.mainScreen.bounds;
    CGFloat x = (scr.size.width - kPanelWidth) / 2;
    CGFloat y = self.keyboardTop - kPanelHeight - 8;
    if (y < 40) y = 40;
    self.cardView.frame = CGRectMake(x, y, kPanelWidth, kPanelHeight);
}

- (void)buildPanelIfNeeded {
    if (self.panelWindow) return;

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kPanelWidth, kPanelHeight)];
    card.backgroundColor = [UIColor secondarySystemBackgroundColor];
    card.layer.cornerRadius = 16;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.3;
    card.layer.shadowRadius = 12;
    card.layer.shadowOffset = CGSizeMake(0, 4);

    // 头部
    UILabel *title = [[UILabel alloc] init];
    title.text = @"Jev AI";
    title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    title.textColor = [UIColor labelColor];
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [closeBtn setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
    closeBtn.tintColor = [UIColor secondaryLabelColor];
    [closeBtn addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:
                           @[title, [[UIView alloc] init], closeBtn]];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;

    // 话术 chips
    UIScrollView *toneScroll = [[UIScrollView alloc] init];
    toneScroll.showsHorizontalScrollIndicator = NO;
    toneScroll.delaysContentTouches = NO;
    UIStackView *toneStack = [[UIStackView alloc] init];
    toneStack.axis = UILayoutConstraintAxisHorizontal;
    toneStack.spacing = 6;
    [toneScroll addSubview:toneStack];
    toneStack.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [toneStack.topAnchor constraintEqualToAnchor:toneScroll.contentLayoutGuide.topAnchor],
        [toneStack.bottomAnchor constraintEqualToAnchor:toneScroll.contentLayoutGuide.bottomAnchor],
        [toneStack.leadingAnchor constraintEqualToAnchor:toneScroll.contentLayoutGuide.leadingAnchor],
        [toneStack.trailingAnchor constraintEqualToAnchor:toneScroll.contentLayoutGuide.trailingAnchor],
        [toneStack.heightAnchor constraintEqualToAnchor:toneScroll.heightAnchor],
    ]];
    self.toneScroll = toneScroll;

    // 动作按钮
    UIButton *pasteBtn = [self actionButton:@"粘贴剪贴板" icon:@"doc.on.clipboard" primary:NO
                                     action:@selector(pasteClipboard)];
    UIButton *genBtn = [self actionButton:@"生成回复" icon:@"sparkles" primary:YES
                                   action:@selector(generateReply)];
    UIStackView *btnRow = [[UIStackView alloc] initWithArrangedSubviews:@[pasteBtn, genBtn]];
    btnRow.axis = UILayoutConstraintAxisHorizontal;
    btnRow.spacing = 8;
    btnRow.distribution = UIStackViewDistributionFillEqually;

    // 状态
    UILabel *status = [[UILabel alloc] init];
    status.font = [UIFont systemFontOfSize:12];
    status.textColor = [UIColor secondaryLabelColor];
    status.numberOfLines = 2;
    self.statusLabel = status;

    // 候选
    UIScrollView *candScroll = [[UIScrollView alloc] init];
    candScroll.showsVerticalScrollIndicator = NO;
    candScroll.delaysContentTouches = NO;
    UIStackView *candStack = [[UIStackView alloc] init];
    candStack.axis = UILayoutConstraintAxisVertical;
    candStack.spacing = 6;
    [candScroll addSubview:candStack];
    candStack.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [candStack.topAnchor constraintEqualToAnchor:candScroll.contentLayoutGuide.topAnchor],
        [candStack.bottomAnchor constraintEqualToAnchor:candScroll.contentLayoutGuide.bottomAnchor],
        [candStack.leadingAnchor constraintEqualToAnchor:candScroll.contentLayoutGuide.leadingAnchor],
        [candStack.trailingAnchor constraintEqualToAnchor:candScroll.contentLayoutGuide.trailingAnchor],
        [candStack.widthAnchor constraintEqualToAnchor:candScroll.widthAnchor],
    ]];
    self.candidateScroll = candScroll;
    self.candidateStack = candStack;

    UIStackView *vstack = [[UIStackView alloc] initWithArrangedSubviews:
                           @[header, toneScroll, btnRow, status, candScroll]];
    vstack.axis = UILayoutConstraintAxisVertical;
    vstack.spacing = 8;
    vstack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:vstack];
    [NSLayoutConstraint activateConstraints:@[
        [vstack.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [vstack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [vstack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [vstack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
        [toneScroll.heightAnchor constraintEqualToConstant:34],
        [btnRow.heightAnchor constraintEqualToConstant:40],
        [status.heightAnchor constraintEqualToConstant:34],
    ]];

    UIWindow *pw = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    pw.windowScene = [self mainScene];
    pw.windowLevel = UIWindowLevelStatusBar + 1;
    pw.backgroundColor = [UIColor clearColor];
    pw.userInteractionEnabled = YES;
    [pw addSubview:card];
    self.cardView = card;
    self.panelWindow = pw;
}

/// configuration 模式下字体要走 titleTextAttributesTransformer（直接改 titleLabel.font 会被覆盖）
- (void)applyFont:(UIFont *)font toButton:(UIButton *)button {
    button.configuration.titleTextAttributesTransformer =
        ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *attrs) {
            NSMutableDictionary *m = [attrs mutableCopy] ?: [NSMutableDictionary dictionary];
            m[NSFontAttributeName] = font;
            return m;
        };
}

- (UIButton *)actionButton:(NSString *)title icon:(NSString *)icon primary:(BOOL)primary
                    action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.configuration = [UIButtonConfiguration filledButtonConfiguration];
    b.configuration.title = title;
    b.configuration.image = [UIImage systemImageNamed:icon];
    b.configuration.imagePadding = 4;
    b.configuration.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    b.configuration.baseForegroundColor = primary ? [UIColor whiteColor] : [UIColor labelColor];
    b.configuration.baseBackgroundColor = primary ? jevBrandColor() : [UIColor tertiarySystemFillColor];
    [self applyFont:[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold] toButton:b];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

#pragma mark 话术 chips

- (void)refreshToneChips {
    for (UIView *v in self.toneScroll.subviews) {
        if (![v isKindOfClass:UIStackView.class]) continue;
        UIStackView *stack = (UIStackView *)v;
        for (UIView *sub in stack.arrangedSubviews) [sub removeFromSuperview];
        for (NSString *name in self.toneNames) {
            UIButton *chip = [UIButton buttonWithType:UIButtonTypeSystem];
            chip.configuration = [UIButtonConfiguration filledButtonConfiguration];
            chip.configuration.title = name;
            chip.configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
            [self applyFont:[UIFont systemFontOfSize:12 weight:UIFontWeightMedium] toButton:chip];
            chip.configuration.baseForegroundColor = [UIColor labelColor];
            chip.configuration.baseBackgroundColor = [UIColor tertiarySystemFillColor];
            chip.accessibilityIdentifier = name;
            [chip addTarget:self action:@selector(toneChipTapped:) forControlEvents:UIControlEventTouchUpInside];
            [stack addArrangedSubview:chip];
        }
        [self updateChipHighlights];
    }
}

- (void)toneChipTapped:(UIButton *)sender {
    self.selectedTone = sender.accessibilityIdentifier;
    [self updateChipHighlights];
}

- (void)updateChipHighlights {
    for (UIView *v in self.toneScroll.subviews) {
        if (![v isKindOfClass:UIStackView.class]) continue;
        for (UIView *sub in [(UIStackView *)v arrangedSubviews]) {
            UIButton *chip = (UIButton *)sub;
            BOOL sel = [chip.accessibilityIdentifier isEqualToString:self.selectedTone];
            chip.configuration.baseForegroundColor = sel ? [UIColor whiteColor] : [UIColor labelColor];
            chip.configuration.baseBackgroundColor = sel ? jevBrandColor() : [UIColor tertiarySystemFillColor];
        }
    }
}

#pragma mark 动作

- (void)setStatus:(NSString *)text color:(UIColor *)color {
    self.statusLabel.text = text;
    self.statusLabel.textColor = color ?: [UIColor secondaryLabelColor];
}

- (void)clearCandidates {
    for (UIView *v in self.candidateStack.arrangedSubviews) [v removeFromSuperview];
}

/// 当前输入框：遍历主窗口找第一响应者（UITextView / UITextField）
- (UIView *)currentInputField {
    UIWindow *w = [self mainWindow];
    if (!w) return nil;
    __block UIView *found = nil;
    void (^walk)(UIView *) = ^(UIView *v) {
        if (found) return;
        if (v.isFirstResponder) { found = v; return; }
        for (UIView *s in v.subviews) walk(s);
    };
    walk(w);
    return found;
}

- (BOOL)insertText:(NSString *)text {
    UIView *f = [self currentInputField];
    if ([f isKindOfClass:UITextView.class]) {
        [(UITextView *)f insertText:text];
        return YES;
    }
    if ([f isKindOfClass:UITextField.class]) {
        [(UITextField *)f insertText:text];
        return YES;
    }
    return NO;
}

- (void)pasteClipboard {
    NSString *s = UIPasteboard.generalPasteboard.string;
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length == 0) {
        [self setStatus:@"剪贴板是空的：先长按复制一条消息再试" color:[UIColor systemOrangeColor]];
        return;
    }
    if ([self insertText:s]) {
        [self setStatus:@"已粘贴到输入框 ✓（首次会问一次「允许粘贴」，允许后不再提示）"
                  color:[UIColor systemGreenColor]];
    } else {
        [self setStatus:@"没找到输入框：先点一下输入框再试" color:[UIColor systemOrangeColor]];
    }
}

- (void)generateReply {
    NSDictionary *cfg = self.config;
    NSString *key = cfg[@"genKey"];
    NSString *base = cfg[@"genBase"];
    NSString *model = cfg[@"genModel"];
    if (![key isKindOfClass:NSString.class] || key.length == 0 ||
        ![base isKindOfClass:NSString.class] || base.length == 0 ||
        ![model isKindOfClass:NSString.class] || model.length == 0) {
        [self setStatus:@"还没配置生成层：打开 Jev Jarvis App →「模型」页填 API Key"
                  color:[UIColor systemOrangeColor]];
        return;
    }
    [self clearCandidates];
    [self setStatus:@"读取聊天内容…" color:nil];
    __weak typeof(self) weakSelf = self;
    jev_ocrScreenText(^(NSString *chatText) {
        __strong typeof(self) self = weakSelf;
        if (!self) return;
        if (chatText.length == 0) {
            [self setStatus:@"没读到聊天内容：请先进入聊天界面（打开输入框）再点生成"
                      color:[UIColor systemOrangeColor]];
            return;
        }
        [self generateWithMessage:chatText cfg:cfg];
    });
}

/// 并发请求每个激活话术，各取 2 条候选
- (void)generateWithMessage:(NSString *)message cfg:(NSDictionary *)cfg {
    NSString *key = cfg[@"genKey"];
    NSString *base = cfg[@"genBase"];
    NSString *model = cfg[@"genModel"];
    NSString *extra = cfg[@"genExtraJSON"];

    __weak typeof(self) weakSelf = self;
    [self setStatus:@"生成中…" color:nil];
    NSMutableArray *results = [NSMutableArray array];   // @[@{tone, texts}]
    dispatch_group_t group = dispatch_group_create();
    NSLock *lock = [[NSLock alloc] init];

    for (NSString *tone in self.toneNames) {
        dispatch_group_enter(group);
        NSString *instruction = jev_toneInstruction(cfg, tone);
        NSString *prompt = [NSString stringWithFormat:
            @"刚收到一条聊天消息，你要帮我回。\n\n消息：「%@」\n\n请写 2 条回复候选，语气统一成下面这一种，但两条的胆量要有差别：\n「%@」%@\n\n硬性要求：\n- 前一条稳妥、可以直接发出去；后一条把这个语气做足，更皮、更夸张一点也行\n- 每条不超过 30 个字，像日常聊天时打字的语气，不要客套话、不要解释\n- 只输出 2 行，每行一条，不要编号、不要引号、不要任何前后缀\n- 不要写出语气名称（不要写「%@：」这类前缀），直接从回复内容开始",
            message, tone, instruction, tone];

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [self chatCompletionPrompt:prompt base:base key:key model:model extra:extra
                            completion:^(NSString *raw, NSString *err) {
                [lock lock];
                if (err) {
                    [results addObject:@{@"tone": tone, @"err": err}];
                } else {
                    [results addObject:@{@"tone": tone, @"texts": jev_parseCandidates(raw, 2)}];
                }
                [lock unlock];
                dispatch_group_leave(group);
            }];
        });
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(40 * NSEC_PER_SEC)));
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) self = weakSelf;
            if (!self) return;
            NSMutableArray *cands = [NSMutableArray array];
            NSMutableArray *errs = [NSMutableArray array];
            // 按话术槽顺序展示；同话术内保留模型顺序（前稳后放）
            for (NSString *tone in self.toneNames) {
                for (NSDictionary *r in results) {
                    if (![r[@"tone"] isEqualToString:tone]) continue;
                    if (r[@"err"]) { [errs addObject:r[@"err"]]; continue; }
                    [cands addObjectsFromArray:r[@"texts"]];
                }
            }
            if (cands.count == 0) {
                NSString *msg = errs.count ? [NSString stringWithFormat:@"生成失败：%@", errs.firstObject]
                                           : @"生成失败：请到 App「模型」页点「测试连接」检查配置";
                [self setStatus:msg color:[UIColor systemRedColor]];
                return;
            }
            [self showCandidates:cands];
            NSString *note = errs.count ? [NSString stringWithFormat:@"已出 %ld 条；%ld 个话术失败",
                                           (long)cands.count, (long)errs.count] : @"";
            [self setStatus:[NSString stringWithFormat:@"点候选直接进输入框，然后手动发送%@", note]
                      color:errs.count ? [UIColor systemOrangeColor] : [UIColor systemGreenColor]];
        });
    });
}

/// OpenAI 兼容 chat/completions 一次调用
- (void)chatCompletionPrompt:(NSString *)prompt base:(NSString *)base key:(NSString *)key
                       model:(NSString *)model extra:(NSString *)extra
                  completion:(void (^)(NSString *raw, NSString *err))completion {
    NSURL *url = [NSURL URLWithString:jev_chatURL(base)];
    if (!url) { completion(nil, @"服务地址不对"); return; }
    NSMutableDictionary *body = [@{
        @"model": model,
        @"messages": @[@{@"role": @"user", @"content": prompt}],
        @"max_tokens": @400,
        @"temperature": @0.9,
        @"stream": @NO,
    } mutableCopy];
    extra = [extra stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (extra.length > 0) {
        NSData *d = [extra dataUsingEncoding:NSUTF8StringEncoding];
        id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if ([obj isKindOfClass:NSDictionary.class]) {
            for (NSString *k in obj) body[k] = obj[k];
        }
    }
    NSMutableURLRequest *req = [[NSMutableURLRequest alloc] initWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", key] forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    req.timeoutInterval = 35;

    [[NSURLSession sharedSession] dataTaskWithRequest:req
                                    completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) { completion(nil, err.localizedDescription); return; }
        NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
        if (code < 200 || code >= 300) {
            NSString *detail = @"";
            if (data) {
                id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([obj isKindOfClass:NSDictionary.class]) {
                    id e = obj[@"error"];
                    if ([e isKindOfClass:NSDictionary.class]) detail = [NSString stringWithFormat:@"：%@", e[@"message"]];
                }
            }
            completion(nil, [NSString stringWithFormat:@"HTTP %ld%@", (long)code, detail]);
            return;
        }
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![obj isKindOfClass:NSDictionary.class]) { completion(nil, @"响应格式不对"); return; }
        NSArray *choices = obj[@"choices"];
        NSDictionary *msg = [choices isKindOfClass:NSArray.class] && choices.count > 0
            ? choices.firstObject[@"message"] : nil;
        NSString *text = [msg isKindOfClass:NSDictionary.class] ? msg[@"content"] : nil;
        if ([text isKindOfClass:NSString.class] && text.length > 0) {
            completion(text, nil);
        } else {
            completion(nil, @"模型只回了思考没出正文：请换非思考模型（如 deepseek-chat / glm-4-flash）");
        }
    }] resume;
}

- (void)showCandidates:(NSArray<NSString *> *)cands {
    for (UIView *v in self.candidateStack.arrangedSubviews) [v removeFromSuperview];
    __weak typeof(self) weakSelf = self;
    for (NSString *text in cands) {
        // 候选可能超一行，用普通按钮（configuration 不支持多行标题）
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.backgroundColor = [UIColor tertiarySystemFillColor];
        b.layer.cornerRadius = 10;
        [b setTitle:text forState:UIControlStateNormal];
        [b setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:14];
        b.titleLabel.numberOfLines = 0;
        b.titleLabel.textAlignment = NSTextAlignmentLeft;
        b.contentEdgeInsets = UIEdgeInsetsMake(6, 10, 6, 10);
        [b addTarget:weakSelf action:@selector(candidateTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.candidateStack addArrangedSubview:b];
    }
}

- (void)candidateTapped:(UIButton *)sender {
    NSString *text = [sender titleForState:UIControlStateNormal];
    if (text.length == 0) return;
    if ([self insertText:text]) {
        [self setStatus:@"已插入输入框 ✓（点发送发出）" color:[UIColor systemGreenColor]];
    } else {
        [self setStatus:@"没找到输入框：先点一下输入框再点候选" color:[UIColor systemOrangeColor]];
    }
}

@end
