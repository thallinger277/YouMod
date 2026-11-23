// Fullscreen button tap area
//
// The enter/exit fullscreen button in the player bar is a ~24pt icon, well
// below the 44pt minimum touch target. A tap that lands a few points off hits
// the overlay instead and just toggles the controls. On top of that, gestures
// that start on the button (long press, swipe to minimize, YouMod's pan for
// gesture controls / seek on overlay) can cancel the button's touch.
//
// This file:
//  1. Routes touches in an enlarged area around the visible fullscreen button
//     to the button (YTMainAppVideoPlayerOverlayView hitTest), without taking
//     touches from other buttons, scroll views or the scrubber.
//  2. Keeps accepting taps while the controls are still fading out.
//  3. Stops other gesture recognizers from beginning on the fullscreen button.
//  4. Gives YouModGestureStartsOnControl() to Player.x so YouMod's own pan
//     gesture never begins on top of a player button.

#import "Headers.h"
#import <objc/runtime.h>

@interface YTEnterExitFullscreenButtonView : UIView
@end

@interface YTInlinePlayerBarContainerView (YouModFullscreenButton)
- (UIView *)enterExitFullscreenButton;
@end

static const void *kYouModFullscreenTargetKey = &kYouModFullscreenTargetKey;

static NSInteger YMFullscreenTapAreaIndex(void) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:FullscreenTapArea];
    return value ? [value integerValue] : 1;
}

static BOOL YMFullscreenFixEnabled(void) {
    return YMFullscreenTapAreaIndex() != 0;
}

// Enlarged touch rect around a button frame for the current setting.
static CGRect YMExpandedRect(CGRect frame) {
    NSInteger index = YMFullscreenTapAreaIndex();
    CGFloat minSide = index >= 2 ? 64.0 : 50.0;
    CGFloat minPad = index >= 2 ? 14.0 : 8.0;
    CGFloat dx = MAX(minPad, (minSide - frame.size.width) / 2.0);
    CGFloat dy = MAX(minPad, (minSide - frame.size.height) / 2.0);
    return CGRectInset(frame, -dx, -dy);
}

static BOOL YMIsFullscreenTarget(UIView *view) {
    return [objc_getAssociatedObject(view, kYouModFullscreenTargetKey) boolValue];
}

static void YMMarkFullscreenTarget(UIView *view) {
    if (view && !YMIsFullscreenTarget(view))
        objc_setAssociatedObject(view, kYouModFullscreenTargetKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Opacity as the user sees it: during a fade-out the model alpha is already 0
// while the presentation layer is still visible.
static CGFloat YMVisibleAlpha(UIView *view) {
    CGFloat alpha = view.alpha;
    CALayer *presentation = view.layer.presentationLayer;
    if (presentation) alpha = MAX(alpha, (CGFloat)presentation.opacity);
    return alpha;
}

// YES when the view and every ancestor up to root can be seen and touched.
static BOOL YMIsTappable(UIView *view, UIView *root) {
    if (!view.window) return NO;
    if ([view isKindOfClass:[UIControl class]] && !((UIControl *)view).enabled) return NO;
    if (CGRectIsEmpty(view.bounds)) return NO;
    for (UIView *v = view; v; v = v.superview) {
        if (v.hidden || !v.userInteractionEnabled || YMVisibleAlpha(v) < 0.05) return NO;
        if (v == root) return YES;
    }
    return NO;
}

static void YMAddCandidate(NSMutableArray<UIView *> *list, id object) {
    if ([object isKindOfClass:[UIView class]] && ![list containsObject:object]) [list addObject:object];
}

// The fullscreen buttons this YouTube version uses. Newer versions wrap the
// button in YTEnterExitFullscreenButtonView; the inner button is preferred.
static NSArray<UIView *> *YMFullscreenCandidates(YTInlinePlayerBarContainerView *bar, UIView *root) {
    NSMutableArray<UIView *> *candidates = [NSMutableArray array];
    if ([bar respondsToSelector:@selector(enterFullscreenButton)]) YMAddCandidate(candidates, [bar enterFullscreenButton]);
    if ([bar respondsToSelector:@selector(exitFullscreenButton)]) YMAddCandidate(candidates, [bar exitFullscreenButton]);
    if ([bar respondsToSelector:@selector(enterExitFullscreenButton)]) {
        id wrapper = [bar enterExitFullscreenButton];
        if ([wrapper isKindOfClass:[UIView class]]) {
            id inner = [wrapper respondsToSelector:@selector(enterExitFullscreenButton)] ? [wrapper enterExitFullscreenButton] : nil;
            if ([inner isKindOfClass:[UIView class]] && YMIsTappable(inner, root)) YMAddCandidate(candidates, inner);
            else YMAddCandidate(candidates, wrapper);
        }
    }
    return candidates;
}

static BOOL YMIsScrubberClassName(NSString *name) {
    if ([name containsString:@"PlayerBarContainer"]) return NO;
    return [name containsString:@"Scrub"] || [name containsString:@"PlayerBarView"] || [name containsString:@"Slider"];
}

// Whether the original hit view may give its touch to the fullscreen button.
// 0 = no, 1 = only very close to the button (scrubber), 2 = yes.
static NSInteger YMStealLevel(UIView *hit, UIView *target, UIView *root) {
    if (!hit || hit == root) return 2;
    NSInteger level = 2;
    for (UIView *v = hit; v && v != root; v = v.superview) {
        if (![target isDescendantOfView:v]) {
            if ([v isKindOfClass:[UIControl class]] || [v isKindOfClass:[UIScrollView class]]) return 0;
            if ([v conformsToProtocol:@protocol(UITextInput)]) return 0;
        }
        if (YMIsScrubberClassName(NSStringFromClass([v class]))) level = 1;
    }
    return level;
}

static CGFloat YMDistanceToRect(CGPoint p, CGRect r) {
    CGFloat dx = MAX(MAX(CGRectGetMinX(r) - p.x, 0), p.x - CGRectGetMaxX(r));
    CGFloat dy = MAX(MAX(CGRectGetMinY(r) - p.y, 0), p.y - CGRectGetMaxY(r));
    return sqrt(dx * dx + dy * dy);
}

BOOL YouModGestureStartsOnControl(UIGestureRecognizer *gesture) {
    if (!YMFullscreenFixEnabled()) return NO;
    UIView *view = gesture.view;
    if (!view.window) return NO;
    CGPoint point = [gesture locationInView:view];
    if ([gesture isKindOfClass:[UIPanGestureRecognizer class]]) {
        CGPoint translation = [(UIPanGestureRecognizer *)gesture translationInView:view];
        point = CGPointMake(point.x - translation.x, point.y - translation.y);
    }
    UIView *hit = [view hitTest:point withEvent:nil];
    CGSize limit = view.bounds.size;
    for (UIView *v = hit; v && v != view; v = v.superview) {
        if (YMIsFullscreenTarget(v)) return YES;
        // Only small controls count, so a full-size transparent control can never disable the gestures.
        if ([v isKindOfClass:[UIControl class]] && v.bounds.size.width < limit.width * 0.4 && v.bounds.size.height < limit.height * 0.4)
            return YES;
    }
    return NO;
}

// UIKit asks the touched view whether other recognizers may begin. Only the
// button's own recognizers and plain single taps (which UIControl already
// handles) stay allowed, so long press, double tap and pans in the player can
// no longer cancel a tap on the fullscreen button. System recognizers (window
// level or private UIKit classes) are never touched.
static BOOL YMShouldBlockRecognizer(UIView *view, UIGestureRecognizer *gesture) {
    if (!YMFullscreenFixEnabled() || !YMIsFullscreenTarget(view)) return NO;
    UIView *owner = gesture.view;
    if (!owner || owner == view || [owner isDescendantOfView:view] || [owner isKindOfClass:[UIWindow class]]) return NO;
    if ([NSStringFromClass([gesture class]) hasPrefix:@"_"]) return NO;
    if ([gesture isKindOfClass:[UIHoverGestureRecognizer class]]) return NO;
    if ([gesture isKindOfClass:[UITapGestureRecognizer class]]) {
        UITapGestureRecognizer *tap = (UITapGestureRecognizer *)gesture;
        if (tap.numberOfTapsRequired <= 1 && tap.numberOfTouchesRequired <= 1) return NO;
    }
    return YES;
}

%hook YTMainAppVideoPlayerOverlayView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = %orig;
    if (!YMFullscreenFixEnabled()) return hit;
    if (self.hidden || !self.userInteractionEnabled || self.alpha < 0.01 || ![self pointInside:point withEvent:event]) return hit;
    YTInlinePlayerBarContainerView *bar = [self respondsToSelector:@selector(playerBar)] ? self.playerBar : nil;
    if (![bar isKindOfClass:%c(YTInlinePlayerBarContainerView)]) return hit;

    UIView *best = nil;
    CGFloat bestDistance = CGFLOAT_MAX;
    for (UIView *target in YMFullscreenCandidates(bar, self)) {
        if (!YMIsTappable(target, self)) continue;
        YMMarkFullscreenTarget(target);
        if (hit == target || [hit isDescendantOfView:target]) return hit;
        CGRect frame = [target convertRect:target.bounds toView:self];
        if (!CGRectContainsPoint(YMExpandedRect(frame), point)) continue;
        NSInteger level = YMStealLevel(hit, target, self);
        if (level == 0) continue;
        if (level == 1 && !CGRectContainsPoint(CGRectInset(frame, -6.0, -6.0), point)) continue;
        CGFloat distance = YMDistanceToRect(point, frame);
        if (distance < bestDistance) {
            bestDistance = distance;
            best = target;
        }
    }
    return best ?: hit;
}
%end

%hook YTQTMButton
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (YMShouldBlockRecognizer(self, gestureRecognizer)) return NO;
    return %orig;
}
%end

%group YMFullscreenWrapper
%hook YTEnterExitFullscreenButtonView
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (YMShouldBlockRecognizer(self, gestureRecognizer)) return NO;
    return %orig;
}
%end
%end

%ctor {
    %init;
    if (objc_getClass("YTEnterExitFullscreenButtonView")) %init(YMFullscreenWrapper);
}
