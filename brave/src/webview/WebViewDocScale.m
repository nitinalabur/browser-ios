#import "WebViewDocScale.h"
#import "BraveWebView.swift"

BOOL webViewIsZoomed(BraveWebView *webView) {
    SEL selector = NSSelectorFromString(@"_" "documentScale");
    id obj = webView.scrollView.subviews.firstObject;
    if (!obj || ![obj respondsToSelector:selector]) {
        return NO;
    }
    float (*func)(id,SEL) = (float (*)(id,SEL))[obj methodForSelector:selector];
    float f = (func)(obj, selector);
    return f > 1.0;
}
