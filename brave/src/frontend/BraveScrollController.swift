/* This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import UIKit
import SnapKit

private let ToolbarBaseAnimationDuration: CGFloat = 0.2

class BraveScrollController: NSObject {
    enum ScrollDirection {
        case up
        case down
        case none  // Brave added
    }

    weak var browser: Browser? {
        willSet {
            self.scrollView?.delegate = nil
            BraveApp.getCurrentWebView()?.removeGestureRecognizer(tapShowBottomBar)
        }

        didSet {
            BraveApp.getCurrentWebView()?.addGestureRecognizer(tapShowBottomBar)
            scrollView?.delegate = self
        }
    }

    lazy var tapShowBottomBar: UITapGestureRecognizer = {
        let t = UITapGestureRecognizer(target: self, action: #selector(onTapShowBottomBar))
        t.delegate = self
        return t
    }()

    weak var header: UIView?
    weak var footer: UIView?
    weak var urlBar: URLBarView?
    weak var snackBars: UIView?

    var keyboardIsShowing = false
    var verticalTranslation = CGFloat(0)

    var footerBottomConstraint: Constraint?
    var headerTopConstraint: Constraint?
    var toolbarsShowing: Bool { return headerTopOffset == 0 }

    var edgeSwipingActive = false

    fileprivate var headerTopOffset: CGFloat = 0 {
        didSet {
            headerTopConstraint?.update(offset: headerTopOffset)
            header?.superview?.setNeedsLayout()
        }
    }

    fileprivate var footerBottomOffset: CGFloat = 0 {
        didSet {
            footerBottomConstraint?.update(offset: footerBottomOffset)
            footer?.superview?.setNeedsLayout()
        }
    }

    fileprivate var scrollView: UIScrollView? { return browser?.webView?.scrollView }
    fileprivate var contentOffset: CGPoint { return scrollView?.contentOffset ?? CGPoint.zero }
    fileprivate var contentSize: CGSize { return scrollView?.contentSize ?? CGSize.zero }
    fileprivate var scrollViewHeight: CGFloat { return scrollView?.frame.height ?? 0 }
    fileprivate var headerFrame: CGRect { return header?.frame ?? CGRect.zero }
    fileprivate var footerFrame: CGRect { return footer?.frame ?? CGRect.zero }
    fileprivate var snackBarsFrame: CGRect { return snackBars?.frame ?? CGRect.zero }

    struct LastScrollPosition {
        static var x = CGFloat(0)
        static var y = CGFloat(0)
    }
    fileprivate var scrollDirection: ScrollDirection = .down

    // Brave added
    // What I am seeing on older devices is when scroll direction is changed quickly, and the toolbar show/hides,
    // the first or second pan gesture after that will report the wrong direction (the gesture handling seems bugging during janky scrolling)
    // This added check is a secondary validator of the scroll direction
    fileprivate var scrollViewWillBeginDragPoint: CGFloat = 0

    func setVerticalInset(top: CGFloat = 0, bottom: CGFloat = 0) {
        scrollView?.contentInset = UIEdgeInsetsMake(top, 0, bottom, 0)
        scrollView?.scrollIndicatorInsets = UIEdgeInsetsMake(top, 0, bottom, 0)
    }

    override init() {
        super.init()

        NotificationCenter.default.addObserver(self, selector: #selector(BraveScrollController.pageUnload), name: NSNotification.Name(rawValue: kNotificationPageUnload), object: nil)

        NotificationCenter.default.addObserver(self, selector:#selector(BraveScrollController.keyboardWillAppear(_:)), name: NSNotification.Name.UIKeyboardWillShow, object: nil)
        NotificationCenter.default.addObserver(self, selector:#selector(BraveScrollController.keyboardDidAppear(_:)), name: NSNotification.Name.UIKeyboardDidShow, object: nil)
        NotificationCenter.default.addObserver(self, selector:#selector(BraveScrollController.keyboardWillDisappear(_:)), name: NSNotification.Name.UIKeyboardWillHide, object: nil)
    }

    func keyboardWillAppear(_ notification: Notification){
        keyboardIsShowing = true
    }
    
    func keyboardDidAppear(_ notification: Notification){
        checkHeightOfPageAndAdjustWebViewInsets(keyboardAppeared: true)
    }

    func keyboardWillDisappear(_ notification: Notification){
        keyboardIsShowing = false

        postAsyncToMain(0.2) {
            // Hiding/showing toolbars during kb show affects layout updating, reset the toolbar state
            self.verticalTranslation = 0
            self.header?.layer.transform = CATransform3DIdentity
            self.footer?.layer.transform = CATransform3DIdentity
            if self.headerTopOffset < 0 {
                self.headerTopOffset = -BraveURLBarView.CurrentHeight
                self.footerBottomOffset = UIConstants.ToolbarHeight
            } else {
                self.headerTopOffset = 0
                self.footerBottomOffset = 0
                self.urlBar?.updateAlphaForSubviews(1.0)
            }
        }
    }

    func pageUnload() {
        postAsyncToMain(0.1) {
            self.showToolbars(animated: true)
        }
    }

    // Struct used to prevent inset adjustment based on runtime scenarios
    struct RuntimeInsetChecks {
        // If inset adjustment code is already being executed
        static var isRunningCheck = false
        
        // Whether webview is currently being zoomed
        // Should not update on zooming (e.g. issue #717)
        static var isZoomingCheck = false
    }
    
    // This causes issue #216 if contentInset changed during a load
    func checkHeightOfPageAndAdjustWebViewInsets(keyboardAppeared: Bool = false) {

        if RuntimeInsetChecks.isZoomingCheck {
            return
        }

        if self.browser?.webView?.isLoading ?? false {
            if RuntimeInsetChecks.isRunningCheck {
                return
            }
            RuntimeInsetChecks.isRunningCheck = true
            postAsyncToMain(0.2) {
                RuntimeInsetChecks.isRunningCheck = false
                self.checkHeightOfPageAndAdjustWebViewInsets(keyboardAppeared: keyboardAppeared)
            }
        } else {
            RuntimeInsetChecks.isRunningCheck = false

            if !isScrollHeightIsLargeEnoughForScrolling() && !keyboardIsShowing {
                let h = BraveApp.isIPhonePortrait() ? UIConstants.ToolbarHeight : 0
                setVerticalInset(top: BraveURLBarView.CurrentHeight, bottom: h)
            }
            else {
                setVerticalInset(top: BraveURLBarView.CurrentHeight, bottom: UIConstants.ToolbarHeight)
            }
        }
    }

    func showToolbars(animated: Bool, isShowingDueToBottomTap: Bool = false, completion: ((_ finished: Bool) -> Void)? = nil) {
        checkHeightOfPageAndAdjustWebViewInsets()

        if verticalTranslation == 0 && headerTopOffset == 0 {
            completion?(true)
            return
        }

        removeTranslationAndSetLayout()

        let durationRatio = abs(headerTopOffset / headerFrame.height)
        let actualDuration = TimeInterval(ToolbarBaseAnimationDuration * durationRatio)
        self.animateToolbarsWithOffsets(
            animated: animated,
            duration: actualDuration,
            headerOffset: 0,
            footerOffset: 0,
            alpha: 1,
            isShowingDueToBottomTap: isShowingDueToBottomTap,
            completion: completion)
    }

    var entrantGuard = false
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if entrantGuard {
            return
        }
        entrantGuard = true
        defer {
            entrantGuard = false
        }
        
        if (keyPath ?? "") == "contentSize" { // && browser?.webView?.scrollView === object {
            browser?.webView?.contentSizeChangeDetected()
            //Slight delay allows the keyboardDidAppear to be called first and adjust textfield positioning.
            postAsyncToMain(0.2) {
                self.checkHeightOfPageAndAdjustWebViewInsets()
            }
            if !isScrollHeightIsLargeEnoughForScrolling() && !toolbarsShowing {
                showToolbars(animated: true, completion: nil)
            }
        }
    }

    //// bottom tap //////
    func onTapShowBottomBar(_ gesture: UITapGestureRecognizer) {
        if toolbarsShowing || !BraveApp.isIPhonePortrait() {
            return
        }

        guard let height = gesture.view?.frame.height else { return }
        if gesture.location(in: gesture.view).y > height - UIConstants.ToolbarHeight {
            showToolbars(animated: true, isShowingDueToBottomTap: true)
        }
    }
}

private extension BraveScrollController {
    func browserIsLoading() -> Bool {
        return browser?.loading ?? true
    }
    
    func clamp(_ y: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        if y >= max {
            return max
        } else if y <= min {
            return min
        }
        return y
    }

    // Currently only has handling for the show toolbars case.
    func animateToolbarsWithOffsets(animated: Bool, duration: TimeInterval, headerOffset: CGFloat,
                                                     footerOffset: CGFloat, alpha: CGFloat, isShowingDueToBottomTap: Bool, completion: ((_ finished: Bool) -> Void)?) {

        let animation: () -> Void = {
            self.headerTopOffset = headerOffset
            self.footerBottomOffset = footerOffset
            self.urlBar?.updateAlphaForSubviews(alpha)
            self.header?.layoutIfNeeded()
            self.footer?.layoutIfNeeded()

            // TODO this code is only being used to show toolbars, so right now hard-code for that case, obviously if/when hide is added, update the code to support that
            let webView = getApp().browserViewController.webViewContainer
            webView?.layer.transform = CATransform3DIdentity

            if isShowingDueToBottomTap { // scroll up to show page under the bottom toolbar
                self.scrollView?.contentOffset.y += 2 * BraveURLBarView.CurrentHeight
            } else if self.contentOffset.y > BraveURLBarView.CurrentHeight {
                // keep the web view in the same scroll position by scrolling up the toolbar height 
                self.scrollView?.contentOffset.y += BraveURLBarView.CurrentHeight
            }
        }

        // Reset the scroll direction now that it is handled
        scrollDirection = .none

        let completionWrapper: (Bool) -> Void = { finished in
            completion?(finished)
        }

        if animated {
            UIView.animate(withDuration: 0.350, delay:0.0, options: .allowUserInteraction, animations: animation, completion: completionWrapper)
        } else {
            animation()
            completion?(true)
        }
    }

    func isScrollHeightIsLargeEnoughForScrolling() -> Bool {
        return (UIScreen.main.bounds.size.height + 2 * UIConstants.ToolbarHeight) < scrollView?.contentSize.height ?? 0
    }
}

extension BraveScrollController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}

func blockOtherGestures(_ isBlocked: Bool, views: [UIView]) {
    for view in views {
        if let gestures = view.gestureRecognizers as [UIGestureRecognizer]! {
            for gesture in gestures {
                gesture.isEnabled = !isBlocked
            }
        }
    }
}

var refreshControl:ODRefreshControl?
// stop refresh interaction while animating
var isInRefreshQuietPeriod:Bool = false
// only allow refresh when scrolling with finger down, not from a momentum scrll
var isRefreshBlockedDueToMomentumScroll = false

extension BraveScrollController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let webView = browser?.webView else { return }
        if webViewIsZoomed(webView) {
            return
        }

//        let position = -webView.convert(webView.frame.origin, from: nil).y
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if (!decelerate) {
            removeTranslationAndSetLayout()
        } else {
            isRefreshBlockedDueToMomentumScroll = true
        }
    }

    func removeTranslationAndSetLayout() {
        if verticalTranslation == 0 {
            return
        }

        if verticalTranslation < 0 && headerTopOffset == 0 {
            headerTopOffset = -BraveURLBarView.CurrentHeight
            footerBottomOffset = UIConstants.ToolbarHeight
            urlBar?.updateAlphaForSubviews(0)
        } else if verticalTranslation > UIConstants.ToolbarHeight / 2.0 && headerTopOffset != 0 {
            headerTopOffset = 0
            footerBottomOffset = 0
            urlBar?.updateAlphaForSubviews(1.0)
        }

        verticalTranslation = 0
        header?.layer.transform = CATransform3DIdentity
        footer?.layer.transform = CATransform3DIdentity
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        // freeze
        RuntimeInsetChecks.isZoomingCheck = true
    }
    
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        // unfreeze
        RuntimeInsetChecks.isZoomingCheck = false
    }
    
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        self.removeTranslationAndSetLayout()
    }
    
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        showToolbars(animated: true)
        return true
    }
}
