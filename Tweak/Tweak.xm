#import <UIKit/UIKit.h>
#import <Vision/Vision.h>
#import "JevFloaty.h"

// Jev ScreenReader + 悬浮球（v1.1.0）
//
// 注入目标：微信（com.tencent.xin）/ Soul（com.soulglobal.cn），见 layout 里的 filter plist。
//
// 两条能力线，互不干扰：
//   A. 键盘喂料（保留）：Jev 键盘出现时 post 进程内通知 com.jevchat.ask-scan →
//      本插件 OCR 聊天区 → 写剪贴板 → 键盘 3 秒后拾取分析
//   B. 悬浮球（新增）：聊天界面键盘弹出时屏幕右缘出现可拖动悬浮球 →
//      点开面板：「粘贴剪贴板」直接写入输入框 /「生成回复」OCR 聊天区 →
//      按话术调模型 → 候选直接写入输入框。打字用系统键盘即可，不依赖 Jev 键盘。
//
// OCR 逻辑（jev_ocrScreenText）在 JevFloaty.m 里，A/B 共用同一套规则。

static id g_notifyObserver = nil;

%ctor {
    // A：与键盘同进程，监听 com.jevchat.ask-scan（键盘在微信/Soul 里出现时广播）
    g_notifyObserver =
        [[NSNotificationCenter defaultCenter]
            addObserverForName:@"com.jevchat.ask-scan"
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
                        // OCR 聊天区 → 写剪贴板（键盘版「复制即回复」的越狱喂料）
                        jev_ocrScreenText(^(NSString *text) {
                            if (text.length > 0) {
                                [UIPasteboard generalPasteboard].string = text;
                            }
                        });
                    }];

    // B：悬浮球（键盘出现时显示，点开面板操作）
    [[JevFloaty shared] start];
}
