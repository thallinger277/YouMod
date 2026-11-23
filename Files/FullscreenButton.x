// Fullscreen button tap area
//
// The enter/exit fullscreen button in the player bar is a ~24pt icon, well
// below the 44pt minimum touch target. A tap that lands a few points off hits
// the overlay instead and just toggles the controls. On top of that, gestures
// that start on the button (long press, swipe to minimize, YouMod's pan for
// gesture controls / seek on overlay) can cancel the button's touch.
//
// YouTube builds the player differently depending on server side experiments,
// which are often only applied from the second app launch on. So the button is
// found in several independent ways (player bar properties, its accessibility
// identifier, YTEnterExitFullscreenButtonView) and the hit test is adjusted at
// the player view, the overlay and the window level.
//
// This file:
//  1. Routes touches in an enlarged area around the visible fullscreen button
//     to the button, without taking touches from other buttons, scroll views
//     or the scrubber.
//  2. Keeps accepting taps while the controls are still fading out.
//  3. Stops other gesture recognizers from beginning on the fullscreen button.
//  4. Gives YouModGestureStartsOnControl() to Player.x so YouMod's own pan
//     gesture never begins on top of a player button.
//  5. Optional debug overlay that shows the detected tap area and hit view.

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

#pragma mark - Known fullscreen buttons

static NSHashTable<UIView *> *YMRegisteredViews(void) {
    static NSHashTable<UIView *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

static void YMRegisterView(UIView *view) {
    if (!view) return;
    if (![NSThread isMainThread]) {
        __weak UIView *weakView = view;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIView *strongView = weakView;
            if (strongView) [YMRegisteredViews() addObject:strongView];
        });
        return;
    }
    [YMRegisteredViews() addObject:view];
}

static BOOL YMIsFullscreenIdentifier(NSString *identifier) {
    if (![identifier isKindOfClass:[NSString class]]) return NO;
    return [identifier isEqualToString:@"id.player.watch.fullscreen.button"] || [identifier isEqualToString:@"id.player.watch.exit_fullscreen.button"];
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

// YES when the view and every ancestor up to its window can be seen and touched.
static BOOL YMIsTappable(UIView *view) {
    if (!view.window) return NO;
    if ([view isKindOfClass:[UIControl class]] && !((UIControl *)view).enabled) return NO;
    if (CGRectIsEmpty(view.bounds)) return NO;
    for (UIView *v = view; v; v = v.superview) {
        if (v.hidden || !v.userInteractionEnabled || YMVisibleAlpha(v) < 0.05) return NO;
    }
    return YES;
}

// The view that should receive the touch for a registered button view.
static UIView *YMResolveTarget(UIView *view) {
    if (!view.window) return nil;
    if ([view isKindOfClass:%c(YTEnterExitFullscreenButtonView)] && [view respondsToSelector:@selector(enterExitFullscreenButton)]) {
        id inner = [(id)view enterExitFullscreenButton];
        if ([inner isKindOfClass:[UIView class]] && YMIsTappable(inner)) return inner;
    }
    if (YMIsTappable(view)) return view;
    // A non-interactive icon passes its touches to the nearest small interactive ancestor.
    CGSize size = view.bounds.size;
    UIView *ancestor = view.superview;
    for (NSInteger i = 0; ancestor && i < 3; i++, ancestor = ancestor.superview) {
        CGSize s = ancestor.bounds.size;
        if (s.width > MAX(100.0, size.width * 3.0) || s.height > MAX(100.0, size.height * 3.0)) break;
        if (YMIsTappable(ancestor)) return ancestor;
    }
    return nil;
}

static void YMRegisterPlayerBarButtons(YTInlinePlayerBarContainerView *bar) {
    if (![bar isKindOfClass:%c(YTInlinePlayerBarContainerView)]) return;
    if ([bar respondsToSelector:@selector(enterFullscreenButton)]) YMRegisterView([bar enterFullscreenButton]);
    if ([bar respondsToSelector:@selector(exitFullscreenButton)]) YMRegisterView([bar exitFullscreenButton]);
    if ([bar respondsToSelector:@selector(enterExitFullscreenButton)]) {
        id wrapper = [bar enterExitFullscreenButton];
        if ([wrapper isKindOfClass:[UIView class]]) YMRegisterView(wrapper);
    }
}

// Visible targets inside root, without duplicates.
static NSArray<UIView *> *YMVisibleTargets(UIView *root) {
    NSMutableArray<UIView *> *targets = [NSMutableArray array];
    UIWindow *rootWindow = [root isKindOfClass:[UIWindow class]] ? (UIWindow *)root : root.window;
    if (!rootWindow) return targets;
    for (UIView *view in YMRegisteredViews().allObjects) {
        if (view.window != rootWindow) continue;
        UIView *target = YMResolveTarget(view);
        if (!target || ![target isDescendantOfView:root] || [targets containsObject:target]) continue;
        [targets addObject:target];
    }
    return targets;
}

#pragma mark - Hit test

static BOOL YMIsScrubberClassName(NSString *name) {
    if ([name containsString:@"PlayerBarContainer"]) return NO;
    return [name containsString:@"Scrub"] || [name containsString:@"PlayerBarView"] || [name containsString:@"Slider"];
}

// Small controls are other buttons; big transparent ones are tap catchers.
static BOOL YMIsOtherButton(UIView *view) {
    if (![view isKindOfClass:[UIControl class]]) return NO;
    CGSize size = view.bounds.size;
    return size.width <= 200.0 && size.height <= 120.0;
}

// Whether the original hit view may give its touch to the fullscreen button.
// 0 = no, 1 = only very close to the button (scrubber), 2 = yes.
static NSInteger YMStealLevel(UIView *hit, UIView *target, UIView *root) {
    if (!hit || hit == root) return 2;
    NSInteger level = 2;
    for (UIView *v = hit; v && v != root; v = v.superview) {
        if (![target isDescendantOfView:v]) {
            if (YMIsOtherButton(v) || [v isKindOfClass:[UIScrollView class]]) return 0;
            if ([v conformsToProtocol:@protocol(UITextInput)]) return 0;
        }
        if (YMIsScrubberClassName(NSStringFromClass([v class]))) level = 1;
    }
    return level;
}

// The outermost player view around the button. The enlarged area never
// reaches outside of it, so taps below the player (title, buttons) stay put.
static UIView *YMPlayerClipView(UIView *target) {
    UIView *clip = nil;
    for (UIView *v = target.superview; v && ![v isKindOfClass:[UIWindow class]]; v = v.superview) {
        if ([NSStringFromClass([v class]) containsString:@"Player"]) clip = v;
    }
    return clip;
}

static CGFloat YMDistanceToRect(CGPoint p, CGRect r) {
    CGFloat dx = MAX(MAX(CGRectGetMinX(r) - p.x, 0), p.x - CGRectGetMaxX(r));
    CGFloat dy = MAX(MAX(CGRectGetMinY(r) - p.y, 0), p.y - CGRectGetMaxY(r));
    return sqrt(dx * dx + dy * dy);
}

static UIView *ymDebugView = nil;
static NSUInteger ymDebugToken = 0;
static BOOL ymInternalHitTest = NO;

static void YMShowDebug(UIView *root, CGPoint point, UIView *hit, NSArray<UIView *> *targets, BOOL routed) {
    UIWindow *window = [root isKindOfClass:[UIWindow class]] ? (UIWindow *)root : root.window;
    if (!window) return;
    CGPoint touch = [root convertPoint:point toView:window];
    NSMutableArray<NSValue *> *areas = [NSMutableArray array];
    NSMutableString *text = [NSMutableString stringWithFormat:@"YouMod fullscreen debug (%@)\nknown: %lu, visible: %lu\n",
        NSStringFromClass([root class]), (unsigned long)YMRegisteredViews().allObjects.count, (unsigned long)targets.count];
    for (UIView *target in targets) {
        CGRect frame = [target convertRect:target.bounds toView:window];
        [areas addObject:[NSValue valueWithCGRect:YMExpandedRect(frame)]];
        [text appendFormat:@"- %@ %.0fx%.0f id=%@\n", NSStringFromClass([target class]), frame.size.width, frame.size.height, target.accessibilityIdentifier ?: @"-"];
    }
    [text appendString:@"hit: "];
    if (!hit) [text appendString:@"nil"];
    NSInteger depth = 0;
    for (UIView *v = hit; v && depth < 4; v = v.superview, depth++)
        [text appendFormat:@"%@%@", depth ? @" < " : @"", NSStringFromClass([v class])];
    [text appendFormat:@"\nfullscreen button gets tap: %@", routed ? @"YES" : @"NO"];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!ymDebugView) {
            ymDebugView = [[UIView alloc] initWithFrame:CGRectZero];
            ymDebugView.userInteractionEnabled = NO;
        }
        ymDebugView.frame = window.bounds;
        if (ymDebugView.superview != window) [window addSubview:ymDebugView];
        [window bringSubviewToFront:ymDebugView];
        for (UIView *sub in [ymDebugView.subviews copy]) [sub removeFromSuperview];
        for (NSValue *value in areas) {
            UIView *box = [[UIView alloc] initWithFrame:value.CGRectValue];
            box.userInteractionEnabled = NO;
            box.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.15];
            box.layer.borderColor = [UIColor redColor].CGColor;
            box.layer.borderWidth = 2.0;
            [ymDebugView addSubview:box];
        }
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(touch.x - 6.0, touch.y - 6.0, 12.0, 12.0)];
        dot.userInteractionEnabled = NO;
        dot.layer.cornerRadius = 6.0;
        dot.backgroundColor = routed ? [UIColor greenColor] : [UIColor yellowColor];
        [ymDebugView addSubview:dot];
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.numberOfLines = 0;
        label.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
        label.textColor = [UIColor whiteColor];
        label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.75];
        label.text = text;
        CGFloat width = MIN(window.bounds.size.width - 20.0, 460.0);
        CGSize size = [label sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)];
        label.frame = CGRectMake(10.0, window.safeAreaInsets.top + 10.0, width, size.height);
        [ymDebugView addSubview:label];
        NSUInteger token = ++ymDebugToken;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (token == ymDebugToken) [ymDebugView removeFromSuperview];
        });
    });
}

// Shared hit test logic for the player view, the overlay and the window.
static UIView *YMAdjustHit(UIView *root, CGPoint point, UIEvent *event, UIView *hit, BOOL isPlayerRoot) {
    if (!YMFullscreenFixEnabled()) return hit;
    if (root.hidden || !root.userInteractionEnabled || root.alpha < 0.01 || ![root pointInside:point withEvent:event]) return hit;
    if (!isPlayerRoot && YMRegisteredViews().allObjects.count == 0) return hit;

    NSArray<UIView *> *targets = YMVisibleTargets(root);
    UIView *best = nil;
    CGFloat bestDistance = CGFLOAT_MAX;
    BOOL nearTarget = NO;
    BOOL directHit = NO;
    for (UIView *target in targets) {
        YMMarkFullscreenTarget(target);
        CGRect frame = [target convertRect:target.bounds toView:root];
        if (YMDistanceToRect(point, frame) < 120.0) nearTarget = YES;
        if (hit == target || [hit isDescendantOfView:target]) {
            directHit = YES;
            break;
        }
        if (!CGRectContainsPoint(YMExpandedRect(frame), point)) continue;
        UIView *clip = YMPlayerClipView(target);
        if (clip && ![clip pointInside:[root convertPoint:point toView:clip] withEvent:event]) continue;
        NSInteger level = YMStealLevel(hit, target, root);
        if (level == 0) continue;
        if (level == 1 && !CGRectContainsPoint(CGRectInset(frame, -6.0, -6.0), point)) continue;
        CGFloat distance = YMDistanceToRect(point, frame);
        if (distance < bestDistance) {
            bestDistance = distance;
            best = target;
        }
    }
    UIView *result = directHit ? hit : (best ?: hit);
    if (!ymInternalHitTest && IS_ENABLED(FullscreenTapDebug) && (isPlayerRoot || nearTarget))
        YMShowDebug(root, point, result, targets, directHit || best != nil);
    return result;
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
    ymInternalHitTest = YES;
    UIView *hit = [view hitTest:point withEvent:nil];
    ymInternalHitTest = NO;
    CGSize limit = view.bounds.size;
    for (UIView *v = hit; v && v != view; v = v.superview) {
        if (YMIsFullscreenTarget(v)) return YES;
        // Only small controls count, so a full-size transparent control can never disable the gestures.
        if ([v isKindOfClass:[UIControl class]] && v.bounds.size.width < limit.width * 0.4 && v.bounds.size.height < limit.height * 0.4)
            return YES;
    }
    return NO;
}

%hook YTMainAppVideoPlayerOverlayView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = %orig;
    if (!YMFullscreenFixEnabled()) return hit;
    if ([self respondsToSelector:@selector(playerBar)]) YMRegisterPlayerBarButtons(self.playerBar);
    return YMAdjustHit(self, point, event, hit, YES);
}
%end

%hook YTPlayerView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return YMAdjustHit(self, point, event, %orig, YES);
}
%end

%hook UIWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return YMAdjustHit(self, point, event, %orig, NO);
}
%end

#pragma mark - Registration

%hook UIView
- (void)setAccessibilityIdentifier:(NSString *)identifier {
    %orig;
    if (YMIsFullscreenIdentifier(identifier)) YMRegisterView(self);
}
%end

%hook YTInlinePlayerBarContainerView
- (void)layoutSubviews {
    %orig;
    YMRegisterPlayerBarButtons(self);
}
%end

#pragma mark - Gestures on the button

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

%hook YTQTMButton
- (void)didMoveToWindow {
    %orig;
    if (self.window && YMIsFullscreenIdentifier(self.accessibilityIdentifier)) YMRegisterView(self);
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (YMShouldBlockRecognizer(self, gestureRecognizer)) return NO;
    return %orig;
}
%end

%group YMFullscreenWrapper
%hook YTEnterExitFullscreenButtonView
- (void)didMoveToWindow {
    %orig;
    if (self.window) YMRegisterView(self);
}
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
