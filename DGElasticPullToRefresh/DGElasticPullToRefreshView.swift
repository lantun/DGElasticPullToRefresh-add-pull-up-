/*

The MIT License (MIT)

Copyright (c) 2015 Danil Gontovnik

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

*/

import UIKit

// MARK: -
// MARK: DGElasticPullToRefreshState

public
enum DGElasticPullToRefreshState: Int {
    case Stopped
    case Dragging
    case AnimatingBounce
    case Loading
    case AnimatingToStopped
    
    func isAnyOf(values: [DGElasticPullToRefreshState]) -> Bool {
        return values.contains({ $0 == self })
    }
}

enum PullDirection: Int {
    case Up     // 上拉
    case Down   // 下拉
}

// MARK: -
// MARK: DGElasticPullToRefreshView

public class DGElasticPullToRefreshView: UIView {
    
    var direction: PullDirection!
    
    // MARK: -
    // MARK: Vars
    
    private var _state: DGElasticPullToRefreshState = .Stopped
    private(set) var state: DGElasticPullToRefreshState {
        get { return _state }
        set {
            let previousValue = state
            _state = newValue
            
            if previousValue == .Dragging && newValue == .AnimatingBounce {
                loadingView?.startAnimating()
                animateBounce()
            } else if newValue == .Loading && actionHandler != nil {
                actionHandler()
            } else if newValue == .AnimatingToStopped {
                resetScrollViewContentInset(shouldAddObserverWhenFinished: true, animated: true, completion: { [weak self] () -> () in self?.state = .Stopped })
            } else if newValue == .Stopped {
                loadingView?.stopLoading()
            }
        }
    }
    
    private var originalContentInsetTop: CGFloat = 0.0 { didSet { layoutSubviews() } }
    private var originalContentInsetBottom: CGFloat = 0.0 { didSet { layoutSubviews() } }
    private let shapeLayer = CAShapeLayer()
    
    private var displayLink: CADisplayLink!
    
    var actionHandler: (() -> Void)! = nil
    
    var loadingView: DGElasticPullToRefreshLoadingView? {
        willSet {
            loadingView?.removeFromSuperview()
            if let newValue = newValue {
                addSubview(newValue)
            }
        }
    }
    
    var observing: Bool = false {
        didSet {
            guard let scrollView = scrollView() else { return }
            if observing {
                scrollView.dg_addObserver(self, forKeyPath: DGElasticPullToRefreshConstants.KeyPaths.ContentOffset)
                scrollView.dg_addObserver(self, forKeyPath: DGElasticPullToRefreshConstants.KeyPaths.ContentInset)
                scrollView.dg_addObserver(self, forKeyPath: DGElasticPullToRefreshConstants.KeyPaths.Frame)
                scrollView.dg_addObserver(self, forKeyPath: DGElasticPullToRefreshConstants.KeyPaths.PanGestureRecognizerState)
            } else {
                scrollView.dg_removeObserver(self, forKeyPath: DGElasticPullToRefreshConstants.KeyPaths.ContentOffset)
                scrollView.dg_removeObserver(self, forKeyPath: DGElasticPullToRefreshConstants.KeyPaths.ContentInset)
                scrollView.dg_removeObserver(self, forKeyPath: DGElasticPullToRefreshConstants.KeyPaths.Frame)
                scrollView.dg_removeObserver(self, forKeyPath: DGElasticPullToRefreshConstants.KeyPaths.PanGestureRecognizerState)
            }
        }
    }
    
    var fillColor: UIColor = .clearColor() { didSet { shapeLayer.fillColor = fillColor.CGColor } }
    
    // MARK: Views
    
    private let bounceAnimationHelperView = UIView()
    
    private let cControlPointView = UIView()
    private let l1ControlPointView = UIView()
    private let l2ControlPointView = UIView()
    private let l3ControlPointView = UIView()
    private let r1ControlPointView = UIView()
    private let r2ControlPointView = UIView()
    private let r3ControlPointView = UIView()
    
    // MARK: -
    // MARK: Constructors
    
    init() {
        super.init(frame: CGRect.zero)
        
        displayLink = CADisplayLink(target: self, selector: Selector("displayLinkTick"))
        displayLink.addToRunLoop(NSRunLoop.mainRunLoop(), forMode: NSRunLoopCommonModes)
        displayLink.paused = true
        
        shapeLayer.backgroundColor = UIColor.clearColor().CGColor
        shapeLayer.fillColor = UIColor.blackColor().CGColor
        shapeLayer.actions = ["path" : NSNull(), "position" : NSNull(), "bounds" : NSNull()]
        layer.addSublayer(shapeLayer)
        
        addSubview(bounceAnimationHelperView)
        addSubview(cControlPointView)
        addSubview(l1ControlPointView)
        addSubview(l2ControlPointView)
        addSubview(l3ControlPointView)
        addSubview(r1ControlPointView)
        addSubview(r2ControlPointView)
        addSubview(r3ControlPointView)
        
        
        NSNotificationCenter.defaultCenter().addObserver(self, selector: Selector("applicationWillEnterForeground"), name: UIApplicationWillEnterForegroundNotification, object: nil)
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: -

    /**
    Has to be called when the receiver is no longer required. Otherwise the main loop holds a reference to the receiver which in turn will prevent the receiver from being deallocated.
    */
    func disassociateDisplayLink() {
        displayLink?.invalidate()
    }

    deinit {
        observing = false
        NSNotificationCenter.defaultCenter().removeObserver(self)
    }

    // MARK: -
    // MARK: Observer
    
    override public func observeValueForKeyPath(keyPath: String?, ofObject object: AnyObject?, change: [String : AnyObject]?, context: UnsafeMutablePointer<Void>) {
        
        if keyPath == DGElasticPullToRefreshConstants.KeyPaths.ContentOffset {
            guard let scrollView = scrollView() else { return  }
            scrollViewDidChangeContentOffset(dragging: scrollView.dragging)
            layoutSubviews()
        } else if keyPath == DGElasticPullToRefreshConstants.KeyPaths.ContentInset {
            // 设置内距
            if let newContentInsetTop = change?[NSKeyValueChangeNewKey]?.UIEdgeInsetsValue().top {
                originalContentInsetTop = newContentInsetTop
            }
            if let newContentInsetBottom = change?[NSKeyValueChangeNewKey]?.UIEdgeInsetsValue().bottom {
                originalContentInsetBottom = newContentInsetBottom
            }
        } else if keyPath == DGElasticPullToRefreshConstants.KeyPaths.Frame {
            layoutSubviews()
        } else if keyPath == DGElasticPullToRefreshConstants.KeyPaths.PanGestureRecognizerState {
            if let gestureState = scrollView()?.panGestureRecognizer.state where gestureState.dg_isAnyOf([.Ended, .Cancelled, .Failed]) {
                scrollViewDidChangeContentOffset(dragging: false)
            }
        }
    }
    
    // MARK: -
    // MARK: Notifications
    
    func applicationWillEnterForeground() {
        if state == .Loading {
            layoutSubviews()
        }
    }
    
    // MARK: -
    // MARK: Methods (Public)
    
    private func scrollView() -> UIScrollView? {
        return superview as? UIScrollView
    }
    
    func stopLoading() {
        // Prevent stop close animation
        if state == .AnimatingToStopped {
            return
        }
        state = .AnimatingToStopped
    }
    
    // MARK: Methods (Private)
    
    private func isAnimating() -> Bool {
        return state.isAnyOf([.AnimatingBounce, .AnimatingToStopped])
    }
    
    private func actualContentOffsetY() -> CGFloat {
        guard let scrollView = scrollView() else { return 0.0 }
        let offsetY = scrollView.contentOffset.y + scrollView.bounds.height - scrollView.contentSize.height
        if direction == .Up {
            return max(offsetY + originalContentInsetBottom, 0)
        }
        return max( -originalContentInsetTop-scrollView.contentOffset.y, 0)
    }
    
    private func currentHeight() -> CGFloat {
        guard let scrollView = scrollView() else { return 0.0 }
        let offsetY = scrollView.contentOffset.y + scrollView.bounds.height - scrollView.contentSize.height
        if direction == .Up {
            return max(offsetY + originalContentInsetBottom, 0)
        }
        return max( -originalContentInsetTop-scrollView.contentOffset.y, 0)
    }
    
    private func currentWaveHeight() -> CGFloat {
        return min(bounds.height / 3.0 * 1.6, DGElasticPullToRefreshConstants.WaveMaxHeight)
    }
    
    private func checkPullUp() -> Bool {
        guard let scrollView = scrollView() else { return false }
        let offsetY = scrollView.contentOffset.y + scrollView.bounds.height - scrollView.contentSize.height
        if offsetY >= 0 {
            return true
        }
        if scrollView.contentOffset.y < 0 {
            return false
        }
        return false
    }
    
    private func currentPath() -> CGPath {
        let width: CGFloat = scrollView()?.bounds.width ?? 0.0
        
        let bezierPath = UIBezierPath()
        let animating = isAnimating()
        
        let height = max(currentHeight(), DGElasticPullToRefreshConstants.LoadingContentInset)
        if direction == .Up {
            bezierPath.moveToPoint(CGPoint(x: 0.0, y: height))
        }else{
            bezierPath.moveToPoint(CGPoint(x: 0.0, y: 0.0))
        }
        bezierPath.addLineToPoint(CGPoint(x: 0.0, y: l3ControlPointView.dg_center(animating).y))
        bezierPath.addCurveToPoint(l1ControlPointView.dg_center(animating), controlPoint1: l3ControlPointView.dg_center(animating), controlPoint2: l2ControlPointView.dg_center(animating))
        bezierPath.addCurveToPoint(r1ControlPointView.dg_center(animating), controlPoint1: cControlPointView.dg_center(animating), controlPoint2: r1ControlPointView.dg_center(animating))
        bezierPath.addCurveToPoint(r3ControlPointView.dg_center(animating), controlPoint1: r1ControlPointView.dg_center(animating), controlPoint2: r2ControlPointView.dg_center(animating))
        if direction == .Up {
            bezierPath.addLineToPoint(CGPoint(x: width, y: height))
        }else{
            bezierPath.addLineToPoint(CGPoint(x: width, y: 0.0))
        }
        
        bezierPath.closePath()
        
        return bezierPath.CGPath
    }
    
    private func scrollViewDidChangeContentOffset(dragging dragging: Bool) {
        
        if checkPullUp() {
            direction = .Up
        }else{
            direction = .Down
        }
        
        let offsetY = actualContentOffsetY()
        
        if state == .Stopped && dragging {
            state = .Dragging
        } else if state == .Dragging && dragging == false {
            if offsetY >= DGElasticPullToRefreshConstants.MinOffsetToPull {
                // 转圈圈
                state = .AnimatingBounce
            } else {
                // 直接收起
                state = .Stopped
            }
        } else if state.isAnyOf([.Dragging, .Stopped]) {
            // set progress
            let pullProgress: CGFloat = offsetY / DGElasticPullToRefreshConstants.MinOffsetToPull
            loadingView?.setPullProgress(pullProgress)
        }
    }
    
    private func resetScrollViewContentInset(shouldAddObserverWhenFinished shouldAddObserverWhenFinished: Bool, animated: Bool, completion: (() -> ())?) {
        guard let scrollView = scrollView() else { return }
        
        var contentInset = scrollView.contentInset
        contentInset.top = originalContentInsetTop
        contentInset.bottom = originalContentInsetBottom
        
        if state == .AnimatingBounce {
            // bounce animation
            if direction == .Up {
                contentInset.bottom += currentHeight()
            }else{
                contentInset.top += currentHeight()
            }
            
        } else if state == .Loading {
            if direction == .Up {
                contentInset.bottom += DGElasticPullToRefreshConstants.LoadingContentInset
            }else{
                contentInset.top += DGElasticPullToRefreshConstants.LoadingContentInset
            }
        }
        
        scrollView.dg_removeObserver(self, forKeyPath: DGElasticPullToRefreshConstants.KeyPaths.ContentInset)
        
        let animationBlock = { scrollView.contentInset = contentInset }
        let completionBlock = { () -> Void in
            if shouldAddObserverWhenFinished && self.observing {
                scrollView.dg_addObserver(self, forKeyPath: DGElasticPullToRefreshConstants.KeyPaths.ContentInset)
            }
            completion?()
        }
        
        if animated {
            startDisplayLink()
            UIView.animateWithDuration(0.4, animations: animationBlock, completion: { _ in
                self.stopDisplayLink()
                completionBlock()
            })
        } else {
            animationBlock()
            completionBlock()
        }
    }
    
    private func animateBounce() {
        guard let scrollView = scrollView() else { return }
        
        resetScrollViewContentInset(shouldAddObserverWhenFinished: false, animated: false, completion: nil)
        
        var centerY = DGElasticPullToRefreshConstants.LoadingContentInset
        
        if direction == .Up {
            centerY = 0
        }
        
        
        let duration = 0.9
        
        scrollView.scrollEnabled = false
        startDisplayLink()
        scrollView.dg_removeObserver(self, forKeyPath: DGElasticPullToRefreshConstants.KeyPaths.ContentOffset)
        scrollView.dg_removeObserver(self, forKeyPath: DGElasticPullToRefreshConstants.KeyPaths.ContentInset)
        UIView.animateWithDuration(duration, delay: 0.0, usingSpringWithDamping: 0.43, initialSpringVelocity: 0.0, options: [], animations: { [weak self] in
            self?.cControlPointView.center.y = centerY
            self?.l1ControlPointView.center.y = centerY
            self?.l2ControlPointView.center.y = centerY
            self?.l3ControlPointView.center.y = centerY
            self?.r1ControlPointView.center.y = centerY
            self?.r2ControlPointView.center.y = centerY
            self?.r3ControlPointView.center.y = centerY
            }, completion: { [weak self] _ in
                self?.stopDisplayLink()
                self?.resetScrollViewContentInset(shouldAddObserverWhenFinished: true, animated: false, completion: nil)
                if let strongSelf = self, scrollView = strongSelf.scrollView() {
                    scrollView.dg_addObserver(strongSelf, forKeyPath: DGElasticPullToRefreshConstants.KeyPaths.ContentOffset)
                    scrollView.scrollEnabled = true
                }
                self?.state = .Loading // begin loading
            })
        
        bounceAnimationHelperView.center = CGPoint(x: 0.0, y: 0 + currentHeight())
        UIView.animateWithDuration(duration * 0.4, animations: { [weak self] in
            self?.bounceAnimationHelperView.center = CGPoint(x: 0.0, y: DGElasticPullToRefreshConstants.LoadingContentInset)
            }, completion: nil)
    }
    
    // MARK: -
    // MARK: CADisplayLink
    
    private func startDisplayLink() {
        displayLink.paused = false
    }
    
    private func stopDisplayLink() {
        displayLink.paused = true
    }
    
    func displayLinkTick() {
        let width = bounds.width
        var height: CGFloat = 0.0
        
        if state == .AnimatingBounce {
            guard let scrollView = scrollView() else { return }
        
            if direction == .Up {
               // 渐渐向下收起
                scrollView.contentInset.bottom = bounceAnimationHelperView.dg_center(isAnimating()).y
                scrollView.contentOffset.y = scrollView.contentSize.height-(scrollView.bounds.height - scrollView.contentInset.bottom)
                height = scrollView.contentInset.bottom
                frame = CGRect(x: 0.0, y: scrollView.contentSize.height + 1.0, width: width, height: height)
            }else{
                // 渐渐向上收起
                scrollView.contentInset.top = bounceAnimationHelperView.dg_center(isAnimating()).y
                scrollView.contentOffset.y = -scrollView.contentInset.top
                height = scrollView.contentInset.top - originalContentInsetTop
                frame = CGRect(x: 0.0, y: -height - 1.0, width: width, height: height)
            }
        } else if state == .AnimatingToStopped {
            height = actualContentOffsetY()
        }

        shapeLayer.frame = CGRect(x: 0.0, y: 0.0, width: width, height: height)
        shapeLayer.path = currentPath()
        
        layoutLoadingView()
    }
    
    // MARK: -
    // MARK: Layout
    
    private func layoutLoadingView() {
        let width = bounds.width
        let height: CGFloat = bounds.height
        
        let loadingViewSize: CGFloat = DGElasticPullToRefreshConstants.LoadingViewSize
        let minOriginY = (DGElasticPullToRefreshConstants.LoadingContentInset - loadingViewSize) / 2.0
        var originY: CGFloat = max(min((height - loadingViewSize) / 2.0, minOriginY), 0.0)
        
        if direction == .Up {
            originY = max(currentHeight() - loadingViewSize - originY ,0)
        }
        
        loadingView?.frame = CGRect(x: (width - loadingViewSize) / 2.0, y: originY, width: loadingViewSize, height: loadingViewSize)
        loadingView?.maskLayer.frame = convertRect(shapeLayer.frame, toView: loadingView)
        loadingView?.maskLayer.path = shapeLayer.path
    }
    
    override public func layoutSubviews() {
        super.layoutSubviews()
        
        if let scrollView = scrollView() where state != .AnimatingBounce {
            let width = scrollView.bounds.width
            let height = currentHeight()
            if direction == .Up {
                frame = CGRect(x: 0.0, y: scrollView.contentSize.height, width: width, height: height)
            }else{
                frame = CGRect(x: 0.0, y: -height, width: width, height: height)
            }
            
            if state.isAnyOf([.Loading, .AnimatingToStopped]) {
                
                cControlPointView.center = CGPoint(x: width / 2.0, y: height)
                l1ControlPointView.center = CGPoint(x: 0.0, y: height)
                l2ControlPointView.center = CGPoint(x: 0.0, y: height)
                l3ControlPointView.center = CGPoint(x: 0.0, y: height)
                r1ControlPointView.center = CGPoint(x: width, y: height)
                r2ControlPointView.center = CGPoint(x: width, y: height)
                r3ControlPointView.center = CGPoint(x: width, y: height)
                if direction == .Up {
                    cControlPointView.center = CGPoint(x: width / 2.0, y: 0)
                    l1ControlPointView.center = CGPoint(x: 0.0, y: 0)
                    l2ControlPointView.center = CGPoint(x: 0.0, y: 0)
                    l3ControlPointView.center = CGPoint(x: 0.0, y: 0)
                    r1ControlPointView.center = CGPoint(x: width, y: 0)
                    r2ControlPointView.center = CGPoint(x: width, y: 0)
                    r3ControlPointView.center = CGPoint(x: width, y: 0)
                }
            } else {
                let locationX = scrollView.panGestureRecognizer.locationInView(scrollView).x
                
                let waveHeight = currentWaveHeight()
                let baseHeight = bounds.height - waveHeight
                print("\(baseHeight)")
                
                let minLeftX = min((locationX - width / 2.0) * 0.28, 0.0)
                let maxRightX = max(width + (locationX - width / 2.0) * 0.28, width)
                
                let leftPartWidth = locationX - minLeftX
                let rightPartWidth = maxRightX - locationX
                
                cControlPointView.center = CGPoint(x: locationX , y: baseHeight + waveHeight * 1.36)
                l1ControlPointView.center = CGPoint(x: minLeftX + leftPartWidth * 0.71, y: baseHeight + waveHeight * 0.64)
                l2ControlPointView.center = CGPoint(x: minLeftX + leftPartWidth * 0.44, y: baseHeight)
                l3ControlPointView.center = CGPoint(x: minLeftX, y: baseHeight)
                r1ControlPointView.center = CGPoint(x: maxRightX - rightPartWidth * 0.71, y: baseHeight + waveHeight * 0.64)
                r2ControlPointView.center = CGPoint(x: maxRightX - (rightPartWidth * 0.44), y: baseHeight)
                r3ControlPointView.center = CGPoint(x: maxRightX, y: baseHeight)
                
                if direction == .Up {
                    cControlPointView.center.y -= height
                    l1ControlPointView.center.y -= height
                    l2ControlPointView.center.y -= height
                    l3ControlPointView.center.y -= height
                    r1ControlPointView.center.y -= height
                    r2ControlPointView.center.y -= height
                    r3ControlPointView.center.y -= height
                    
                    cControlPointView.center.y = -cControlPointView.center.y
                    l1ControlPointView.center.y = -l1ControlPointView.center.y
                    l2ControlPointView.center.y = -l2ControlPointView.center.y
                    l3ControlPointView.center.y = -l3ControlPointView.center.y
                    r1ControlPointView.center.y = -r1ControlPointView.center.y
                    r2ControlPointView.center.y = -r2ControlPointView.center.y
                    r3ControlPointView.center.y = -r3ControlPointView.center.y
                    
                    
                }
                print("cControlPointView.center.y\(cControlPointView.center.y)")
            }
            shapeLayer.frame = CGRect(x: 0.0, y: 0.0, width: width, height: height)
            shapeLayer.path = currentPath()
            
            layoutLoadingView()
        }
    }
    
}
