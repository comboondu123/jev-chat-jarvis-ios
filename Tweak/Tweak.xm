#import <UIKit/UIKit.h>
#import "JevFloaty.h"

// Jev 全局悬浮球（v1.2.0）
//
// 注入目标：SpringBoard（系统主屏进程）——悬浮球在任意 App 前台时都能呼出，
// 不再绑定微信/Soul，任何软件里点输入框弹出键盘，屏幕右缘即出现悬浮球。
//
// 能力：
//   - 点开面板 → 「生成回复」：系统截屏（UIGetScreenImage 截完整屏幕）→
//     Vision OCR 当前画面文字 → 按激活话术并发调模型 → 出候选
//   - 点候选 = 自动复制到剪贴板 → 去输入框长按粘贴（首次允许一次后不再询问）
//   - 打字用系统键盘即可，无需切换到 Jev 键盘；发送永远手动
//
// OCR 逻辑（jev_ocrScreenText）在 JevFloaty.m 里。

%ctor {
    [[JevFloaty shared] start];
}
