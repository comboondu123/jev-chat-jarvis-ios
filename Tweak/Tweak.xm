#import <UIKit/UIKit.h>
#import <Vision/Vision.h>
#import <notify.h>

// Jev ScreenReader：屏幕 OCR → 剪贴板
//
// 注入目标：微信（com.tencent.xin）/ Soul（com.soulglobal.cn），见 layout 里的 filter plist。
// 工作方式：
//   1. Jev 键盘出现时 post Darwin notify：com.jevchat.ask-scan
//   2. 本插件（在聊天 App 进程内）收到通知 → 截取当前窗口 → Vision OCR（中文优先）
//   3. 按视觉位置取聊天区文本（去掉顶部导航/底部输入区），写进剪贴板
//   4. Jev 键盘 3 秒后拾取剪贴板自动分析
// 不依赖微信/Soul 内部结构，界面怎么改都不影响——OCR 的是屏幕本身。

static void performScan(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 给界面一点稳定时间，避免截到键盘切换动画中的半帧
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIWindow *window = [UIApplication sharedApplication].windows.firstObject;
            if (!window || window.bounds.size.width < 10 || window.bounds.size.height < 10) return;

            UIGraphicsImageRenderer *renderer =
                [[UIGraphicsImageRenderer alloc] initWithSize:window.bounds.size];
            UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
            }];
            if (!image) return;

            VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] init];
            req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
            req.recognitionLanguages = @[@"zh-Hans", @"zh-Hant", @"en-US"];
            req.usesLanguageCorrection = YES;

            VNImageRequestHandler *handler =
                [[VNImageRequestHandler alloc] initWithCGImage:image.CGImage options:@{}];
            NSError *error = nil;
            [handler performRequests:@[req] error:&error];
            if (error || req.results.count == 0) return;

            // Vision 坐标：原点在左下、归一化 0-1。cy 越大越靠上。
            // 聊天记录在中间区域：滤掉顶部导航（cy>0.90）与底部输入栏（cy<0.08）。
            NSMutableArray *items = [NSMutableArray array];
            for (VNRecognizedTextObservation *obs in req.results) {
                VNRecognizedText *top = obs.topCandidates.firstObject;
                if (!top) continue;
                CGFloat cy = obs.boundingBox.origin.y + obs.boundingBox.size.height * 0.5;
                if (cy < 0.08 || cy > 0.90) continue;
                [items addObject:@{@"cy": @(cy), @"text": top.string}];
            }
            if (items.count == 0) return;

            // 视觉越靠下 = 聊得越新：按 cy 升序排，从底部（最新）往上取，最多 14 行
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
            NSString *joined = [lines componentsJoinedByString:@"\n"];
            if (joined.length > 0) {
                [UIPasteboard generalPasteboard].string = joined;
            }
        });
    });
}

static int g_notifyToken = 0;

%ctor {
    // Darwin notify：键盘与插件同在聊天 App 进程内时直接可达，跨进程同样可达
    notify_register_dispatch("com.jevchat.ask-scan", &g_notifyToken,
                             dispatch_get_main_queue(), ^(int token) {
        performScan();
    });
}
