#import <UIKit/UIKit.h>

// Jev 悬浮球（注入微信 / Soul 进程内，由 Tweak.xm 的 %ctor 启动）
//
// 交互：聊天界面键盘弹出 → 屏幕右缘出现可拖动悬浮球（键盘上方，不挡打字）
//   点球 → 面板：
//     ·「粘贴剪贴板」：剪贴板内容直接写入当前输入框（注入进程直接操作输入框控件，
//       不走系统粘贴流程；iOS 首次会弹一次宿主 App 的「允许粘贴」，允许后不再提示）
//     ·「生成回复」：OCR 当前聊天区 → 按所选话术调模型 → 候选直接写入输入框
//   发送永远由用户手动完成。

@interface JevFloaty : NSObject

+ (instancetype)shared;

/// 注册键盘通知监听（Tweak.xm 的 %ctor 里调用）
- (void)start;

/// 屏幕 OCR → 聊天区文本（异步，主线程回调）。与键盘版共用同一套 OCR 规则。
FOUNDATION_EXPORT void jev_ocrScreenText(void (^completion)(NSString *text));

@end
