import Foundation
import UIKit
import Display
import AsyncDisplayKit
import Postbox
import TelegramCore
import SwiftSignalKit
import TelegramPresentationData
import TelegramUIPreferences
import TelegramAudio
import AccountContext
import LocalizedPeerData
import PhotoResources
import CallsEmoji
import TooltipUI
import AlertUI
import PresentationDataUtils
import DeviceAccess
import ContextUI
import AvatarNode
import AudioBlob
import AnimatedStickerNode
import MediaResources
import TelegramAnimatedStickerNode

private func interpolateFrame(from fromValue: CGRect, to toValue: CGRect, t: CGFloat) -> CGRect {
    return CGRect(x: floorToScreenPixels(toValue.origin.x * t + fromValue.origin.x * (1.0 - t)), y: floorToScreenPixels(toValue.origin.y * t + fromValue.origin.y * (1.0 - t)), width: floorToScreenPixels(toValue.size.width * t + fromValue.size.width * (1.0 - t)), height: floorToScreenPixels(toValue.size.height * t + fromValue.size.height * (1.0 - t)))
}

private func interpolate(from: CGFloat, to: CGFloat, value: CGFloat) -> CGFloat {
    return (1.0 - value) * from + value * to
}

private final class CallVideoNode: ASDisplayNode, PreviewVideoNode {
    private let videoTransformContainer: ASDisplayNode
    private let videoView: PresentationCallVideoView
    
    private var effectView: UIVisualEffectView?
    private let videoPausedNode: ImmediateTextNode
    
    private var isBlurred: Bool = false
    private var currentCornerRadius: CGFloat = 0.0
    
    private let isReadyUpdated: () -> Void
    private(set) var isReady: Bool = false
    private var isReadyTimer: SwiftSignalKit.Timer?
    
    private let readyPromise = ValuePromise(false)
    var ready: Signal<Bool, NoError> {
        return self.readyPromise.get()
    }
    
    private let isFlippedUpdated: (CallVideoNode) -> Void
    
    private(set) var currentOrientation: PresentationCallVideoView.Orientation
    private(set) var currentAspect: CGFloat = 0.0
    
    private var previousVideoHeight: CGFloat?
    
    init(videoView: PresentationCallVideoView, disabledText: String?, assumeReadyAfterTimeout: Bool, isReadyUpdated: @escaping () -> Void, orientationUpdated: @escaping () -> Void, isFlippedUpdated: @escaping (CallVideoNode) -> Void) {
        self.isReadyUpdated = isReadyUpdated
        self.isFlippedUpdated = isFlippedUpdated
        
        self.videoTransformContainer = ASDisplayNode()
        self.videoView = videoView
        videoView.view.clipsToBounds = true
        videoView.view.backgroundColor = .black
        
        self.currentOrientation = videoView.getOrientation()
        self.currentAspect = videoView.getAspect()
        
        self.videoPausedNode = ImmediateTextNode()
        self.videoPausedNode.alpha = 0.0
        self.videoPausedNode.maximumNumberOfLines = 3
        
        super.init()
        
        self.backgroundColor = .black
        self.clipsToBounds = true
        
        if #available(iOS 13.0, *) {
            self.layer.cornerCurve = .continuous
        }
        
        self.videoTransformContainer.view.addSubview(self.videoView.view)
        self.addSubnode(self.videoTransformContainer)
        
        if let disabledText = disabledText {
            self.videoPausedNode.attributedText = NSAttributedString(string: disabledText, font: Font.regular(17.0), textColor: .white)
            self.addSubnode(self.videoPausedNode)
        }
        
        self.videoView.setOnFirstFrameReceived { [weak self] aspectRatio in
            Queue.mainQueue().async {
                guard let strongSelf = self else {
                    return
                }
                if !strongSelf.isReady {
                    strongSelf.isReady = true
                    strongSelf.readyPromise.set(true)
                    strongSelf.isReadyTimer?.invalidate()
                    strongSelf.isReadyUpdated()
                }
            }
        }
        
        self.videoView.setOnOrientationUpdated { [weak self] orientation, aspect in
            Queue.mainQueue().async {
                guard let strongSelf = self else {
                    return
                }
                if strongSelf.currentOrientation != orientation || strongSelf.currentAspect != aspect {
                    strongSelf.currentOrientation = orientation
                    strongSelf.currentAspect = aspect
                    orientationUpdated()
                }
            }
        }
        
        self.videoView.setOnIsMirroredUpdated { [weak self] _ in
            Queue.mainQueue().async {
                guard let strongSelf = self else {
                    return
                }
                strongSelf.isFlippedUpdated(strongSelf)
            }
        }
        
        if assumeReadyAfterTimeout {
            self.isReadyTimer = SwiftSignalKit.Timer(timeout: 3.0, repeat: false, completion: { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                if !strongSelf.isReady {
                    strongSelf.isReady = true
                    strongSelf.readyPromise.set(true)
                    strongSelf.isReadyUpdated()
                }
            }, queue: .mainQueue())
        }
        self.isReadyTimer?.start()
    }
    
    deinit {
        self.isReadyTimer?.invalidate()
    }
    
    override func didLoad() {
        super.didLoad()
        
        if #available(iOS 13.0, *) {
            self.layer.cornerCurve = .continuous
        }
    }
    
    func animateRadialMask(from fromRect: CGRect, to toRect: CGRect) {
        let maskLayer = CAShapeLayer()
        maskLayer.frame = fromRect
        
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(origin: CGPoint(), size: fromRect.size))
        maskLayer.path = path
        
        self.layer.mask = maskLayer
        
        let topLeft = CGPoint(x: 0.0, y: 0.0)
        let topRight = CGPoint(x: self.bounds.width, y: 0.0)
        let bottomLeft = CGPoint(x: 0.0, y: self.bounds.height)
        let bottomRight = CGPoint(x: self.bounds.width, y: self.bounds.height)
        
        func distance(_ v1: CGPoint, _ v2: CGPoint) -> CGFloat {
            let dx = v1.x - v2.x
            let dy = v1.y - v2.y
            return sqrt(dx * dx + dy * dy)
        }
        
        var maxRadius = distance(toRect.center, topLeft)
        maxRadius = max(maxRadius, distance(toRect.center, topRight))
        maxRadius = max(maxRadius, distance(toRect.center, bottomLeft))
        maxRadius = max(maxRadius, distance(toRect.center, bottomRight))
        maxRadius = ceil(maxRadius)
        
        let targetFrame = CGRect(origin: CGPoint(x: toRect.center.x - maxRadius, y: toRect.center.y - maxRadius), size: CGSize(width: maxRadius * 2.0, height: maxRadius * 2.0))
        
        let transition: ContainedViewLayoutTransition = .animated(duration: 0.3, curve: .easeInOut)
        transition.updatePosition(layer: maskLayer, position: targetFrame.center)
        transition.updateTransformScale(layer: maskLayer, scale: maxRadius * 2.0 / fromRect.width, completion: { [weak self] _ in
            self?.layer.mask = nil
        })
    }
    
    func updateLayout(size: CGSize, layoutMode: VideoNodeLayoutMode, transition: ContainedViewLayoutTransition) {
        self.updateLayout(size: size, cornerRadius: self.currentCornerRadius, isOutgoing: true, deviceOrientation: .portrait, isCompactLayout: false, transition: transition)
    }
    
    func updateLayout(size: CGSize, cornerRadius: CGFloat, isOutgoing: Bool, deviceOrientation: UIDeviceOrientation, isCompactLayout: Bool, transition: ContainedViewLayoutTransition) {
        self.currentCornerRadius = cornerRadius
        
        var rotationAngle: CGFloat
        if false && isOutgoing && isCompactLayout {
            rotationAngle = CGFloat.pi / 2.0
        } else {
            switch self.currentOrientation {
            case .rotation0:
                rotationAngle = 0.0
            case .rotation90:
                rotationAngle = CGFloat.pi / 2.0
            case .rotation180:
                rotationAngle = CGFloat.pi
            case .rotation270:
                rotationAngle = -CGFloat.pi / 2.0
            }
            
            var additionalAngle: CGFloat = 0.0
            switch deviceOrientation {
            case .portrait:
                additionalAngle = 0.0
            case .landscapeLeft:
                additionalAngle = CGFloat.pi / 2.0
            case .landscapeRight:
                additionalAngle = -CGFloat.pi / 2.0
            case .portraitUpsideDown:
                rotationAngle = CGFloat.pi
            default:
                additionalAngle = 0.0
            }
            rotationAngle += additionalAngle
            if abs(rotationAngle - CGFloat.pi * 3.0 / 2.0) < 0.01 {
                rotationAngle = -CGFloat.pi / 2.0
            }
            if abs(rotationAngle - (-CGFloat.pi)) < 0.01 {
                rotationAngle = -CGFloat.pi + 0.001
            }
        }
        
        let rotateFrame = abs(rotationAngle.remainder(dividingBy: CGFloat.pi)) > 1.0
        let fittingSize: CGSize
        if rotateFrame {
            fittingSize = CGSize(width: size.height, height: size.width)
        } else {
            fittingSize = size
        }
        
        let unboundVideoSize = CGSize(width: self.currentAspect * 10000.0, height: 10000.0)
        
        var fittedVideoSize = unboundVideoSize.fitted(fittingSize)
        if fittedVideoSize.width < fittingSize.width || fittedVideoSize.height < fittingSize.height {
            let isVideoPortrait = unboundVideoSize.width < unboundVideoSize.height
            let isFittingSizePortrait = fittingSize.width < fittingSize.height
            
            if isCompactLayout && isVideoPortrait == isFittingSizePortrait {
                fittedVideoSize = unboundVideoSize.aspectFilled(fittingSize)
            } else {
                let maxFittingEdgeDistance: CGFloat
                if isCompactLayout {
                    maxFittingEdgeDistance = 200.0
                } else {
                    maxFittingEdgeDistance = 400.0
                }
                if fittedVideoSize.width > fittingSize.width - maxFittingEdgeDistance && fittedVideoSize.height > fittingSize.height - maxFittingEdgeDistance {
                    fittedVideoSize = unboundVideoSize.aspectFilled(fittingSize)
                }
            }
        }
        
        let rotatedVideoHeight: CGFloat = max(fittedVideoSize.height, fittedVideoSize.width)
        
        let videoFrame: CGRect = CGRect(origin: CGPoint(), size: fittedVideoSize)
        
        let videoPausedSize = self.videoPausedNode.updateLayout(CGSize(width: size.width - 16.0, height: 100.0))
        transition.updateFrame(node: self.videoPausedNode, frame: CGRect(origin: CGPoint(x: floor((size.width - videoPausedSize.width) / 2.0), y: floor((size.height - videoPausedSize.height) / 2.0)), size: videoPausedSize))
        
        self.videoTransformContainer.bounds = CGRect(origin: CGPoint(), size: videoFrame.size)
        if transition.isAnimated && !videoFrame.height.isZero, let previousVideoHeight = self.previousVideoHeight, !previousVideoHeight.isZero {
            let scaleDifference = previousVideoHeight / rotatedVideoHeight
            if abs(scaleDifference - 1.0) > 0.001 {
                transition.animateTransformScale(node: self.videoTransformContainer, from: scaleDifference, additive: true)
            }
        }
        self.previousVideoHeight = rotatedVideoHeight
        transition.updatePosition(node: self.videoTransformContainer, position: CGPoint(x: size.width / 2.0, y: size.height / 2.0))
        transition.updateTransformRotation(view: self.videoTransformContainer.view, angle: rotationAngle)
        
        let localVideoFrame = CGRect(origin: CGPoint(), size: videoFrame.size)
        self.videoView.view.bounds = localVideoFrame
        self.videoView.view.center = localVideoFrame.center
        // TODO: properly fix the issue
        // On iOS 13 and later metal layer transformation is broken if the layer does not require compositing
        self.videoView.view.alpha = 0.995
        
        if let effectView = self.effectView {
            transition.updateFrame(view: effectView, frame: localVideoFrame)
        }
        
        transition.updateCornerRadius(layer: self.layer, cornerRadius: self.currentCornerRadius)
    }
    
    func updateIsBlurred(isBlurred: Bool, light: Bool = false, animated: Bool = true) {
        if self.hasScheduledUnblur {
            self.hasScheduledUnblur = false
        }
        if self.isBlurred == isBlurred {
            return
        }
        self.isBlurred = isBlurred
        
        if isBlurred {
            if self.effectView == nil {
                let effectView = UIVisualEffectView()
                self.effectView = effectView
                effectView.frame = self.videoTransformContainer.bounds
                self.videoTransformContainer.view.addSubview(effectView)
            }
            if animated {
                UIView.animate(withDuration: 0.3, animations: {
                    self.videoPausedNode.alpha = 1.0
                    self.effectView?.effect = UIBlurEffect(style: light ? .light : .dark)
                })
            } else {
                self.effectView?.effect = UIBlurEffect(style: light ? .light : .dark)
            }
        } else if let effectView = self.effectView {
            self.effectView = nil
            UIView.animate(withDuration: 0.3, animations: {
                self.videoPausedNode.alpha = 0.0
                effectView.effect = nil
            }, completion: { [weak effectView] _ in
                effectView?.removeFromSuperview()
            })
        }
    }
    
    private var hasScheduledUnblur = false
    func flip(withBackground: Bool) {
        if withBackground {
            self.backgroundColor = .black
        }
        UIView.transition(with: withBackground ? self.videoTransformContainer.view : self.view, duration: 0.4, options: [.transitionFlipFromLeft, .curveEaseOut], animations: {
            UIView.performWithoutAnimation {
                self.updateIsBlurred(isBlurred: true, light: false, animated: false)
            }
        }) { finished in
            self.backgroundColor = nil
            self.hasScheduledUnblur = true
            Queue.mainQueue().after(0.5) {
                if self.hasScheduledUnblur {
                    self.updateIsBlurred(isBlurred: false)
                }
            }
        }
    }
}

final class CallControllerNode: ViewControllerTracingNode, CallControllerNodeProtocol {
    private enum VideoNodeCorner {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }
    
    private let sharedContext: SharedAccountContext
    private let account: Account
    
    private let statusBar: StatusBar
    
    private var presentationData: PresentationData
    private var peer: Peer?
    private let debugInfo: Signal<(String, String), NoError>
    private var forceReportRating = false
    private let easyDebugAccess: Bool
    private let call: PresentationCall
    
    private let containerTransformationNode: ASDisplayNode
    private let containerNode: ASDisplayNode
    private let videoContainerNode: PinchSourceContainerNode
    
    private let animatedGradientNode: ASDisplayNode
    private let audioLevelDisposable = MetaDisposable()

    private lazy var blobNode = VoiceBlobNode(
        maxLevel: 1.2,
        smallBlobRange: (0, 0.5),
        mediumBlobRange: (0.85, 1.0),
        bigBlobRange: (0.9, 1.2)
    )

    private let avatarNode: AvatarNode
    
    private var candidateIncomingVideoNodeValue: CallVideoNode?
    private var incomingVideoNodeValue: CallVideoNode?
    private var incomingVideoViewRequested: Bool = false
    private var candidateOutgoingVideoNodeValue: CallVideoNode?
    private var outgoingVideoNodeValue: CallVideoNode?
    private var outgoingVideoViewRequested: Bool = false
    
    private var removedMinimizedVideoNodeValue: CallVideoNode?
    private var removedExpandedVideoNodeValue: CallVideoNode?
    
    private var isRequestingVideo: Bool = false
    private var animateRequestedVideoOnce: Bool = false
    
    private var hiddenUIForActiveVideoCallOnce: Bool = false
    private var hideUIForActiveVideoCallTimer: SwiftSignalKit.Timer?
    
    private var displayedCameraConfirmation: Bool = false
    private var displayedCameraTooltip: Bool = false
        
    private var expandedVideoNode: CallVideoNode?
    private var minimizedVideoNode: CallVideoNode?
    private var disableAnimationForExpandedVideoOnce: Bool = false
    private var animationForExpandedVideoSnapshotView: UIView? = nil
    
    private var outgoingVideoNodeCorner: VideoNodeCorner = .bottomRight
    private let backButtonArrowNode: ASImageNode
    private let backButtonNode: HighlightableButtonNode
    private let statusNode: CallControllerStatusNode
    private let toastNode: CallControllerToastContainerNode
    private let buttonsNode: CallControllerButtonsNode
    private var keyPreviewNode: CallControllerKeyPreviewNode?
    private let encryptionDescHintNode: TextHintNode
    private let hintNode: TextHintNode
    private var ratingNode: CallRatingNode?
    private var debugNode: CallDebugNode?
    
    private var keyTextData: (Data, String)?
    private let keyButtonNode: CallControllerKeyButton
    
    private var validLayout: (ContainerViewLayout, CGFloat)?
    private var disableActionsUntilTimestamp: Double = 0.0
    
    private var displayedVersionOutdatedAlert: Bool = false
    private var cachedCallTimestamp: Double?
    private var cachedCallTimestampString: String?

    var isMuted: Bool = false {
        didSet {
            self.buttonsNode.isMuted = self.isMuted
            self.updateToastContent()
            if let (layout, navigationBarHeight) = self.validLayout {
                self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.3, curve: .easeInOut))
            }
        }
    }
    
    private var shouldStayHiddenUntilConnection: Bool = false
    
    private var audioOutputState: ([AudioSessionOutput], currentOutput: AudioSessionOutput?)?
    private var callState: PresentationCallState?
    
    var toggleMute: (() -> Void)?
    var setCurrentAudioOutput: ((AudioSessionOutput) -> Void)?
    var beginAudioOuputSelection: ((Bool) -> Void)?
    var acceptCall: (() -> Void)?
    var endCall: (() -> Void)?
    var back: (() -> Void)?
    var presentCallRating: ((CallId, Bool) -> Void)?
    var callEnded: ((Bool) -> Void)?
    var dismissedInteractively: (() -> Void)?
    var present: ((ViewController) -> Void)?
    var dismissAllTooltips: (() -> Void)?
    
    private var toastContent: CallControllerToastContent?
    private var displayToastsAfterTimestamp: Double?
    
    private var buttonsMode: CallControllerButtonsMode?
    
    private var isUIHidden: Bool = false
    private var isVideoPaused: Bool = false
    private var isVideoPinched: Bool = false
        
    private enum PictureInPictureGestureState {
        case none
        case collapsing(didSelectCorner: Bool)
        case dragging(initialPosition: CGPoint, draggingPosition: CGPoint)
    }
    
    private var pictureInPictureGestureState: PictureInPictureGestureState = .none
    private var pictureInPictureCorner: VideoNodeCorner = .topRight
    private var pictureInPictureTransitionFraction: CGFloat = 0.0
    
    private var deviceOrientation: UIDeviceOrientation = .portrait
    private var orientationDidChangeObserver: NSObjectProtocol?
    
    private var currentRequestedAspect: CGFloat?
    private var gradientView: AnimatedGradientView?

    private var animatedEmojiStickers: [String: [StickerPackItem]] {
        call.context.animatedEmojiStickers
    }
    
    private var callDismissed = false
    private let closeCallButtonNode: AnimatedButtonNode
    private var dismissedButtons = false
    
    private var touchTimer: SwiftSignalKit.Timer?
    
    init(sharedContext: SharedAccountContext, account: Account, presentationData: PresentationData, statusBar: StatusBar, debugInfo: Signal<(String, String), NoError>, shouldStayHiddenUntilConnection: Bool = false, easyDebugAccess: Bool, call: PresentationCall) {
        self.closeCallButtonNode = AnimatedButtonNode(
            text: "Close",
            backColor: .white.withAlphaComponent(0.25),
            backTextColor: .white,
            topColor: .white,
            topTextColor: UIColor(hexString: "7261DA")!
        )
        self.avatarNode = AvatarNode(font: Font.bold(58.0))
        self.sharedContext = sharedContext
        self.account = account
        self.presentationData = presentationData
        self.statusBar = statusBar
        self.debugInfo = debugInfo
        self.shouldStayHiddenUntilConnection = shouldStayHiddenUntilConnection
        self.easyDebugAccess = easyDebugAccess
        self.call = call
        
        self.containerTransformationNode = ASDisplayNode()
        self.containerTransformationNode.clipsToBounds = true
        
        self.containerNode = ASDisplayNode()
        
        self.videoContainerNode = PinchSourceContainerNode()
        self.animatedGradientNode = ASDisplayNode()
        self.hintNode = TextHintNode(text: "Weak network signal", font: Font.with(size: 16.0), isHidden: true)
      
        let img = generateTintedImage(image: UIImage(bundleImageName: "Chat/Stickers/SmallLock"), color: .white)
        self.encryptionDescHintNode = TextHintNode(text: "Encryption key of this call", font: Font.with(size: 15.0), radius: 14.0, showTail: true, image: img, isHidden: true)

        animatedGradientNode.displaysAsynchronously = false
        animatedGradientNode.frame = UIScreen.main.bounds
        
        let _: DefaultAnimatedStickerNodeImpl = DefaultAnimatedStickerNodeImpl(useMetalCache: sharedContext.immediateExperimentalUISettings.acceleratedStickers)
                
        self.backButtonArrowNode = ASImageNode()
        self.backButtonArrowNode.displayWithoutProcessing = true
        self.backButtonArrowNode.displaysAsynchronously = false
        self.backButtonArrowNode.image = NavigationBarTheme.generateBackArrowImage(color: .white)
        self.backButtonNode = HighlightableButtonNode()
        
        self.statusNode = CallControllerStatusNode()
        
        self.buttonsNode = CallControllerButtonsNode(strings: self.presentationData.strings)
        self.toastNode = CallControllerToastContainerNode(strings: self.presentationData.strings)
        self.keyButtonNode = CallControllerKeyButton()
        self.keyButtonNode.accessibilityElementsHidden = false
        
        super.init()
        
        self.containerNode.backgroundColor = .black
        
        self.addSubnode(self.containerTransformationNode)
        self.containerTransformationNode.addSubnode(self.containerNode)
        
        self.backButtonNode.setTitle(presentationData.strings.Common_Back, with: Font.regular(17.0), with: .white, for: [])
        self.backButtonNode.accessibilityLabel = presentationData.strings.Call_VoiceOver_Minimize
        self.backButtonNode.accessibilityTraits = [.button]
        self.backButtonNode.hitTestSlop = UIEdgeInsets(top: -8.0, left: -20.0, bottom: -8.0, right: -8.0)
        self.backButtonNode.highligthedChanged = { [weak self] highlighted in
            if let strongSelf = self {
                if highlighted {
                    strongSelf.backButtonNode.layer.removeAnimation(forKey: "opacity")
                    strongSelf.backButtonArrowNode.layer.removeAnimation(forKey: "opacity")
                    strongSelf.backButtonNode.alpha = 0.4
                    strongSelf.backButtonArrowNode.alpha = 0.4
                } else {
                    strongSelf.backButtonNode.alpha = 1.0
                    strongSelf.backButtonArrowNode.alpha = 1.0
                    strongSelf.backButtonNode.layer.animateAlpha(from: 0.4, to: 1.0, duration: 0.2)
                    strongSelf.backButtonArrowNode.layer.animateAlpha(from: 0.4, to: 1.0, duration: 0.2)
                }
            }
        }
        
        self.blobNode.setColor(.white)
        self.containerNode.addSubnode(self.animatedGradientNode)
        self.containerNode.addSubnode(self.blobNode)
        self.containerNode.addSubnode(self.avatarNode)
        self.containerNode.addSubnode(self.hintNode)
        self.containerNode.addSubnode(self.videoContainerNode)
        self.containerNode.addSubnode(self.statusNode)
        self.containerNode.addSubnode(self.buttonsNode)
        self.containerNode.addSubnode(self.toastNode)
        self.containerNode.addSubnode(self.keyButtonNode)
        self.containerNode.addSubnode(self.backButtonArrowNode)
        self.containerNode.addSubnode(self.backButtonNode)
        self.containerNode.addSubnode(self.closeCallButtonNode)
        self.containerNode.addSubnode(self.encryptionDescHintNode)
        
        self.buttonsNode.mute = { [weak self] in
            self?.toggleMute?()
            self?.cancelScheduledUIHiding()
        }
        
        self.buttonsNode.speaker = { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.beginAudioOuputSelection?(strongSelf.hasVideoNodes)
            strongSelf.cancelScheduledUIHiding()
        }
                
        self.buttonsNode.acceptOrEnd = { [weak self] in
            guard let strongSelf = self, let callState = strongSelf.callState else {
                return
            }
            switch callState.state {
            case .active, .connecting, .reconnecting:
                strongSelf.endCall?()
                strongSelf.cancelScheduledUIHiding()
            case .requesting:
                strongSelf.endCall?()
            case .ringing:
                strongSelf.acceptCall?()
            default:
                break
            }
        }
        
        self.buttonsNode.decline = { [weak self] in
            self?.endCall?()
        }
        
        self.buttonsNode.toggleVideo = { [weak self] in
            guard let strongSelf = self, let callState = strongSelf.callState else {
                return
            }
            switch callState.state {
            case .active:
                var isScreencastActive = false
                switch callState.videoState {
                case .active(true), .paused(true):
                    isScreencastActive = true
                default:
                    break
                }

                if isScreencastActive {
                    (strongSelf.call as! PresentationCallImpl).disableScreencast()
                } else if strongSelf.outgoingVideoNodeValue == nil {
                    DeviceAccess.authorizeAccess(to: .camera(.videoCall), onlyCheck: true, presentationData: strongSelf.presentationData, present: { [weak self] c, a in
                        if let strongSelf = self {
                            strongSelf.present?(c)
                        }
                    }, openSettings: { [weak self] in
                        self?.sharedContext.applicationBindings.openSettings()
                    }, _: { [weak self] ready in
                        guard let strongSelf = self, ready else {
                            return
                        }
                        let proceed = {
                            strongSelf.displayedCameraConfirmation = true
                            switch callState.videoState {
                            case .inactive:
                                strongSelf.isRequestingVideo = true
                                strongSelf.updateButtonsMode()
                            default:
                                break
                            }
                            strongSelf.call.requestVideo()
                        }
                        
                        strongSelf.call.makeOutgoingVideoView(completion: { [weak self] outgoingVideoView in
                            guard let strongSelf = self else {
                                return
                            }
                            
                            if let outgoingVideoView = outgoingVideoView {
                                outgoingVideoView.view.backgroundColor = .black
                                outgoingVideoView.view.clipsToBounds = true
                                
                                var updateLayoutImpl: ((ContainerViewLayout, CGFloat) -> Void)?
                                
                                let outgoingVideoNode = CallVideoNode(videoView: outgoingVideoView, disabledText: nil, assumeReadyAfterTimeout: true, isReadyUpdated: {
                                    guard let strongSelf = self, let (layout, navigationBarHeight) = strongSelf.validLayout else {
                                        return
                                    }
                                    updateLayoutImpl?(layout, navigationBarHeight)
                                }, orientationUpdated: {
                                    guard let strongSelf = self, let (layout, navigationBarHeight) = strongSelf.validLayout else {
                                        return
                                    }
                                    updateLayoutImpl?(layout, navigationBarHeight)
                                }, isFlippedUpdated: { _ in
                                    guard let strongSelf = self, let (layout, navigationBarHeight) = strongSelf.validLayout else {
                                        return
                                    }
                                    updateLayoutImpl?(layout, navigationBarHeight)
                                })
                                
                                let controller = VoiceChatCameraPreviewController(sharedContext: strongSelf.sharedContext, cameraNode: outgoingVideoNode, shareCamera: { _, _ in
                                    proceed()
                                }, switchCamera: { [weak self] in
                                    Queue.mainQueue().after(0.1) {
                                        self?.call.switchVideoCamera()
                                    }
                                })
                                strongSelf.present?(controller)
                                
                                updateLayoutImpl = { [weak controller] layout, navigationBarHeight in
                                    controller?.containerLayoutUpdated(layout, transition: .immediate)
                                }
                            }
                        })
                    })
                } else {
                    strongSelf.call.disableVideo()
                    strongSelf.cancelScheduledUIHiding()
                }
            default:
                break
            }
        }
        
        self.buttonsNode.rotateCamera = { [weak self] in
            guard let strongSelf = self, !strongSelf.areUserActionsDisabledNow() else {
                return
            }
            strongSelf.disableActionsUntilTimestamp = CACurrentMediaTime() + 1.0
            if let outgoingVideoNode = strongSelf.outgoingVideoNodeValue {
                outgoingVideoNode.flip(withBackground: outgoingVideoNode !== strongSelf.minimizedVideoNode)
            }
            strongSelf.call.switchVideoCamera()
            if let _ = strongSelf.outgoingVideoNodeValue {
                if let (layout, navigationBarHeight) = strongSelf.validLayout {
                    strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
                }
            }
            strongSelf.cancelScheduledUIHiding()
        }
        
        self.keyButtonNode.addTarget(self, action: #selector(self.keyPressed), forControlEvents: .touchUpInside)
        
        self.backButtonNode.addTarget(self, action: #selector(self.backPressed), forControlEvents: .touchUpInside)
        self.closeCallButtonNode.addTarget(self, action: #selector(self.didPressDismiss), forControlEvents: .touchUpInside)
        self.closeCallButtonNode.isHidden = true

        if shouldStayHiddenUntilConnection {
            self.containerNode.alpha = 0.0
            Queue.mainQueue().after(3.0, { [weak self] in
                self?.containerNode.alpha = 1.0
                self?.animateIn()
            })
        } else if call.isVideo && call.isOutgoing {
            self.containerNode.alpha = 0.0
            Queue.mainQueue().after(1.0, { [weak self] in
                self?.containerNode.alpha = 1.0
                self?.animateIn()
            })
        }
        
        self.orientationDidChangeObserver = NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: nil, using: { [weak self] _ in
            guard let strongSelf = self else {
                return
            }
            let deviceOrientation = UIDevice.current.orientation
            if strongSelf.deviceOrientation != deviceOrientation {
                strongSelf.deviceOrientation = deviceOrientation
                if let (layout, navigationBarHeight) = strongSelf.validLayout {
                    strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.3, curve: .easeInOut))
                }
            }
        })
        
        self.videoContainerNode.activate = { [weak self] sourceNode in
            guard let strongSelf = self else {
                return
            }
            let pinchController = PinchController(sourceNode: sourceNode, getContentAreaInScreenSpace: {
                return UIScreen.main.bounds
            })
            strongSelf.sharedContext.mainWindow?.presentInGlobalOverlay(pinchController)
            strongSelf.isVideoPinched = true
            
            strongSelf.videoContainerNode.contentNode.clipsToBounds = true
            strongSelf.videoContainerNode.backgroundColor = .black
            
            if let (layout, navigationBarHeight) = strongSelf.validLayout {
                strongSelf.videoContainerNode.contentNode.cornerRadius = layout.deviceMetrics.screenCornerRadius
                
                strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
            }
        }
        
        self.videoContainerNode.animatedOut = { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.isVideoPinched = false
            
            strongSelf.videoContainerNode.backgroundColor = .clear
            strongSelf.videoContainerNode.contentNode.cornerRadius = 0.0
            
            if let (layout, navigationBarHeight) = strongSelf.validLayout {
                strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.3, curve: .easeInOut))
            }
        }
        
        self.audioLevelDisposable.set((call.audioLevel
        |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let strongSelf = self, !strongSelf.dismissedButtons else {
                return
            }

            guard strongSelf.startCallAnimationShow else { return }

            strongSelf.blobNode.updateLevel(CGFloat(value) * 2.0)
            if value > 0.0 {
                strongSelf.blobNode.startAnimating()
            } else {
                strongSelf.blobNode.stopAnimating(duration: 0.5)
            }
        }))
    }
    
    func showEndCallUI() {
        self.dismissedButtons = true
        self.closeCallButtonNode.isHidden = false
        self.buttonsNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false)
        self.closeCallButtonNode.animate()
        self.dismissAllHints()
    }
    
    private func dismissAllHints() {
        startCallAnimationShow = false
        blobNode.updateLevel(0.0)
        blobNode.layer.animateScale(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false)
        hintNode.animateOut()
        encryptionDescHintNode.animateOut()
        keyPreviewNode?.animateOut(to: keyButtonNode.frame, toNode: keyButtonNode) { [weak self] _ in
            self?.keyPreviewNode?.removeFromSupernode()
        }
    }
    
    @objc func didPressDismiss() {
        guard !callDismissed else { return }
        callDismissed = true
        call.dismissCallScreen()
    }
    
    deinit {
        if let orientationDidChangeObserver = self.orientationDidChangeObserver {
            NotificationCenter.default.removeObserver(orientationDidChangeObserver)
        }
    }
    
    func displayCameraTooltip() {
        guard self.pictureInPictureTransitionFraction.isZero, let location = self.buttonsNode.videoButtonFrame().flatMap({ frame -> CGRect in
            return self.buttonsNode.view.convert(frame, to: self.view)
        }) else {
            return
        }
                
        self.present?(TooltipScreen(account: self.account, text: self.presentationData.strings.Call_CameraOrScreenTooltip, style: .light, icon: nil, location: .point(location.offsetBy(dx: 0.0, dy: -14.0), .bottom), displayDuration: .custom(5.0), shouldDismissOnTouch: { _ in
            return .dismiss(consume: false)
        }))
    }
    
    override func didLoad() {
        super.didLoad()
        let panRecognizer = CallPanGestureRecognizer(target: self, action: #selector(self.panGesture(_:)))
        panRecognizer.shouldBegin = { [weak self] _ in
            guard let strongSelf = self else {
                return false
            }
            if strongSelf.areUserActionsDisabledNow() {
                return false
            }
            return true
        }
        self.view.addGestureRecognizer(panRecognizer)
        
        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:)))
        self.view.addGestureRecognizer(tapRecognizer)
        let animatedView = AnimatedGradientView(
            frame: UIScreen.main.bounds,
            colorPallete: .connecting,
            animationTime: 1
        )
        animatedGradientNode.view.addSubview(animatedView)
        animatedView.setup()
        self.gradientView = animatedView
        blobNode.startAnimating()
        blobNode.updateLevel(0.8)
        animateWaitingAvatarAndBlob(isBig: true)
        encryptionDescHintNode.addTarget(self, action: #selector(self.hideEncryption), forControlEvents: .touchUpInside)
        
        let notificationName = Notification.Name(rawValue: "UIDeviceProximityStateDidChangeNotification")
        NotificationCenter.default.addObserver(self, selector: #selector(proximityStateDidChange), name: notificationName, object: nil)
        
        setupTimer()
    }
     
    func resumeAnimations() {
        gradientView?.resume()
    }
    
    func pauseAnimations() {
        gradientView?.pause()
    }
    
    private func setupTimer() {
        self.touchTimer = nil
        let timer = SwiftSignalKit.Timer(timeout: 5, repeat: false, completion: { [weak self] in
            self?.gradientView?.pause()
        }, queue: Queue.mainQueue())
        self.touchTimer = timer
        timer.start()
    }
    
    @objc private func proximityStateDidChange(notification: Notification) {
        if let device = notification.object as? UIDevice {
            
            let currentProximityState = device.proximityState
            if currentProximityState {
                gradientView?.pause()
            } else {
                gradientView?.resume()
            }
        }
    }
    
    @objc private func hideEncryption() {
        encryptionDescHintNode.animateOut()
    }
    
    func updatePeer(accountPeer: Peer, peer: Peer, hasOther: Bool) {
        if !arePeersEqual(self.peer, peer) {
            self.peer = peer

            self.avatarNode.setPeer(context: self.call.context, theme: presentationData.theme, peer: EnginePeer(peer), overrideImage: nil, clipStyle: .round, synchronousLoad: true, displayDimensions: CGSize(width: 136, height: 136), storeUnrounded: true)
                        
            self.toastNode.title = EnginePeer(peer).compactDisplayTitle
            self.statusNode.title = EnginePeer(peer).displayTitle(strings: self.presentationData.strings, displayOrder: self.presentationData.nameDisplayOrder)
            if hasOther {
                self.statusNode.subtitle = self.presentationData.strings.Call_AnsweringWithAccount(EnginePeer(accountPeer).displayTitle(strings: self.presentationData.strings, displayOrder: self.presentationData.nameDisplayOrder)).string
                
                if let callState = self.callState {
                    self.updateCallState(callState)
                }
            }
            
            if let (layout, navigationBarHeight) = self.validLayout {
                self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
            }
        }
    }
    
    func updateAudioOutputs(availableOutputs: [AudioSessionOutput], currentOutput: AudioSessionOutput?) {
        if self.audioOutputState?.0 != availableOutputs || self.audioOutputState?.1 != currentOutput {
            self.audioOutputState = (availableOutputs, currentOutput)
            self.updateButtonsMode()
            
            self.setupAudioOutputs()
        }
    }
    
    private func setupAudioOutputs() {
        if self.outgoingVideoNodeValue != nil || self.incomingVideoNodeValue != nil || self.candidateOutgoingVideoNodeValue != nil || self.candidateIncomingVideoNodeValue != nil {
            if let audioOutputState = self.audioOutputState, let currentOutput = audioOutputState.currentOutput {
                switch currentOutput {
                case .headphones, .speaker:
                    break
                case let .port(port) where port.type == .bluetooth || port.type == .wired:
                    break
                default:
                    self.setCurrentAudioOutput?(.speaker)
                }
            }
        }
    }
    
    func updateCallState(_ callState: PresentationCallState) {
        self.callState = callState
        
        let statusValue: CallControllerStatusValue
        var statusReception: Int32?
        
        switch callState.remoteVideoState {
        case .active, .paused:
            if !self.incomingVideoViewRequested {
                self.incomingVideoViewRequested = true
                let delayUntilInitialized = true
                self.call.makeIncomingVideoView(completion: { [weak self] incomingVideoView in
                    guard let strongSelf = self else {
                        return
                    }
                    if let incomingVideoView = incomingVideoView {
                        incomingVideoView.view.backgroundColor = .black
                        incomingVideoView.view.clipsToBounds = true
                        
                        let applyNode: () -> Void = {
                            guard let strongSelf = self, let incomingVideoNode = strongSelf.candidateIncomingVideoNodeValue else {
                                return
                            }
                            strongSelf.candidateIncomingVideoNodeValue = nil
                            
                            strongSelf.incomingVideoNodeValue = incomingVideoNode
                            if let expandedVideoNode = strongSelf.expandedVideoNode {
                                strongSelf.minimizedVideoNode = expandedVideoNode
                                strongSelf.videoContainerNode.contentNode.insertSubnode(incomingVideoNode, belowSubnode: expandedVideoNode)
                            } else {
                                strongSelf.videoContainerNode.contentNode.addSubnode(incomingVideoNode)
                            }
                            strongSelf.expandedVideoNode = incomingVideoNode
                            strongSelf.updateButtonsMode(transition: .animated(duration: 0.4, curve: .spring))
                            
                            strongSelf.updateDimVisibility()
                            strongSelf.maybeScheduleUIHidingForActiveVideoCall()
                        }
                        
                        let incomingVideoNode = CallVideoNode(videoView: incomingVideoView, disabledText: strongSelf.presentationData.strings.Call_RemoteVideoPaused(strongSelf.peer.flatMap(EnginePeer.init)?.compactDisplayTitle ?? "").string, assumeReadyAfterTimeout: false, isReadyUpdated: {
                            if delayUntilInitialized {
                                Queue.mainQueue().after(0.1, {
                                    applyNode()
                                })
                            }
                        }, orientationUpdated: {
                            guard let strongSelf = self else {
                                return
                            }
                            if let (layout, navigationBarHeight) = strongSelf.validLayout {
                                strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.3, curve: .easeInOut))
                            }
                        }, isFlippedUpdated: { _ in
                        })
                        strongSelf.candidateIncomingVideoNodeValue = incomingVideoNode
                        strongSelf.setupAudioOutputs()
                        
                        if !delayUntilInitialized {
                            applyNode()
                        }
                    }
                })
            }
        case .inactive:
            self.candidateIncomingVideoNodeValue = nil
            if let incomingVideoNodeValue = self.incomingVideoNodeValue {
                if self.minimizedVideoNode == incomingVideoNodeValue {
                    self.minimizedVideoNode = nil
                    self.removedMinimizedVideoNodeValue = incomingVideoNodeValue
                }
                if self.expandedVideoNode == incomingVideoNodeValue {
                    self.expandedVideoNode = nil
                    self.removedExpandedVideoNodeValue = incomingVideoNodeValue
                    
                    if let minimizedVideoNode = self.minimizedVideoNode {
                        self.expandedVideoNode = minimizedVideoNode
                        self.minimizedVideoNode = nil
                    }
                }
                self.incomingVideoNodeValue = nil
                self.incomingVideoViewRequested = false
            }
        }
        
        switch callState.videoState {
        case .active(false), .paused(false):
            if !self.outgoingVideoViewRequested {
                self.outgoingVideoViewRequested = true
                let delayUntilInitialized = self.isRequestingVideo
                self.call.makeOutgoingVideoView(completion: { [weak self] outgoingVideoView in
                    guard let strongSelf = self else {
                        return
                    }
                    
                    if let outgoingVideoView = outgoingVideoView {
                        outgoingVideoView.view.backgroundColor = .black
                        outgoingVideoView.view.clipsToBounds = true
                        
                        let applyNode: () -> Void = {
                            guard let strongSelf = self, let outgoingVideoNode = strongSelf.candidateOutgoingVideoNodeValue else {
                                return
                            }
                            strongSelf.candidateOutgoingVideoNodeValue = nil
                            
                            if strongSelf.isRequestingVideo {
                                strongSelf.isRequestingVideo = false
                                strongSelf.animateRequestedVideoOnce = true
                            }
                            
                            strongSelf.outgoingVideoNodeValue = outgoingVideoNode
                            if let expandedVideoNode = strongSelf.expandedVideoNode {
                                strongSelf.minimizedVideoNode = outgoingVideoNode
                                strongSelf.videoContainerNode.contentNode.insertSubnode(outgoingVideoNode, aboveSubnode: expandedVideoNode)
                            } else {
                                strongSelf.expandedVideoNode = outgoingVideoNode
                                strongSelf.videoContainerNode.contentNode.addSubnode(outgoingVideoNode)
                            }
                            strongSelf.updateButtonsMode(transition: .animated(duration: 0.4, curve: .spring))
                            
                            strongSelf.updateDimVisibility()
                            strongSelf.maybeScheduleUIHidingForActiveVideoCall()
                        }
                        
                        let outgoingVideoNode = CallVideoNode(videoView: outgoingVideoView, disabledText: nil, assumeReadyAfterTimeout: true, isReadyUpdated: {
                            if delayUntilInitialized {
                                Queue.mainQueue().after(0.4, {
                                    applyNode()
                                })
                            }
                        }, orientationUpdated: {
                            guard let strongSelf = self else {
                                return
                            }
                            if let (layout, navigationBarHeight) = strongSelf.validLayout {
                                strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.3, curve: .easeInOut))
                            }
                        }, isFlippedUpdated: { videoNode in
                            guard let _ = self else {
                                return
                            }
                            /*if videoNode === strongSelf.minimizedVideoNode, let tempView = videoNode.view.snapshotView(afterScreenUpdates: true) {
                                videoNode.view.superview?.insertSubview(tempView, aboveSubview: videoNode.view)
                                videoNode.view.frame = videoNode.frame
                                let transitionOptions: UIView.AnimationOptions = [.transitionFlipFromRight, .showHideTransitionViews]

                                UIView.transition(with: tempView, duration: 1.0, options: transitionOptions, animations: {
                                    tempView.isHidden = true
                                }, completion: { [weak tempView] _ in
                                    tempView?.removeFromSuperview()
                                })

                                videoNode.view.isHidden = true
                                UIView.transition(with: videoNode.view, duration: 1.0, options: transitionOptions, animations: {
                                    videoNode.view.isHidden = false
                                })
                            }*/
                        })
                        
                        strongSelf.candidateOutgoingVideoNodeValue = outgoingVideoNode
                        strongSelf.setupAudioOutputs()
                        
                        if !delayUntilInitialized {
                            applyNode()
                        }
                    }
                })
            }
        default:
            self.candidateOutgoingVideoNodeValue = nil
            if let outgoingVideoNodeValue = self.outgoingVideoNodeValue {
                if self.minimizedVideoNode == outgoingVideoNodeValue {
                    self.minimizedVideoNode = nil
                    self.removedMinimizedVideoNodeValue = outgoingVideoNodeValue
                }
                if self.expandedVideoNode == self.outgoingVideoNodeValue {
                    self.expandedVideoNode = nil
                    self.removedExpandedVideoNodeValue = outgoingVideoNodeValue
                    
                    if let minimizedVideoNode = self.minimizedVideoNode {
                        self.expandedVideoNode = minimizedVideoNode
                        self.minimizedVideoNode = nil
                    }
                }
                self.outgoingVideoNodeValue = nil
                self.outgoingVideoViewRequested = false
            }
        }
        
        if let incomingVideoNode = self.incomingVideoNodeValue {
            switch callState.state {
            case .terminating, .terminated:
                break
            default:
                let isActive: Bool
                switch callState.remoteVideoState {
                case .inactive, .paused:
                    isActive = false
                case .active:
                    isActive = true
                }
                incomingVideoNode.updateIsBlurred(isBlurred: !isActive)
            }
        }
        
        switch callState.state {
            case .waiting, .connecting:
                gradientView?.change(pallete: .connecting)
                statusValue = .text(string: self.presentationData.strings.Call_StatusConnecting, displayLogo: nil)
            case let .requesting(ringing):
                gradientView?.change(pallete: .connecting)
                if ringing {
                    statusValue = .text(string: self.presentationData.strings.Call_StatusRinging, displayLogo: nil)
                } else {
                    statusValue = .text(string: self.presentationData.strings.Call_StatusRequesting, displayLogo: nil)
                }
            case .terminating:
                dismissAllHints()
                self.statusNode.title = self.presentationData.strings.Call_StatusEnded
                if let cachedCallTimestampString {
                    statusValue = .text(
                        string: cachedCallTimestampString,
                        displayLogo: generateTintedImage(image: UIImage(bundleImageName: "Call/CallDeclineButton"), color: .white))
                } else {
                    let callDuration = callDurationString(from: cachedCallTimestamp)
                    self.cachedCallTimestampString = callDuration
                    statusValue = .text(
                        string: callDuration ?? "",
                        displayLogo: callDuration != nil ? generateTintedImage(image: UIImage(bundleImageName: "Call/CallDeclineButton"), color: .white) : nil)
                }
            case let .terminated(_, reason, _):
                dismissAllHints()
                if let reason = reason {
                    switch reason {
                        case let .ended(type):
                            switch type {
                                case .busy:
                                    statusValue = .text(string: self.presentationData.strings.Call_StatusBusy, displayLogo: nil)
                                case .hungUp, .missed:
                                	self.statusNode.title = self.presentationData.strings.Call_StatusEnded
                                    if let cachedCallTimestampString {
                                        statusValue = .text(
                                            string: cachedCallTimestampString,
                                            displayLogo: generateTintedImage(image: UIImage(bundleImageName: "Call/CallDeclineButton"), color: .white))
                                    } else {
                                        let callDuration = callDurationString(from: cachedCallTimestamp)
                                        self.cachedCallTimestampString = callDuration
                                        statusValue = .text(
                                            string: callDuration ?? "",
                                            displayLogo: callDuration != nil ? generateTintedImage(image: UIImage(bundleImageName: "Call/CallDeclineButton"), color: .white) : nil)
                                    }
                            }
                        case let .error(error):
                            let text = self.presentationData.strings.Call_StatusFailed
                            switch error {
                            case let .notSupportedByPeer(isVideo):
                                if !self.displayedVersionOutdatedAlert, let peer = self.peer {
                                    self.displayedVersionOutdatedAlert = true
                                    
                                    let text: String
                                    if isVideo {
                                        text = self.presentationData.strings.Call_ParticipantVideoVersionOutdatedError(EnginePeer(peer).displayTitle(strings: self.presentationData.strings, displayOrder: self.presentationData.nameDisplayOrder)).string
                                    } else {
                                        text = self.presentationData.strings.Call_ParticipantVersionOutdatedError(EnginePeer(peer).displayTitle(strings: self.presentationData.strings, displayOrder: self.presentationData.nameDisplayOrder)).string
                                    }
                                    
                                    self.present?(textAlertController(sharedContext: self.sharedContext, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Common_OK, action: {
                                    })]))
                                }
                            default:
                                break
                            }
                            statusValue = .text(string: text, displayLogo: nil)
                    }
                } else {
                    self.statusNode.title = self.presentationData.strings.Call_StatusEnded
                    if let cachedCallTimestampString {
                        statusValue = .text(
                            string: cachedCallTimestampString,
                            displayLogo: generateTintedImage(image: UIImage(bundleImageName: "Call/CallDeclineButton"), color: .white))
                    } else {
                        let callDuration = callDurationString(from: cachedCallTimestamp)
                        self.cachedCallTimestampString = callDuration
                        statusValue = .text(
                            string: callDuration ?? "",
                            displayLogo: callDuration != nil ? generateTintedImage(image: UIImage(bundleImageName: "Call/CallDeclineButton"), color: .white) : nil)
                    }
                }
            case .ringing:
                gradientView?.change(pallete: .connecting)
                var text: String
                if self.call.isVideo {
                    text = self.presentationData.strings.Call_IncomingVideoCall
                } else {
                    text = self.presentationData.strings.Call_IncomingVoiceCall
                }
                if !self.statusNode.subtitle.isEmpty {
                    text += "\n\(self.statusNode.subtitle)"
                }
                statusValue = .text(string: text, displayLogo: nil)
            case .active(let timestamp, let reception, let keyVisualHash), .reconnecting(let timestamp, let reception, let keyVisualHash):
                self.cachedCallTimestamp = timestamp
                let strings = self.presentationData.strings
                var isReconnecting = false
                if case .reconnecting = callState.state {
                    isReconnecting = true
                }
                if self.keyTextData?.0 != keyVisualHash {
                    let text = stringForEmojiHashOfData(keyVisualHash, 4)!
                    self.keyTextData = (keyVisualHash, text)

                    self.keyButtonNode.key = text
                    
                    let keyTextSize = self.keyButtonNode.measure(CGSize(width: 200.0, height: 200.0))
                    self.keyButtonNode.frame = CGRect(origin: self.keyButtonNode.frame.origin, size: keyTextSize)
                    
                    self.keyButtonNode.animateIn(rect: .zero)
                    
                    if !UserDefaults.standard.bool(forKey: "TG_encryption_description_presented") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                            guard let self else { return }
                            self.encryptionDescHintNode.animateIn()
                            self.encryptionDescHintNode.layer.animatePosition(from: CGPoint(x: self.keyButtonNode.frame.midX, y: self.keyButtonNode.frame.midY), to: self.encryptionDescHintNode.layer.position, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring)
                        }
                    }
                    
                    if let (layout, navigationBarHeight) = self.validLayout {
                        self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
                    }
                }
                
                statusValue = .timer({ value, measure in
                    if isReconnecting || (self.outgoingVideoViewRequested && value == "00:00" && !measure) {
                        return strings.Call_StatusConnecting
                    } else {
                        return value
                    }
                }, timestamp)
                if case .active = callState.state {
                    statusReception = reception
                }
                if let statusReception, statusReception == 0 {
                    gradientView?.change(pallete: .weakSignal)
                    hintNode.show()
                } else if !isReconnecting {
                    self.shouldAnimateAvatar = false
                    self.animateStartingCall()
                    gradientView?.change(pallete: .connected)
                    hintNode.hide()
                }
        }
        if self.shouldStayHiddenUntilConnection {
            switch callState.state {
                case .connecting, .active:
                    self.containerNode.alpha = 1.0
                default:
                    break
            }
        }
        self.statusNode.status = statusValue
        self.statusNode.reception = statusReception
        
        if let callState = self.callState {
            switch callState.state {
            case .active, .connecting, .reconnecting:
                break
            default:
                self.isUIHidden = false
            }
        }
        
        self.updateToastContent()
        self.updateButtonsMode()
        self.updateDimVisibility()
        
        if self.incomingVideoViewRequested || self.outgoingVideoViewRequested {
            if self.incomingVideoViewRequested && self.outgoingVideoViewRequested {
                self.displayedCameraTooltip = true
            }
            self.displayedCameraConfirmation = true
        }
        if self.incomingVideoViewRequested && !self.outgoingVideoViewRequested && !self.displayedCameraTooltip && (self.toastContent?.isEmpty ?? true) {
            self.displayedCameraTooltip = true
            Queue.mainQueue().after(2.0) {
                self.displayCameraTooltip()
            }
        }
        
        if case let .terminated(id, _, reportRating) = callState.state, let callId = id {
            let presentRating = reportRating || self.forceReportRating
            if presentRating {
                self.showCallRating(callId: callId, isVideo: self.call.isVideo)
            } else {
                self.call.dismissCallScreen()
            }
            self.callEnded?(presentRating)
        }
        
        let hasIncomingVideoNode = self.incomingVideoNodeValue != nil && self.expandedVideoNode === self.incomingVideoNodeValue
        self.videoContainerNode.isPinchGestureEnabled = hasIncomingVideoNode
    }
    
    private func showCallRating(callId: CallId, isVideo: Bool) {
        guard self.ratingNode == nil else { return }
        self.showEndCallUI()
        self.gradientView?.change(pallete: .connecting)
        self.keyButtonNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false)
        self.toastNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false)
        self.ratingNode = CallRatingNode(presentationData: self.presentationData)
        self.ratingNode?.alpha = 0.0
        self.containerNode.addSubnode(self.ratingNode!)
        if let (layout, navigationBarHeight) = self.validLayout {
            self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.3, curve: .easeInOut))
        }
        self.ratingNode?.onSelect = { [weak self] rating in
            guard let self else { return }
            let _ = rateCallAndSendLogs(engine: TelegramEngine(account: self.account), callId: callId, starsCount: rating, comment: "", userInitiated: false, includeLogs: false).start()
        }
    }
    
    private func updateToastContent() {
        guard let callState = self.callState else {
            return
        }
        if case .terminating = callState.state {
        } else if case .terminated = callState.state {
        } else {
            var toastContent: CallControllerToastContent = []
            if case .active = callState.state {
                if let displayToastsAfterTimestamp = self.displayToastsAfterTimestamp {
                    if CACurrentMediaTime() > displayToastsAfterTimestamp {
                        if case .inactive = callState.remoteVideoState, self.hasVideoNodes {
                            toastContent.insert(.camera)
                        }
                        if case .muted = callState.remoteAudioState {
                            toastContent.insert(.microphone)
                        }
                        if case .low = callState.remoteBatteryLevel {
                            toastContent.insert(.battery)
                        }
                    }
                } else {
                    self.displayToastsAfterTimestamp = CACurrentMediaTime() + 1.5
                }
            }
            if self.isMuted, let (availableOutputs, _) = self.audioOutputState, availableOutputs.count > 2 {
                toastContent.insert(.mute)
            }
            self.toastContent = toastContent
        }
    }
    
    private func updateDimVisibility(transition: ContainedViewLayoutTransition = .animated(duration: 0.3, curve: .easeInOut)) {
        guard let callState = self.callState else {
            return
        }
        
        var visible = true
        if case .active = callState.state, self.incomingVideoNodeValue != nil || self.outgoingVideoNodeValue != nil {
            visible = false
        }

        self.statusNode.setVisible(visible || self.keyPreviewNode != nil, transition: transition)
    }
    
    private func maybeScheduleUIHidingForActiveVideoCall() {
        guard let callState = self.callState, case .active = callState.state, self.incomingVideoNodeValue != nil && self.outgoingVideoNodeValue != nil, !self.hiddenUIForActiveVideoCallOnce && self.keyPreviewNode == nil else {
            return
        }
        
        let timer = SwiftSignalKit.Timer(timeout: 3.0, repeat: false, completion: { [weak self] in
            if let strongSelf = self {
                var updated = false
                if let callState = strongSelf.callState, !strongSelf.isUIHidden {
                    switch callState.state {
                        case .active, .connecting, .reconnecting:
                            strongSelf.isUIHidden = true
                            updated = true
                        default:
                            break
                    }
                }
                if updated, let (layout, navigationBarHeight) = strongSelf.validLayout {
                    strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.3, curve: .easeInOut))
                }
                strongSelf.hideUIForActiveVideoCallTimer = nil
            }
        }, queue: Queue.mainQueue())
        timer.start()
        self.hideUIForActiveVideoCallTimer = timer
        self.hiddenUIForActiveVideoCallOnce = true
    }
    
    private func cancelScheduledUIHiding() {
        self.hideUIForActiveVideoCallTimer?.invalidate()
        self.hideUIForActiveVideoCallTimer = nil
    }
    
    private var buttonsTerminationMode: CallControllerButtonsMode?
    
    private func updateButtonsMode(transition: ContainedViewLayoutTransition = .animated(duration: 0.3, curve: .spring)) {
        guard let callState = self.callState else {
            return
        }
        
        var mode: CallControllerButtonsSpeakerMode = .none
        var hasAudioRouteMenu: Bool = false
        if let (availableOutputs, maybeCurrentOutput) = self.audioOutputState, let currentOutput = maybeCurrentOutput {
            hasAudioRouteMenu = availableOutputs.count > 2
            switch currentOutput {
                case .builtin:
                    mode = .builtin
                case .speaker:
                    mode = .speaker
                case .headphones:
                    mode = .headphones
                case let .port(port):
                    var type: CallControllerButtonsSpeakerMode.BluetoothType = .generic
                    let portName = port.name.lowercased()
                    if portName.contains("airpods pro") {
                        type = .airpodsPro
                    } else if portName.contains("airpods") {
                        type = .airpods
                    }
                    mode = .bluetooth(type)
            }
            if availableOutputs.count <= 1 {
                mode = .none
            }
        }
        var mappedVideoState = CallControllerButtonsMode.VideoState(isAvailable: false, isCameraActive: self.outgoingVideoNodeValue != nil, isScreencastActive: false, canChangeStatus: false, hasVideo: self.outgoingVideoNodeValue != nil || self.incomingVideoNodeValue != nil, isInitializingCamera: self.isRequestingVideo)
        switch callState.videoState {
        case .notAvailable:
            break
        case .inactive:
            mappedVideoState.isAvailable = true
            mappedVideoState.canChangeStatus = true
        case .active(let isScreencast), .paused(let isScreencast):
            mappedVideoState.isAvailable = true
            mappedVideoState.canChangeStatus = true
            if isScreencast {
                mappedVideoState.isScreencastActive = true
                mappedVideoState.hasVideo = true
            }
        }
        
        switch callState.state {
        case .ringing:
            self.buttonsMode = .incoming(speakerMode: mode, hasAudioRouteMenu: hasAudioRouteMenu, videoState: mappedVideoState)
            self.buttonsTerminationMode = buttonsMode
        case .waiting, .requesting:
            self.buttonsMode = .outgoingRinging(speakerMode: mode, hasAudioRouteMenu: hasAudioRouteMenu, videoState: mappedVideoState)
            self.buttonsTerminationMode = buttonsMode
        case .active, .connecting, .reconnecting:
            self.buttonsMode = .active(speakerMode: mode, hasAudioRouteMenu: hasAudioRouteMenu, videoState: mappedVideoState)
            self.buttonsTerminationMode = buttonsMode
        case .terminating, .terminated:
            if let buttonsTerminationMode = self.buttonsTerminationMode {
                self.buttonsMode = buttonsTerminationMode
            } else {
                self.buttonsMode = .active(speakerMode: mode, hasAudioRouteMenu: hasAudioRouteMenu, videoState: mappedVideoState)
            }
        }
                
        if let (layout, navigationHeight) = self.validLayout {
            self.containerLayoutUpdated(layout, navigationBarHeight: navigationHeight, transition: transition)
        }
    }
    
    func animateIn() {
        if !self.containerNode.alpha.isZero {
            var bounds = self.bounds
            bounds.origin = CGPoint()
            self.bounds = bounds
            self.layer.removeAnimation(forKey: "bounds")
            self.statusBar.layer.removeAnimation(forKey: "opacity")
            self.containerNode.layer.removeAnimation(forKey: "opacity")
            self.containerNode.layer.removeAnimation(forKey: "scale")
            self.statusBar.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3)
            if !self.shouldStayHiddenUntilConnection {
                self.containerNode.layer.animateScale(from: 1.04, to: 1.0, duration: 0.3)
                self.containerNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
            }
        }
    }
    
    func animateOut(completion: @escaping () -> Void) {
        self.statusBar.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false)
        if !self.shouldStayHiddenUntilConnection || self.containerNode.alpha > 0.0 {
            self.containerNode.layer.allowsGroupOpacity = true
            self.containerNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false, completion: { [weak self] _ in
                self?.containerNode.layer.allowsGroupOpacity = false
            })
            self.containerNode.layer.animateScale(from: 1.0, to: 1.04, duration: 0.3, removeOnCompletion: false, completion: { _ in
                completion()
            })
        } else {
            completion()
        }
    }
    
    func expandFromPipIfPossible() {
        if self.pictureInPictureTransitionFraction.isEqual(to: 1.0), let (layout, navigationHeight) = self.validLayout {
            self.pictureInPictureTransitionFraction = 0.0
            
            self.containerLayoutUpdated(layout, navigationBarHeight: navigationHeight, transition: .animated(duration: 0.4, curve: .spring))
        }
    }
    
    private func calculatePreviewVideoRect(layout: ContainerViewLayout, navigationHeight: CGFloat) -> CGRect {
        let buttonsHeight: CGFloat = self.buttonsNode.bounds.height
        let toastHeight: CGFloat = self.toastNode.bounds.height
        let toastInset = (toastHeight > 0.0 ? toastHeight + 22.0 : 0.0)
        
        var fullInsets = layout.insets(options: .statusBar)
    
        var cleanInsets = fullInsets
        cleanInsets.bottom = max(layout.intrinsicInsets.bottom, 20.0) + toastInset
        cleanInsets.left = 20.0
        cleanInsets.right = 20.0
        
        fullInsets.top += 44.0 + 8.0
        fullInsets.bottom = buttonsHeight + 22.0 + toastInset
        fullInsets.left = 20.0
        fullInsets.right = 20.0
        
        var insets: UIEdgeInsets = self.isUIHidden ? cleanInsets : fullInsets
        
        let expandedInset: CGFloat = 16.0
        
        insets.top = interpolate(from: expandedInset, to: insets.top, value: 1.0 - self.pictureInPictureTransitionFraction)
        insets.bottom = interpolate(from: expandedInset, to: insets.bottom, value: 1.0 - self.pictureInPictureTransitionFraction)
        insets.left = interpolate(from: expandedInset, to: insets.left, value: 1.0 - self.pictureInPictureTransitionFraction)
        insets.right = interpolate(from: expandedInset, to: insets.right, value: 1.0 - self.pictureInPictureTransitionFraction)
        
        let previewVideoSide = interpolate(from: 300.0, to: 150.0, value: 1.0 - self.pictureInPictureTransitionFraction)
        var previewVideoSize = layout.size.aspectFitted(CGSize(width: previewVideoSide, height: previewVideoSide))
        previewVideoSize = CGSize(width: 30.0, height: 45.0).aspectFitted(previewVideoSize)
        if let minimizedVideoNode = self.minimizedVideoNode {
            var aspect = minimizedVideoNode.currentAspect
            var rotationCount = 0
            if minimizedVideoNode === self.outgoingVideoNodeValue {
                aspect = 3.0 / 4.0
            } else {
                if aspect < 1.0 {
                    aspect = 3.0 / 4.0
                } else {
                    aspect = 4.0 / 3.0
                }
                
                switch minimizedVideoNode.currentOrientation {
                case .rotation90, .rotation270:
                    rotationCount += 1
                default:
                    break
                }
                
                var mappedDeviceOrientation = self.deviceOrientation
                if case .regular = layout.metrics.widthClass, case .regular = layout.metrics.heightClass {
                    mappedDeviceOrientation = .portrait
                }
                
                switch mappedDeviceOrientation {
                case .landscapeLeft, .landscapeRight:
                    rotationCount += 1
                default:
                    break
                }
                
                if rotationCount % 2 != 0 {
                    aspect = 1.0 / aspect
                }
            }
            
            let unboundVideoSize = CGSize(width: aspect * 10000.0, height: 10000.0)
            
            previewVideoSize = unboundVideoSize.aspectFitted(CGSize(width: previewVideoSide, height: previewVideoSide))
        }
        let previewVideoY: CGFloat
        let previewVideoX: CGFloat
        
        switch self.outgoingVideoNodeCorner {
        case .topLeft:
            previewVideoX = insets.left
            previewVideoY = insets.top
        case .topRight:
            previewVideoX = layout.size.width - previewVideoSize.width - insets.right
            previewVideoY = insets.top
        case .bottomLeft:
            previewVideoX = insets.left
            previewVideoY = layout.size.height - insets.bottom - previewVideoSize.height
        case .bottomRight:
            previewVideoX = layout.size.width - previewVideoSize.width - insets.right
            previewVideoY = layout.size.height - insets.bottom - previewVideoSize.height
        }
        
        return CGRect(origin: CGPoint(x: previewVideoX, y: previewVideoY), size: previewVideoSize)
    }
    
    private func calculatePictureInPictureContainerRect(layout: ContainerViewLayout, navigationHeight: CGFloat) -> CGRect {
        let pictureInPictureTopInset: CGFloat = layout.insets(options: .statusBar).top + 44.0 + 8.0
        let pictureInPictureSideInset: CGFloat = 8.0
        let pictureInPictureSize = layout.size.fitted(CGSize(width: 240.0, height: 240.0))
        let pictureInPictureBottomInset: CGFloat = layout.insets(options: .input).bottom + 44.0 + 8.0
        
        let containerPictureInPictureFrame: CGRect
        switch self.pictureInPictureCorner {
        case .topLeft:
            containerPictureInPictureFrame = CGRect(origin: CGPoint(x: pictureInPictureSideInset, y: pictureInPictureTopInset), size: pictureInPictureSize)
        case .topRight:
            containerPictureInPictureFrame = CGRect(origin: CGPoint(x: layout.size.width -  pictureInPictureSideInset - pictureInPictureSize.width, y: pictureInPictureTopInset), size: pictureInPictureSize)
        case .bottomLeft:
            containerPictureInPictureFrame = CGRect(origin: CGPoint(x: pictureInPictureSideInset, y: layout.size.height - pictureInPictureBottomInset - pictureInPictureSize.height), size: pictureInPictureSize)
        case .bottomRight:
            containerPictureInPictureFrame = CGRect(origin: CGPoint(x: layout.size.width -  pictureInPictureSideInset - pictureInPictureSize.width, y: layout.size.height - pictureInPictureBottomInset - pictureInPictureSize.height), size: pictureInPictureSize)
        }
        return containerPictureInPictureFrame
    }
    
    var shouldAnimateAvatar = true
    var startCallAnimationShow = false
    
    private func animateStartingCall() {
        guard !startCallAnimationShow else { return }
        startCallAnimationShow = true
        
        blobNode.layer.animateScale(
            from: 1.0,
            to: 1.1,
            duration: 0.2,
            removeOnCompletion: false
        ) { [weak self] _ in
            self?.startCallAnimationShow = true
            self?.blobNode.layer.animateScale(
                from: 1.1,
                to: 1.0,
                duration: 0.2,
                removeOnCompletion: true
            )
        }
        
        avatarNode.layer.animateScale(
            from: 1.0,
            to: 1.1,
            duration: 0.2,
            removeOnCompletion: false
        ) { [weak self] _ in
            self?.avatarNode.layer.animateScale(
                from: 1.1,
                to: 1.0,
                duration: 0.2,
                removeOnCompletion: false
            )
        }
    }
    
    private func animateWaitingAvatarAndBlob(isBig: Bool) {
        guard shouldAnimateAvatar else {
            return
        }
        
        avatarNode.layer.animateScale(
            from: isBig ? 1.0 : 1.07,
            to: isBig ? 1.07 : 1.0,
            duration: 0.8,
            removeOnCompletion: false
        )
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.animateWaitingAvatarAndBlob(isBig: !isBig)
        }
    }
    
    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        self.validLayout = (layout, navigationBarHeight)
        
        var mappedDeviceOrientation = self.deviceOrientation
        var isCompactLayout = true
        if case .regular = layout.metrics.widthClass, case .regular = layout.metrics.heightClass {
            mappedDeviceOrientation = .portrait
            isCompactLayout = false
        }
        
        if !self.hasVideoNodes {
            self.isUIHidden = false
        }
        
        var isUIHidden = self.isUIHidden
        switch self.callState?.state {
        case .terminated, .terminating:
            isUIHidden = false
        default:
            break
        }
        
        var uiDisplayTransition: CGFloat = isUIHidden ? 0.0 : 1.0
        let pipTransitionAlpha: CGFloat = 1.0 - self.pictureInPictureTransitionFraction
        uiDisplayTransition *= pipTransitionAlpha
        
        let pinchTransitionAlpha: CGFloat = self.isVideoPinched ? 0.0 : 1.0
        
        let previousVideoButtonFrame = self.buttonsNode.videoButtonFrame().flatMap { frame -> CGRect in
            return self.buttonsNode.view.convert(frame, to: self.view)
        }
        
        let buttonsHeight: CGFloat
        if let buttonsMode = self.buttonsMode {
            buttonsHeight = self.buttonsNode.updateLayout(strings: self.presentationData.strings, mode: buttonsMode, constrainedWidth: layout.size.width, bottomInset: layout.intrinsicInsets.bottom, transition: transition)
        } else {
            buttonsHeight = 0.0
        }
        let defaultButtonsOriginY = layout.size.height - buttonsHeight

        let toastHeight = self.toastNode.updateLayout(strings: self.presentationData.strings, content: self.toastContent, constrainedWidth: layout.size.width, bottomInset: layout.intrinsicInsets.bottom + buttonsHeight, transition: transition)
        
        let toastSpacing: CGFloat = 22.0
        let toastCollapsedOriginY = self.pictureInPictureTransitionFraction > 0.0 ? layout.size.height : layout.size.height - max(layout.intrinsicInsets.bottom, 20.0) - toastHeight
        let toastOriginY = interpolate(from: toastCollapsedOriginY, to: defaultButtonsOriginY - toastSpacing - toastHeight, value: uiDisplayTransition)
        
        var overlayAlpha: CGFloat = min(pinchTransitionAlpha, uiDisplayTransition)
        var toastAlpha: CGFloat = min(pinchTransitionAlpha, pipTransitionAlpha)
        
        switch self.callState?.state {
        case .terminated, .terminating:
            overlayAlpha *= 0.5
            toastAlpha *= 0.5
        default:
            break
        }
        
        let containerFullScreenFrame = CGRect(origin: CGPoint(), size: layout.size)
        let containerPictureInPictureFrame = self.calculatePictureInPictureContainerRect(layout: layout, navigationHeight: navigationBarHeight)
        
        let containerFrame = interpolateFrame(from: containerFullScreenFrame, to: containerPictureInPictureFrame, t: self.pictureInPictureTransitionFraction)
        
        transition.updateFrame(node: self.containerTransformationNode, frame: containerFrame)
        transition.updateSublayerTransformScale(node: self.containerTransformationNode, scale: min(1.0, containerFrame.width / layout.size.width * 1.01))
        transition.updateCornerRadius(layer: self.containerTransformationNode.layer, cornerRadius: self.pictureInPictureTransitionFraction * 10.0)
        
        transition.updateFrame(node: self.containerNode, frame: CGRect(origin: CGPoint(x: (containerFrame.width - layout.size.width) / 2.0, y: floor(containerFrame.height - layout.size.height) / 2.0), size: layout.size))
        transition.updateFrame(node: self.videoContainerNode, frame: containerFullScreenFrame)
        self.videoContainerNode.update(size: containerFullScreenFrame.size, transition: transition)
                
        if let keyPreviewNode = self.keyPreviewNode {
            transition.updateFrame(node: keyPreviewNode, frame: containerFullScreenFrame)
            keyPreviewNode.updateLayout(size: layout.size, transition: .immediate)
        }
        
        let encryptionHintWidth: CGFloat = layout.size.width * 0.57
        let encryptionTextInsets = UIEdgeInsets(top: 9, left: 0, bottom: 9, right: 6)
        let encryptionSize = encryptionDescHintNode.updateLayout(
            constrainedWidth: encryptionHintWidth,
            insets: encryptionTextInsets
        )
        transition.updateFrame(
            node: self.encryptionDescHintNode,
            frame: CGRect(
                x: layout.size.width - encryptionSize.width - 15,
                y: keyButtonNode.frame.maxY + 13.5,
                width: encryptionSize.width,
                height: encryptionSize.height
            )
        )
        
        transition.updateFrame(node: self.animatedGradientNode, frame: containerFullScreenFrame)

        let avatarFrame = CGRect(
            x: (containerFullScreenFrame.size.width / 2) - 68,
            y: ((containerFullScreenFrame.size.height / 2) - 68) * 0.62,
            width: 136,
            height: 136
        )
        let blobFrame = CGRect(
            x: avatarFrame.minX - 18,
            y: avatarFrame.minY - 18,
            width: 172,
            height: 172
        )
        transition.updateFrame(
            node: self.blobNode,
            frame: blobFrame
        )
        transition.updateFrame(
            node: self.avatarNode,
            frame: avatarFrame
        )
        
        let navigationOffset: CGFloat = max(20.0, layout.safeInsets.top)
        let topOriginY = interpolate(from: -20.0, to: navigationOffset, value: uiDisplayTransition)
        
        let backSize = self.backButtonNode.measure(CGSize(width: 320.0, height: 100.0))
        if let image = self.backButtonArrowNode.image {
            transition.updateFrame(node: self.backButtonArrowNode, frame: CGRect(origin: CGPoint(x: 10.0, y: topOriginY + 11.0), size: image.size))
        }
        transition.updateFrame(node: self.backButtonNode, frame: CGRect(origin: CGPoint(x: 29.0, y: topOriginY + 11.0), size: backSize))
        

        let statusHeight = self.statusNode.updateLayout(constrainedWidth: layout.size.width, transition: transition)
        let statusFrame = CGRect(
            x: 0,
            y: avatarFrame.maxY + 40,
            width: layout.size.width,
            height: statusHeight
        )
        transition.updateFrame(node: self.statusNode, frame: statusFrame)
        
        let hintWidth: CGFloat = 178.0
        let textInsets = UIEdgeInsets(top: 5, left: 0, bottom: 5, right: 6)
        let hintSize = hintNode.updateLayout(
            constrainedWidth: hintWidth,
            insets: textInsets
        )
        let hintFrame = CGRect(
            x: (layout.size.width - hintWidth) / 2,
            y: statusFrame.maxY + 12.5,
            width: hintWidth,
            height: hintSize.height
        )
        transition.updateFrame(
            node: hintNode,
            frame: hintFrame
        )
        
        transition.updateFrame(node: self.toastNode, frame: CGRect(origin: CGPoint(x: 0.0, y: toastOriginY), size: CGSize(width: layout.size.width, height: toastHeight)))
        transition.updateFrame(node: self.buttonsNode, frame: CGRect(origin: CGPoint(x: 0.0, y: defaultButtonsOriginY), size: CGSize(width: layout.size.width, height: buttonsHeight)))
        if !dismissedButtons {
            transition.updateAlpha(node: self.buttonsNode, alpha: overlayAlpha)
        }
        let closeCallBtnWidth: CGFloat = layout.size.width * 0.78
        let closeCallBtnX: CGFloat = (layout.size.width - closeCallBtnWidth) / 2
        transition.updateFrame(
            node: closeCallButtonNode,
            frame: CGRect(
                x: closeCallBtnX,
                y: defaultButtonsOriginY,
                width: closeCallBtnWidth,
                height: 50
            )
        )
        
        if let ratingNode = self.ratingNode {
            let ratingSize = ratingNode.updateLayout(width: layout.size.width * 0.77)
            let ratingFrame = CGRect(
                x: (layout.size.width - ratingSize.width) / 2,
                y: closeCallButtonNode.frame.minY - (ratingSize.height + 66),
                width: ratingSize.width,
                height: ratingSize.height
            )
            ratingNode.frame = ratingFrame
            ratingNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2, removeOnCompletion: false)
            ratingNode.layer.animateScale(from: 0.4, to: 1.0, duration: 0.2, removeOnCompletion: false)
            
            if statusNode.frame.maxY > ratingNode.frame.minY {
                transition.updateAlpha(node: statusNode, alpha: 0.0)
            }
        }

        
        let fullscreenVideoFrame = containerFullScreenFrame
        let previewVideoFrame = self.calculatePreviewVideoRect(layout: layout, navigationHeight: navigationBarHeight)
        
        if let removedMinimizedVideoNodeValue = self.removedMinimizedVideoNodeValue {
            self.removedMinimizedVideoNodeValue = nil
            
            if transition.isAnimated {
                removedMinimizedVideoNodeValue.layer.animateScale(from: 1.0, to: 0.1, duration: 0.3, removeOnCompletion: false)
                removedMinimizedVideoNodeValue.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false, completion: { [weak removedMinimizedVideoNodeValue] _ in
                    removedMinimizedVideoNodeValue?.removeFromSupernode()
                })
            } else {
                removedMinimizedVideoNodeValue.removeFromSupernode()
            }
        }
        
        if let expandedVideoNode = self.expandedVideoNode {
            transition.updateAlpha(node: expandedVideoNode, alpha: 1.0)
            var expandedVideoTransition = transition
            if expandedVideoNode.frame.isEmpty || self.disableAnimationForExpandedVideoOnce {
                expandedVideoTransition = .immediate
                self.disableAnimationForExpandedVideoOnce = false
            }
            
            if let removedExpandedVideoNodeValue = self.removedExpandedVideoNodeValue {
                self.removedExpandedVideoNodeValue = nil
                
                expandedVideoTransition.updateFrame(node: expandedVideoNode, frame: fullscreenVideoFrame, completion: { [weak removedExpandedVideoNodeValue] _ in
                    removedExpandedVideoNodeValue?.removeFromSupernode()
                })
            } else {
                expandedVideoTransition.updateFrame(node: expandedVideoNode, frame: fullscreenVideoFrame)
            }
            
            expandedVideoNode.updateLayout(size: expandedVideoNode.frame.size, cornerRadius: 0.0, isOutgoing: expandedVideoNode === self.outgoingVideoNodeValue, deviceOrientation: mappedDeviceOrientation, isCompactLayout: isCompactLayout, transition: expandedVideoTransition)
            
            if self.animateRequestedVideoOnce {
                self.animateRequestedVideoOnce = false
                if expandedVideoNode === self.outgoingVideoNodeValue {
                    let videoButtonFrame = self.buttonsNode.videoButtonFrame().flatMap { frame -> CGRect in
                        return self.buttonsNode.view.convert(frame, to: self.view)
                    }
                    
                    if let previousVideoButtonFrame = previousVideoButtonFrame, let videoButtonFrame = videoButtonFrame {
                        expandedVideoNode.animateRadialMask(from: previousVideoButtonFrame, to: videoButtonFrame)
                    }
                }
            }
        } else {
            if let removedExpandedVideoNodeValue = self.removedExpandedVideoNodeValue {
                self.removedExpandedVideoNodeValue = nil
                
                if transition.isAnimated {
                    removedExpandedVideoNodeValue.layer.animateScale(from: 1.0, to: 0.1, duration: 0.3, removeOnCompletion: false)
                    removedExpandedVideoNodeValue.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false, completion: { [weak removedExpandedVideoNodeValue] _ in
                        removedExpandedVideoNodeValue?.removeFromSupernode()
                    })
                } else {
                    removedExpandedVideoNodeValue.removeFromSupernode()
                }
            }
        }
        
        
        if let minimizedVideoNode = self.minimizedVideoNode {
            transition.updateAlpha(node: minimizedVideoNode, alpha: min(pipTransitionAlpha, pinchTransitionAlpha))
            var minimizedVideoTransition = transition
            var didAppear = false
            if minimizedVideoNode.frame.isEmpty {
                minimizedVideoTransition = .immediate
                didAppear = true
            }
            if self.minimizedVideoDraggingPosition == nil {
                if let animationForExpandedVideoSnapshotView = self.animationForExpandedVideoSnapshotView {
                    self.containerNode.view.addSubview(animationForExpandedVideoSnapshotView)
                    transition.updateAlpha(layer: animationForExpandedVideoSnapshotView.layer, alpha: 0.0, completion: { [weak animationForExpandedVideoSnapshotView] _ in
                        animationForExpandedVideoSnapshotView?.removeFromSuperview()
                    })
                    transition.updateTransformScale(layer: animationForExpandedVideoSnapshotView.layer, scale: previewVideoFrame.width / fullscreenVideoFrame.width)
                    
                    transition.updatePosition(layer: animationForExpandedVideoSnapshotView.layer, position: CGPoint(x: previewVideoFrame.minX + previewVideoFrame.center.x /  fullscreenVideoFrame.width * previewVideoFrame.width, y: previewVideoFrame.minY + previewVideoFrame.center.y / fullscreenVideoFrame.height * previewVideoFrame.height))
                    self.animationForExpandedVideoSnapshotView = nil
                }
                minimizedVideoTransition.updateFrame(node: minimizedVideoNode, frame: previewVideoFrame)
                minimizedVideoNode.updateLayout(size: previewVideoFrame.size, cornerRadius: interpolate(from: 14.0, to: 24.0, value: self.pictureInPictureTransitionFraction), isOutgoing: minimizedVideoNode === self.outgoingVideoNodeValue, deviceOrientation: mappedDeviceOrientation, isCompactLayout: layout.metrics.widthClass == .compact, transition: minimizedVideoTransition)
                if transition.isAnimated && didAppear {
                    minimizedVideoNode.layer.animateSpring(from: 0.1 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.5)
                }
            }
            
            self.animationForExpandedVideoSnapshotView = nil
        }
        
        let keyTextSize = self.keyButtonNode.frame.size
        transition.updateFrame(node: self.keyButtonNode, frame: CGRect(origin: CGPoint(x: layout.size.width - keyTextSize.width - 8.0, y: topOriginY + 8.0), size: keyTextSize))
        transition.updateAlpha(node: self.keyButtonNode, alpha: overlayAlpha)
        
        if let debugNode = self.debugNode {
            transition.updateFrame(node: debugNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        }
        
        let requestedAspect: CGFloat
        if case .compact = layout.metrics.widthClass, case .compact = layout.metrics.heightClass {
            var isIncomingVideoRotated = false
            var rotationCount = 0
            
            switch mappedDeviceOrientation {
            case .portrait:
                break
            case .landscapeLeft:
                rotationCount += 1
            case .landscapeRight:
                rotationCount += 1
            case .portraitUpsideDown:
                 break
            default:
                break
            }
            
            if rotationCount % 2 != 0 {
                isIncomingVideoRotated = true
            }
            
            if !isIncomingVideoRotated {
                requestedAspect = layout.size.width / layout.size.height
            } else {
                requestedAspect = 0.0
            }
        } else {
            requestedAspect = 0.0
        }
        if self.currentRequestedAspect != requestedAspect {
            self.currentRequestedAspect = requestedAspect
            if !self.sharedContext.immediateExperimentalUISettings.disableVideoAspectScaling {
                self.call.setRequestedVideoAspect(Float(requestedAspect))
            }
        }
    }
    
    @objc func keyPressed() {
        if self.keyPreviewNode == nil, let keyText = self.keyTextData?.1, let peer = self.peer {
            UserDefaults.standard.set(true, forKey: "TG_encryption_description_presented")
            encryptionDescHintNode.animateOut()
            encryptionDescHintNode.layer.animatePosition(from: encryptionDescHintNode.layer.position, to: CGPoint(x: self.keyButtonNode.frame.midX, y: self.keyButtonNode.frame.midY), duration: 0.2)
            
            let keyPreviewNode = CallControllerKeyPreviewNode(
                context: call.context,
                keyText: keyText,
                titleText: self.presentationData.strings.Call_EmojiTitle,
                infoText: self.presentationData.strings.Call_EmojiDescription(EnginePeer(peer).compactDisplayTitle).string.replacingOccurrences(of: "%%", with: "%"),
                emojis: { [weak self] in
                    self?.call.context.animatedEmojiStickers ?? [:]
                },
                dismiss: { [weak self] in
                    if let _ = self?.keyPreviewNode {
                        self?.backPressed()
                    }
                }
            )
            
            self.containerNode.insertSubnode(keyPreviewNode, belowSubnode: self.backButtonArrowNode)
            self.keyPreviewNode = keyPreviewNode
            
            if let (validLayout, _) = self.validLayout {
                keyPreviewNode.updateLayout(size: validLayout.size, transition: .immediate)

                self.keyButtonNode.isHidden = true
                keyPreviewNode.animateIn(from: self.keyButtonNode.frame, fromNode: self.keyButtonNode)
                avatarNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false)
                blobNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false)
                
                avatarNode.layer.animateScale(from: 1.0, to: 0.4, duration: 0.2, removeOnCompletion: false)
                blobNode.layer.animateScale(from: 1.0, to: 0.4, duration: 0.2, removeOnCompletion: false)
            }
        }
    }
    
    @objc func backPressed() {
        if let keyPreviewNode = self.keyPreviewNode {
            self.keyPreviewNode = nil
            let f = CGRect(
                origin: self.keyButtonNode.frame.origin.offsetBy(dx: 2, dy: 1),
                size: CGSize(
                    width: self.keyButtonNode.frame.width - 2,
                    height: self.keyButtonNode.frame.height - 1
                )
            )
            keyPreviewNode.animateOut(to: f, toNode: self.keyButtonNode, completion: { [weak self, weak keyPreviewNode] isEmojiAnimated in
                self?.keyButtonNode.isHidden = false
                if isEmojiAnimated {
                    keyPreviewNode?.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false) { [weak keyPreviewNode] _ in
                        keyPreviewNode?.removeFromSupernode()
                    }
                } else {
                    keyPreviewNode?.removeFromSupernode()
                }
            })
            
            avatarNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2, removeOnCompletion: false)
            blobNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2, removeOnCompletion: false)
            
            avatarNode.layer.animateScale(from: 0.4, to: 1.0, duration: 0.2, removeOnCompletion: false)
            blobNode.layer.animateScale(from: 0.4, to: 1.0, duration: 0.2, removeOnCompletion: false)
            self.updateDimVisibility()
        } else if self.hasVideoNodes {
            if let (layout, navigationHeight) = self.validLayout {
                self.pictureInPictureTransitionFraction = 1.0
                self.containerLayoutUpdated(layout, navigationBarHeight: navigationHeight, transition: .animated(duration: 0.4, curve: .spring))
            }
        } else {
            self.back?()
        }
    }
    
    private var hasVideoNodes: Bool {
        return self.expandedVideoNode != nil || self.minimizedVideoNode != nil
    }
    
    private var debugTapCounter: (Double, Int) = (0.0, 0)
    
    private func areUserActionsDisabledNow() -> Bool {
        return CACurrentMediaTime() < self.disableActionsUntilTimestamp
    }
    
    @objc func tapGesture(_ recognizer: UITapGestureRecognizer) {
        if case .ended = recognizer.state {
            if !self.pictureInPictureTransitionFraction.isZero {
                self.view.window?.endEditing(true)
                
                if let (layout, navigationHeight) = self.validLayout {
                    self.pictureInPictureTransitionFraction = 0.0
                    
                    self.containerLayoutUpdated(layout, navigationBarHeight: navigationHeight, transition: .animated(duration: 0.4, curve: .spring))
                }
            } else if let _ = self.keyPreviewNode {
                self.backPressed()
            } else {
                if self.hasVideoNodes {
                    let point = recognizer.location(in: recognizer.view)
                    if let expandedVideoNode = self.expandedVideoNode, let minimizedVideoNode = self.minimizedVideoNode, minimizedVideoNode.frame.contains(point) {
                        if !self.areUserActionsDisabledNow() {
                            let copyView = minimizedVideoNode.view.snapshotView(afterScreenUpdates: false)
                            copyView?.frame = minimizedVideoNode.frame
                            self.expandedVideoNode = minimizedVideoNode
                            self.minimizedVideoNode = expandedVideoNode
                            if let supernode = expandedVideoNode.supernode {
                                supernode.insertSubnode(expandedVideoNode, aboveSubnode: minimizedVideoNode)
                            }
                            self.disableActionsUntilTimestamp = CACurrentMediaTime() + 0.3
                            if let (layout, navigationBarHeight) = self.validLayout {
                                self.disableAnimationForExpandedVideoOnce = true
                                self.animationForExpandedVideoSnapshotView = copyView
                                self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.3, curve: .easeInOut))
                            }
                        }
                    } else {
                        var updated = false
                        if let callState = self.callState {
                            switch callState.state {
                            case .active, .connecting, .reconnecting:
                                self.isUIHidden = !self.isUIHidden
                                updated = true
                            default:
                                break
                            }
                        }
                        if updated, let (layout, navigationBarHeight) = self.validLayout {
                            self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.3, curve: .easeInOut))
                        }
                    }
                } else {
                    let point = recognizer.location(in: recognizer.view)
                    if self.statusNode.frame.contains(point) {
                        if self.easyDebugAccess {
                            self.presentDebugNode()
                        } else {
                            let timestamp = CACurrentMediaTime()
                            if self.debugTapCounter.0 < timestamp - 0.75 {
                                self.debugTapCounter.0 = timestamp
                                self.debugTapCounter.1 = 0
                            }
                            
                            if self.debugTapCounter.0 >= timestamp - 0.75 {
                                self.debugTapCounter.0 = timestamp
                                self.debugTapCounter.1 += 1
                            }
                            
                            if self.debugTapCounter.1 >= 10 {
                                self.debugTapCounter.1 = 0
                                
                                self.presentDebugNode()
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func presentDebugNode() {
        guard self.debugNode == nil else {
            return
        }
        
        self.forceReportRating = true
        
        let debugNode = CallDebugNode(signal: self.debugInfo)
        debugNode.dismiss = { [weak self] in
            if let strongSelf = self {
                strongSelf.debugNode?.removeFromSupernode()
                strongSelf.debugNode = nil
            }
        }
        self.addSubnode(debugNode)
        self.debugNode = debugNode
        
        if let (layout, navigationBarHeight) = self.validLayout {
            self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
        }
    }
    
    private var minimizedVideoInitialPosition: CGPoint?
    private var minimizedVideoDraggingPosition: CGPoint?
    
    private func nodeLocationForPosition(layout: ContainerViewLayout, position: CGPoint, velocity: CGPoint) -> VideoNodeCorner {
        let layoutInsets = UIEdgeInsets()
        var result = CGPoint()
        if position.x < layout.size.width / 2.0 {
            result.x = 0.0
        } else {
            result.x = 1.0
        }
        if position.y < layoutInsets.top + (layout.size.height - layoutInsets.bottom - layoutInsets.top) / 2.0 {
            result.y = 0.0
        } else {
            result.y = 1.0
        }
        
        let currentPosition = result
        
        let angleEpsilon: CGFloat = 30.0
        var shouldHide = false
        
        if (velocity.x * velocity.x + velocity.y * velocity.y) >= 500.0 * 500.0 {
            let x = velocity.x
            let y = velocity.y
            
            var angle = atan2(y, x) * 180.0 / CGFloat.pi * -1.0
            if angle < 0.0 {
                angle += 360.0
            }
            
            if currentPosition.x.isZero && currentPosition.y.isZero {
                if ((angle > 0 && angle < 90 - angleEpsilon) || angle > 360 - angleEpsilon) {
                    result.x = 1.0
                    result.y = 0.0
                } else if (angle > 180 + angleEpsilon && angle < 270 + angleEpsilon) {
                    result.x = 0.0
                    result.y = 1.0
                } else if (angle > 270 + angleEpsilon && angle < 360 - angleEpsilon) {
                    result.x = 1.0
                    result.y = 1.0
                } else {
                    shouldHide = true
                }
            } else if !currentPosition.x.isZero && currentPosition.y.isZero {
                if (angle > 90 + angleEpsilon && angle < 180 + angleEpsilon) {
                    result.x = 0.0
                    result.y = 0.0
                }
                else if (angle > 270 - angleEpsilon && angle < 360 - angleEpsilon) {
                    result.x = 1.0
                    result.y = 1.0
                }
                else if (angle > 180 + angleEpsilon && angle < 270 - angleEpsilon) {
                    result.x = 0.0
                    result.y = 1.0
                }
                else {
                    shouldHide = true
                }
            } else if currentPosition.x.isZero && !currentPosition.y.isZero {
                if (angle > 90 - angleEpsilon && angle < 180 - angleEpsilon) {
                    result.x = 0.0
                    result.y = 0.0
                }
                else if (angle < angleEpsilon || angle > 270 + angleEpsilon) {
                    result.x = 1.0
                    result.y = 1.0
                }
                else if (angle > angleEpsilon && angle < 90 - angleEpsilon) {
                    result.x = 1.0
                    result.y = 0.0
                }
                else if (!shouldHide) {
                    shouldHide = true
                }
            } else if !currentPosition.x.isZero && !currentPosition.y.isZero {
                if (angle > angleEpsilon && angle < 90 + angleEpsilon) {
                    result.x = 1.0
                    result.y = 0.0
                }
                else if (angle > 180 - angleEpsilon && angle < 270 - angleEpsilon) {
                    result.x = 0.0
                    result.y = 1.0
                }
                else if (angle > 90 + angleEpsilon && angle < 180 - angleEpsilon) {
                    result.x = 0.0
                    result.y = 0.0
                }
                else if (!shouldHide) {
                    shouldHide = true
                }
            }
        }
        
        if result.x.isZero {
            if result.y.isZero {
                return .topLeft
            } else {
                return .bottomLeft
            }
        } else {
            if result.y.isZero {
                return .topRight
            } else {
                return .bottomRight
            }
        }
    }
    
    @objc private func panGesture(_ recognizer: CallPanGestureRecognizer) {
        switch recognizer.state {
            case .began:
                guard let location = recognizer.firstLocation else {
                    return
                }
                if self.pictureInPictureTransitionFraction.isZero, let expandedVideoNode = self.expandedVideoNode, let minimizedVideoNode = self.minimizedVideoNode, minimizedVideoNode.frame.contains(location), expandedVideoNode.frame != minimizedVideoNode.frame {
                    self.minimizedVideoInitialPosition = minimizedVideoNode.position
                } else if self.hasVideoNodes {
                    self.minimizedVideoInitialPosition = nil
                    if !self.pictureInPictureTransitionFraction.isZero {
                        self.pictureInPictureGestureState = .dragging(initialPosition: self.containerTransformationNode.position, draggingPosition: self.containerTransformationNode.position)
                    } else {
                        self.pictureInPictureGestureState = .collapsing(didSelectCorner: false)
                    }
                } else {
                    self.pictureInPictureGestureState = .none
                }
                self.dismissAllTooltips?()
            case .changed:
                if let minimizedVideoNode = self.minimizedVideoNode, let minimizedVideoInitialPosition = self.minimizedVideoInitialPosition {
                    let translation = recognizer.translation(in: self.view)
                    let minimizedVideoDraggingPosition = CGPoint(x: minimizedVideoInitialPosition.x + translation.x, y: minimizedVideoInitialPosition.y + translation.y)
                    self.minimizedVideoDraggingPosition = minimizedVideoDraggingPosition
                    minimizedVideoNode.position = minimizedVideoDraggingPosition
                } else {
                    switch self.pictureInPictureGestureState {
                    case .none:
                        let offset = recognizer.translation(in: self.view).y
                        var bounds = self.bounds
                        bounds.origin.y = -offset
                        self.bounds = bounds
                    case let .collapsing(didSelectCorner):
                        if let (layout, navigationHeight) = self.validLayout {
                            let offset = recognizer.translation(in: self.view)
                            if !didSelectCorner {
                                self.pictureInPictureGestureState = .collapsing(didSelectCorner: true)
                                if offset.x < 0.0 {
                                    self.pictureInPictureCorner = .topLeft
                                } else {
                                    self.pictureInPictureCorner = .topRight
                                }
                            }
                            let maxOffset: CGFloat = min(300.0, layout.size.height / 2.0)
                            
                            let offsetTransition = max(0.0, min(1.0, abs(offset.y) / maxOffset))
                            self.pictureInPictureTransitionFraction = offsetTransition
                            switch self.pictureInPictureCorner {
                            case .topRight, .bottomRight:
                                self.pictureInPictureCorner = offset.y < 0.0 ? .topRight : .bottomRight
                            case .topLeft, .bottomLeft:
                                self.pictureInPictureCorner = offset.y < 0.0 ? .topLeft : .bottomLeft
                            }
                            
                            self.containerLayoutUpdated(layout, navigationBarHeight: navigationHeight, transition: .immediate)
                        }
                    case .dragging(let initialPosition, var draggingPosition):
                        let translation = recognizer.translation(in: self.view)
                        draggingPosition.x = initialPosition.x + translation.x
                        draggingPosition.y = initialPosition.y + translation.y
                        self.pictureInPictureGestureState = .dragging(initialPosition: initialPosition, draggingPosition: draggingPosition)
                        self.containerTransformationNode.position = draggingPosition
                    }
                }
            case .cancelled, .ended:
                if let minimizedVideoNode = self.minimizedVideoNode, let _ = self.minimizedVideoInitialPosition, let minimizedVideoDraggingPosition = self.minimizedVideoDraggingPosition {
                    self.minimizedVideoInitialPosition = nil
                    self.minimizedVideoDraggingPosition = nil
                    
                    if let (layout, navigationHeight) = self.validLayout {
                        self.outgoingVideoNodeCorner = self.nodeLocationForPosition(layout: layout, position: minimizedVideoDraggingPosition, velocity: recognizer.velocity(in: self.view))
                        
                        let videoFrame = self.calculatePreviewVideoRect(layout: layout, navigationHeight: navigationHeight)
                        minimizedVideoNode.frame = videoFrame
                        minimizedVideoNode.layer.animateSpring(from: NSValue(cgPoint: CGPoint(x: minimizedVideoDraggingPosition.x - videoFrame.midX, y: minimizedVideoDraggingPosition.y - videoFrame.midY)), to: NSValue(cgPoint: CGPoint()), keyPath: "position", duration: 0.5, delay: 0.0, initialVelocity: 0.0, damping: 110.0, removeOnCompletion: true, additive: true, completion: nil)
                    }
                } else {
                    switch self.pictureInPictureGestureState {
                    case .none:
                        let velocity = recognizer.velocity(in: self.view).y
                        if abs(velocity) < 100.0 {
                            var bounds = self.bounds
                            let previous = bounds
                            bounds.origin = CGPoint()
                            self.bounds = bounds
                            self.layer.animateBounds(from: previous, to: bounds, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring)
                        } else {
                            var bounds = self.bounds
                            let previous = bounds
                            bounds.origin = CGPoint(x: 0.0, y: velocity > 0.0 ? -bounds.height: bounds.height)
                            self.bounds = bounds
                            self.layer.animateBounds(from: previous, to: bounds, duration: 0.15, timingFunction: CAMediaTimingFunctionName.easeOut.rawValue, completion: { [weak self] _ in
                                self?.dismissedInteractively?()
                            })
                        }
                    case .collapsing:
                        self.pictureInPictureGestureState = .none
                        let velocity = recognizer.velocity(in: self.view).y
                        if abs(velocity) < 100.0 && self.pictureInPictureTransitionFraction < 0.5 {
                            if let (layout, navigationHeight) = self.validLayout {
                                self.pictureInPictureTransitionFraction = 0.0
                                
                                self.containerLayoutUpdated(layout, navigationBarHeight: navigationHeight, transition: .animated(duration: 0.4, curve: .spring))
                            }
                        } else {
                            if let (layout, navigationHeight) = self.validLayout {
                                self.pictureInPictureTransitionFraction = 1.0
                                
                                self.containerLayoutUpdated(layout, navigationBarHeight: navigationHeight, transition: .animated(duration: 0.4, curve: .spring))
                            }
                        }
                    case let .dragging(initialPosition, _):
                        self.pictureInPictureGestureState = .none
                        if let (layout, navigationHeight) = self.validLayout {
                            let translation = recognizer.translation(in: self.view)
                            let draggingPosition = CGPoint(x: initialPosition.x + translation.x, y: initialPosition.y + translation.y)
                            self.pictureInPictureCorner = self.nodeLocationForPosition(layout: layout, position: draggingPosition, velocity: recognizer.velocity(in: self.view))
                            
                            let containerFrame = self.calculatePictureInPictureContainerRect(layout: layout, navigationHeight: navigationHeight)
                            self.containerTransformationNode.frame = containerFrame
                            containerTransformationNode.layer.animateSpring(from: NSValue(cgPoint: CGPoint(x: draggingPosition.x - containerFrame.midX, y: draggingPosition.y - containerFrame.midY)), to: NSValue(cgPoint: CGPoint()), keyPath: "position", duration: 0.5, delay: 0.0, initialVelocity: 0.0, damping: 110.0, removeOnCompletion: true, additive: true, completion: nil)
                        }
                    }
                }
            default:
                break
        }
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        touchTimer?.invalidate()
        gradientView?.resume()
        setupTimer()
        
        if self.debugNode != nil {
            return super.hitTest(point, with: event)
        }
        if self.containerTransformationNode.frame.contains(point) {
            return self.containerTransformationNode.view.hitTest(self.view.convert(point, to: self.containerTransformationNode.view), with: event)
        }
        return nil
    }
}

final class CallPanGestureRecognizer: UIPanGestureRecognizer {
    private(set) var firstLocation: CGPoint?
    
    public var shouldBegin: ((CGPoint) -> Bool)?
    
    override public init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        
        self.maximumNumberOfTouches = 1
    }
    
    override public func reset() {
        super.reset()
        
        self.firstLocation = nil
    }
    
    override public func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        
        let touch = touches.first!
        let point = touch.location(in: self.view)
        if let shouldBegin = self.shouldBegin, !shouldBegin(point) {
            self.state = .failed
            return
        }
        
        self.firstLocation = point
    }
    
    override public func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
    }
}

//Call UI contest
enum ColorPalette: Equatable {
    case connecting
    case weakSignal
    case connected
    
    var colors: [String] {
        switch self {
        case .connecting:
            return ColorPalette.connectingColors
        case .weakSignal:
            return ColorPalette.weakColors
        case .connected:
            return ColorPalette.connectedColors
        }
    }
    
    private static let connectingColors = [
        "7261DA", "AC65D4", "616AD5", "5295D6"
    ]
    
    private static let weakColors = [
        "FF7E46", "C94986", "F4992E", "B84498"
    ]
    
    private static let connectedColors = [
        "3C9C8F", "BAC05D", "398D6F", "53A6DE"
    ]
    
}

private final class AnimatedGradientView: UIView {
    
    struct AnimationPoint {
        let start: CGPoint
        let end: CGPoint
    }
    
    private let path: [AnimationPoint] = [
        AnimationPoint(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1)),
        AnimationPoint(start: CGPoint(x: 0, y: 1), end: CGPoint(x: 1, y: 1)),
        AnimationPoint(start: CGPoint(x: 1, y: 1), end: CGPoint(x: 1, y: 0)),
        AnimationPoint(start: CGPoint(x: 1, y: 1), end: CGPoint(x: 0, y: 0)),
        AnimationPoint(start: CGPoint(x: 1, y: 0), end: CGPoint(x: 0, y: 1))
    ]
    
    private var colors: [String]
    private var pallete: ColorPalette

    private let gradientLayer1 = CAGradientLayer()
    private let gradientLayer2 = CAGradientLayer()
    private let gradientLayer3 = CAGradientLayer()
    private let gradientLayer4 = CAGradientLayer()

    private let animationTime: CFTimeInterval
    
    private var currentIndex: Int = 0
    private var isPaused = false
    private var isAnimating = false
    
    init(frame: CGRect = .zero,
         colorPallete: ColorPalette,
         animationTime: CFTimeInterval = 1.0
    ) {
        self.colors = colorPallete.colors
        self.animationTime = animationTime
        self.pallete = colorPallete
        super.init(frame: frame)
        backgroundColor = .white
    }
    
    func pause() {
        isPaused = true
    }
    
    func resume() {
        isPaused = false
        startAnimation(ind: currentIndex)
    }
    
    func change(pallete: ColorPalette) {
        guard pallete != self.pallete else { return }
        
        self.pallete = pallete
        animateColor(layer: gradientLayer1, color: UIColor(hexString: pallete.colors[0])!, prev: UIColor(hexString: colors[0])!)
        animateColor(layer: gradientLayer2, color: UIColor(hexString: pallete.colors[1])!, prev: UIColor(hexString: colors[1])!)
        animateColor(layer: gradientLayer3, color: UIColor(hexString: pallete.colors[2])!, prev: UIColor(hexString: colors[2])!)
        animateColor(layer: gradientLayer4, color: UIColor(hexString: pallete.colors[3])!, prev: UIColor(hexString: colors[3])!)
        colors = pallete.colors
    }

    private func animateColor(layer: CAGradientLayer, color: UIColor, prev: UIColor) {
        let colorAnimation = CABasicAnimation(keyPath: "colors")
        colorAnimation.duration = 0.5
        colorAnimation.fromValue = [prev.cgColor, prev.withAlphaComponent(0.2).cgColor]
        colorAnimation.toValue = [color.cgColor, color.withAlphaComponent(0.2).cgColor]
        colorAnimation.fillMode = CAMediaTimingFillMode.forwards
        colorAnimation.isRemovedOnCompletion = false
        
        layer.add(colorAnimation, forKey: nil)
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
   
    func setup() {
        updateGradients()
        startAnimation(ind: 0)
    }
    
    private func updateGradients() {
        setGradient(layer: gradientLayer1, color: UIColor(hexString: colors[0])!, point: path[0])
        setGradient(layer: gradientLayer2, color: UIColor(hexString: colors[1])!, point: path[1])
        setGradient(layer: gradientLayer3, color: UIColor(hexString: colors[2])!, point: path[2])
        setGradient(layer: gradientLayer4, color: UIColor(hexString: colors[3])!, point: path[3])
    }
    
    private func startAnimation(ind: Int) {
        guard !isPaused, !isAnimating else { return }
        let ind1 = nextIndex(for: ind)
        let ind2 = nextIndex(for: ind1)
        let ind3 = nextIndex(for: ind2)
        let ind4 = nextIndex(for: ind3)

        animateGradient(layer: gradientLayer1, current: path[ind], next: path[ind1])
        animateGradient(layer: gradientLayer2, current: path[ind1], next: path[ind2])
        animateGradient(layer: gradientLayer3, current: path[ind2], next: path[ind3])
        animateGradient(layer: gradientLayer4, current: path[ind3], next: path[ind4])
        self.isAnimating = true
        self.currentIndex = ind1
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.isAnimating = false
            self?.startAnimation(ind: ind1)
        }
    }
    
    private func nextIndex(for ind: Int) -> Int {
        ind < path.count - 1 ? ind + 1 : 0
    }

}

private extension AnimatedGradientView {
    
    private func setGradient(layer: CAGradientLayer, color: UIColor, point: AnimationPoint) {
        layer.frame = self.bounds
        layer.colors = [color.cgColor, color.withAlphaComponent(0.2).cgColor]
        layer.type = .axial

        layer.startPoint = point.start
        layer.endPoint = point.end
        layer.locations = [0.07]
        layer.drawsAsynchronously = true
        
        self.layer.addSublayer(layer)
    }

    private func animateGradient(layer: CAGradientLayer, current: AnimationPoint, next: AnimationPoint) {
        let gradientAnimation = CABasicAnimation(keyPath: "startPoint")
        gradientAnimation.duration = animationTime
        gradientAnimation.fromValue = current.start
        gradientAnimation.toValue = next.start
        gradientAnimation.fillMode = CAMediaTimingFillMode.forwards
        gradientAnimation.isRemovedOnCompletion = false
        
        layer.startPoint = current.start
        layer.add(gradientAnimation, forKey: "animatestartpoint")
        
        let gradientAnimation1 = CABasicAnimation(keyPath: "endPoint")
        gradientAnimation1.duration = animationTime
        gradientAnimation1.fromValue = current.end
        gradientAnimation1.toValue = next.end
        gradientAnimation1.fillMode = CAMediaTimingFillMode.forwards
        gradientAnimation1.isRemovedOnCompletion = false
        
        layer.endPoint = next.end
        layer.add(gradientAnimation1, forKey: "animateendpoint")
    }
    
}

private final class TextHintNode: ASButtonNode {
    
    var onPress: (() -> Void)?
    
    private let leftImageNode: ASImageNode?
    private let textNode: ASTextNode
    private let btn: ASButtonNode
    private let tailNode: ASDisplayNode
    private let text: String
    private let font: UIFont
    
    private var _isHidden: Bool
    private let showTail: Bool
    
    func show() {
        guard _isHidden else { return }
        _isHidden = false
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2, removeOnCompletion: false)
    }
    
    func animateIn() {
        guard _isHidden else { return }
        _isHidden = false
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2, removeOnCompletion: false)
        self.layer.animateScale(from: 0.4, to: 1.0, duration: 0.2, removeOnCompletion: false)
    }
    
    func animateOut() {
        guard !_isHidden else { return }
        _isHidden = true
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false)
        self.layer.animateScale(from: 1.0, to: 0.4, duration: 0.2, removeOnCompletion: false)
    }
    
    func hide() {
        guard !_isHidden else { return }
        _isHidden = true
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false)
    }
    
    init(text: String, font: UIFont, radius: CGFloat = 16.0, showTail: Bool = false, image: UIImage? = nil, isHidden: Bool) {
        self.text = text
        self.font = font
        self.showTail = showTail
        self.btn = ASButtonNode()
        self.tailNode = ASDisplayNode()
        self._isHidden = isHidden
        self.textNode = ASTextNode()
        if let image {
            self.leftImageNode = ASImageNode()
            leftImageNode?.image = image
            leftImageNode?.contentMode = .scaleAspectFit
        } else {
            self.leftImageNode = nil
        }
        super.init()
        textNode.maximumNumberOfLines = 1
        tailNode.isHidden = !showTail
        self.alpha = _isHidden ? 0.0 : 1.0
        self.addSubnode(textNode)
        if let leftImageNode = self.leftImageNode {
            self.addSubnode(leftImageNode)
        }
        self.addSubnode(btn)
        self.addSubnode(tailNode)

        backgroundColor = UIColor.white.withAlphaComponent(0.25)
        tailNode.backgroundColor = .clear
        cornerRadius = radius
        drawTail(node: tailNode)
        
        addTarget(self, action: #selector(self.didPress), forControlEvents: .touchUpInside)
    }

    @objc private func didPress() {
        onPress?()
    }
    
    func updateLayout(constrainedWidth: CGFloat, insets: UIEdgeInsets) -> CGSize {
        var imageX: CGFloat = 0.0
        if leftImageNode != nil {
            imageX += 20
        }
        let startY: CGFloat = showTail ? 0.0 : 0.0
        
        let (titleLayout, titleApply) = TextNode.asyncLayout(self.textNode)(TextNodeLayoutArguments(attributedString: NSAttributedString(string: self.text, font: Font.regular(16.0), textColor: .white), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: constrainedWidth - imageX, height: CGFloat.greatestFiniteMagnitude), alignment: .center, cutout: nil, insets: insets))
        let _ = titleApply()
        self.textNode.frame = CGRect(origin: CGPoint(x: floor(((constrainedWidth - titleLayout.size.width) / 2.0)) + imageX, y: startY), size: titleLayout.size)
        self.leftImageNode?.frame = CGRect(x: 16, y: ((titleLayout.size.height / 2) - 12) + startY, width: 13, height: 22)
        let size = CGSize(width: textNode.frame.width + 16 + 16 + imageX, height: textNode.frame.height + startY)
        btn.frame = .init(origin: .zero, size: size)
        self.tailNode.frame = .init(x: size.width - 20 - 36, y: -3.5, width: 20.0, height: 7.5)
        
        return size
    }
    
    private func drawTail(node: ASDisplayNode) {
        let triangle = CAShapeLayer()
        triangle.fillColor = UIColor.white.withAlphaComponent(0.25).cgColor
        triangle.path = createRoundedTriangle(width: 20, height: 7.5, radius: 1)
        triangle.position = CGPoint(x: 0, y: 0)
        node.layer.addSublayer(triangle)
    }
    
    func createRoundedTriangle(width: CGFloat, height: CGFloat, radius: CGFloat) -> CGPath {
        // Draw the triangle path with its origin at the center.
        let point1 = CGPoint(x: -width / 2, y: height / 2)
        let point2 = CGPoint(x: 0, y: -height / 2)
        let point3 = CGPoint(x: width / 2, y: height / 2)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: height / 2))
        path.addArc(tangent1End: point1, tangent2End: point2, radius: radius)
        path.addArc(tangent1End: point2, tangent2End: point3, radius: radius)
        path.addArc(tangent1End: point3, tangent2End: point1, radius: radius)
        path.closeSubpath()

        return path
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if bounds.contains(point) {
            return self.view
        }
        
        return super.hitTest(point, with: event)
    }
}

final class AnimatedButtonNode: ASButtonNode {
    
    var onPress: (() -> Void)?
    private let backButton = ASButtonNode()
    private let topButton = ASButtonNode()
    
    private let backMaskLayer = CAShapeLayer()
    private let topMaskLayer = CAShapeLayer()

    init(text: String, backColor: UIColor, backTextColor: UIColor, topColor: UIColor, topTextColor: UIColor) {
        backButton.backgroundColor = backColor
        backButton.cornerRadius = 10
        backButton.setTitle(text, with: Font.with(size: 17, weight: .semibold), with: backTextColor, for: .normal)
        
        topButton.backgroundColor = topColor
        topButton.setTitle(text, with: Font.with(size: 17, weight: .semibold), with: topTextColor, for: .normal)
        topButton.cornerRadius = 10
        
        super.init()
        
        addSubnode(backButton)
        addSubnode(topButton)
        setup()
    }

    private func setup() {
        addMask(backMaskLayer, to: backButton.layer)
        addMask(topMaskLayer, to: topButton.layer)
    }
    
    override func layout() {
        super.layout()
        backButton.frame = bounds
        topButton.frame = bounds
    }
    
    func animate() {
        animateIn(maskLayer: backMaskLayer)
        animateIn(maskLayer: topMaskLayer)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.animateOut(maskLayer: self.topMaskLayer)
        }
    }

    private func addMask(_ maskLayer: CAShapeLayer, to: CALayer) {
        maskLayer.backgroundColor = UIColor.black.cgColor
        maskLayer.frame = .zero
        maskLayer.fillRule = .evenOdd
        to.mask = maskLayer
    }
    
    private func fillPath(for percent: Double) -> CGPath {
        let height = self.bounds.height * CGFloat(percent)
        let rect = CGRect(x: 0, y: height, width: self.bounds.width, height: self.bounds.height - height)
        return UIBezierPath(rect: rect).cgPath
    }
    
    private func animateIn(maskLayer: CAShapeLayer) {
        maskLayer.path = UIBezierPath(rect: bounds).cgPath
        let from = CGMutablePath()
        from.addRoundedRect(
            in: .init(x: bounds.width, y: 0, width: bounds.width, height: bounds.height),
            cornerWidth: 10,
            cornerHeight: 10
        )
        
        let to = CGMutablePath()
        to.addRoundedRect(
            in: bounds,
            cornerWidth: 10,
            cornerHeight: 10
        )
        let animation = CABasicAnimation(keyPath: "path")
        
        animation.fromValue = from
        animation.toValue = to
        animation.timingFunction = CAMediaTimingFunction.init(name: .easeInEaseOut)
        animation.duration = 0.6
        animation.isRemovedOnCompletion = false
        maskLayer.path = to
        maskLayer.add(animation, forKey: nil)
        
        let alphaAnimation = CABasicAnimation(keyPath: "opacity")
        
        alphaAnimation.fromValue = 0.0
        alphaAnimation.toValue = 1.0
        alphaAnimation.timingFunction = CAMediaTimingFunction.init(name: .easeInEaseOut)
        alphaAnimation.duration = 0.5
        alphaAnimation.isRemovedOnCompletion = false
        maskLayer.add(alphaAnimation, forKey: nil)
    }
    
    private func animateOut(maskLayer: CAShapeLayer) {
        maskLayer.path = UIBezierPath(rect: bounds).cgPath
        let from = CGMutablePath()
        from.addRoundedRect(
            in: bounds,
            cornerWidth: 5,
            cornerHeight: 5
        )
        
        let to = CGMutablePath()
        to.addRoundedRect(
            in: .init(x: bounds.width, y: 0, width: bounds.width, height: bounds.height),
            cornerWidth: 10,
            cornerHeight: 10
        )
        
        let animation = CABasicAnimation(keyPath: "path")
        
        animation.fromValue = from
        animation.toValue = to
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.duration = 8
        animation.isRemovedOnCompletion = false
        maskLayer.path = to
        maskLayer.add(animation, forKey: nil)
    }
    
}

final class CallRatingNode: ASDisplayNode {
    
    var onSelect: ((Int) -> Void)?
    
    private let titleNode: ASTextNode
    private let descNode: ASTextNode
    private let presentationData: PresentationData
    private let starNodes: [ASButtonNode]
    private let starContainerNode: ASDisplayNode

    private var rating: Int?
    
    init(presentationData: PresentationData) {
        self.titleNode = ASTextNode()
        self.descNode = ASTextNode()
        self.starContainerNode = ASDisplayNode()
        self.presentationData = presentationData
        var starNodes: [ASButtonNode] = []
        for _ in 0 ..< 5 {
            starNodes.append(ASButtonNode())
        }
        self.starNodes = starNodes
        
        super.init()
        self.backgroundColor = .white.withAlphaComponent(0.25)
        self.cornerRadius = 20
        
        self.addSubnode(self.titleNode)
        self.addSubnode(self.descNode)
        self.addSubnode(self.starContainerNode)
        
        for node in self.starNodes {
            node.addTarget(self, action: #selector(self.starPressed(_:)), forControlEvents: .touchDown)
            node.addTarget(self, action: #selector(self.starReleased(_:)), forControlEvents: .touchUpInside)
            self.starContainerNode.addSubnode(node)
        }

        titleNode.attributedText = NSAttributedString(string: presentationData.strings.Calls_RatingTitle, font: Font.semibold(16.0), textColor: .white)
        descNode.attributedText = NSAttributedString(string: presentationData.strings.Calls_RatingDesc, font: Font.regular(14.0), textColor: .white)

        for node in self.starNodes {
            node.setImage(generateTintedImage(image: UIImage(bundleImageName: "Call/Star"), color: .white), for: [])
            let highlighted = generateTintedImage(image: UIImage(bundleImageName: "Call/StarHighlighted"), color: .white)
            node.setImage(highlighted, for: [.selected])
            node.setImage(highlighted, for: [.selected, .highlighted])
        }
    }
    
    override func didLoad() {
        super.didLoad()
        
        self.starContainerNode.view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(self.panGesture(_:))))
    }
    
    private var shouldAnimateStars = true
    
    @objc func panGesture(_ gestureRecognizer: UIPanGestureRecognizer) {
        let location = gestureRecognizer.location(in: self.starContainerNode.view)
        var selectedNode: ASButtonNode?
        for node in self.starNodes {
            if node.frame.contains(location) {
                selectedNode = node
                break
            }
        }
        if let selectedNode = selectedNode {
            switch gestureRecognizer.state {
                case .began, .changed:
                    self.shouldAnimateStars = false
                    self.starPressed(selectedNode)
                case .ended:
                    self.shouldAnimateStars = true
                    self.starReleased(selectedNode)
                case .cancelled:
                    self.shouldAnimateStars = true
                    self.resetStars()
                default:
                    break
            }
        } else {
            self.resetStars()
        }
    }
    
    private func resetStars() {
        for i in 0 ..< self.starNodes.count {
            let node = self.starNodes[i]
            node.isSelected = false
        }
    }
    
    private var animationNode: AnimatedStickerNode?
    
    @objc func starPressed(_ sender: ASButtonNode) {
        if let index = self.starNodes.firstIndex(of: sender) {
            self.rating = index + 1
            for i in 0 ..< self.starNodes.count {
                let node = self.starNodes[i]
                node.isSelected = i <= index
                if node.isSelected {
                    animateTap(at: node)
                }
            }
            if index >= 3, self.animationNode == nil {
                let animationNode = DefaultAnimatedStickerNodeImpl()
                animationNode.completed = { [weak self] _ in
                    self?.animationNode = nil
                }
                animationNode.frame = CGRect(
                    x: (starNodes[index].frame.midX - 50),
                    y: starNodes[index].frame.midY - 50,
                    width: 100,
                    height: 100
                )
                animationNode.setup(source: AnimatedStickerNodeLocalFileSource(name: "CallStarRating"), width: 256, height: 256, playbackMode: .once, mode: .direct(cachePathPrefix: nil))
                animationNode.visibility = true
                self.animationNode = animationNode
                starContainerNode.addSubnode(animationNode)
            }
        }
    }
    
    private func animateTap(at node: ASButtonNode) {
        guard shouldAnimateStars else { return }
        let barItemView = node.view
        let impliesAnimation = CAKeyframeAnimation(keyPath: "transform.scale")
        impliesAnimation.values = [1.0, 1.05, 0.97, 1.0]
        impliesAnimation.duration = 0.1
        impliesAnimation.calculationMode = CAAnimationCalculationMode.cubic
        barItemView.layer.add(impliesAnimation, forKey: nil)
    }
    
    @objc func starReleased(_ sender: ASButtonNode) {
        if let index = self.starNodes.firstIndex(of: sender) {
            self.rating = index + 1
            for i in 0 ..< self.starNodes.count {
                let node = self.starNodes[i]
                node.isSelected = i <= index
            }
            if let rating = self.rating {
                self.onSelect?(rating)
            }
        }
    }
    
    func updateLayout(width: CGFloat) -> CGSize {
        let titleSize = titleNode.measure(.init(width: width, height: .greatestFiniteMagnitude))
        titleNode.frame = .init(
            x: (width - titleSize.width) / 2,
            y: 20,
            width: titleSize.width,
            height: titleSize.height
        )
        
        let descSize = descNode.measure(.init(width: width, height: .greatestFiniteMagnitude))
        descNode.frame = .init(
            x: (width - descSize.width) / 2,
            y: titleNode.frame.maxY + 10,
            width: descSize.width,
            height: descSize.height
        )
        
        let starSize = CGSize(width: 44.0, height: 44.0)
        let starContainerWidth = (starSize.width * 5.0)
        starContainerNode.frame = CGRect(
            x: (width - starContainerWidth) / 2,
            y: descNode.frame.maxY + 10,
            width: starContainerWidth,
            height: starSize.height
        )
        
        var starInd: CGFloat = 0
        for starNode in starNodes {
            starNode.frame = .init(
                x: ((starInd * starSize.width)),
                y: 0,
                width: starSize.width,
                height: starSize.height
            )
            starInd += 1
        }
        
        return CGSize(width: width, height: 20 + titleSize.height + 10 + descSize.height + 72)
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for star in self.starNodes {
            if let result = star.view.hitTest(self.view.convert(point, to: star.view), with: event) {
                return result
            }
        }
        
        return super.hitTest(point, with: event)
    }
}
