import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import LegacyComponents
import AnimatedStickerNode
import TelegramAnimatedStickerNode
import AccountContext
import TelegramCore
import Emoji
import MediaResources
import StickerResources

private let emojiFont = Font.regular(28.0)
private let textFont = Font.regular(15.0)

final class CallControllerEmojiNode: ASDisplayNode {
    
    private let emojiTextNodes: [ASTextNode]
    private let emojiAnimatedNodes: [AnimatedStickerNode]
    private let emojiItems: [StickerPackItem]
    
    private let emojis: () -> [String: [StickerPackItem]]
    let isAnimated: Bool
    private let emojiStringText: String
    private let context: AccountContext
    
    private let disposables = DisposableSet()

    private var _emojiNodes: [ASDisplayNode] {
        return isAnimated ? emojiAnimatedNodes : emojiTextNodes
    }
    
    deinit {
        disposables.dispose()
    }
    
    init(context: AccountContext, keyText: String, emojis: @escaping () -> [String: [StickerPackItem]]) {
        self.emojiStringText =  keyText
        self.context = context
        let emojiSource = emojis()
        let animatedEmojies = keyText.compactMap { emoji in
            return emojiSource["\(emoji)"]?.first
        }
        
        if animatedEmojies.count == 4 {
            self.isAnimated = true
            self.emojiItems = animatedEmojies
            self.emojiAnimatedNodes = (0..<4).map { _ in DefaultAnimatedStickerNodeImpl() }
        } else {
            self.emojiItems = []
            self.emojiAnimatedNodes = []
            self.isAnimated = false
        }
        
        self.emojiTextNodes = keyText.map { _ in ASTextNode() }
        
        self.emojis = emojis
        super.init()
        
        keyText.enumerated().forEach { index, emoji in
            self.emojiTextNodes[index].attributedText = NSAttributedString(string: "\(emoji)", font: Font.regular(38.0), textColor: .white, paragraphAlignment: .center)
        }
        
        emojiTextNodes.forEach { self.addSubnode($0) }
        emojiAnimatedNodes.forEach { self.addSubnode($0) }
        
        setupAnimatedNodes()
    }
    
    func stopAnimation(completion: (() -> Void)?) {
        guard isAnimated else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                completion?()
            }
            return
        }
        var completedCount = 0
        let playingCount = emojiAnimatedNodes.filter { $0.isPlaying }.count

        emojiAnimatedNodes.forEach { node in
            node.stopAtNearestLoop = true
            node.completed = { res in
                completedCount += 1

                if completedCount == playingCount {
                    completion?()
                    completedCount = -1
                }
            }
        }
    }
    
    private func setupAnimatedNodes() {
        emojiAnimatedNodes.enumerated().forEach { index, node in
            let fetchDisposable = freeMediaFileInteractiveFetched(account: context.account, userLocation: .other, fileReference: .standalone(media: emojiItems[index].file)).start()
            self.disposables.add(fetchDisposable)
            start(emoji: emojiItems[index], index: index, animatedNode: node)
            node.updateLayout(size: .init(width: 45, height: 45))
        }
    }
    
    private func start(emoji: StickerPackItem, index: Int, animatedNode: AnimatedStickerNode) {
        let file = emoji.file
        let pathPrefix = context.account.postbox.mediaBox.shortLivedResourceCachePathPrefix(file.resource.id)
        let mode: AnimatedStickerMode = .direct(cachePathPrefix: pathPrefix)
                
        animatedNode.autoplay = true

        animatedNode.setup(
            source: AnimatedStickerResourceSource(
                account: context.account,
                resource: file.resource,
                fitzModifier: nil,
                isVideo: file.mimeType == "video/webm"
            ),
            width: 300,
            height: 300,
            playbackMode: .still(.end),
            mode: mode
        )
        
        animatedNode.started = { [weak self] in
            guard let self else { return }
            self.emojiTextNodes[index].isHidden = true
        }
        
        animatedNode.visibility = true
        animatedNode.playLoop()
        _ = animatedNode.playIfNeeded()
    }
    
    func updateLayout(width: CGFloat, transition: ContainedViewLayoutTransition) -> CGSize {
        let emojiSize: CGFloat = 45.0

        let totalEmojiWidth: CGFloat = (emojiSize * 4) //+ (0 * 3) //emoji with margins
   
        var index: CGFloat = 0
        for node in emojiTextNodes {
            let f = CGRect(
                x: ((index * emojiSize)), // + (index * 4.0)),
                y: 0,
                width: emojiSize,
                height: emojiSize
            )
            transition.updateFrame(
                node: node,
                frame: f
            )
            index += 1
        }
        
        index = 0
        for node in emojiAnimatedNodes {
            let f = CGRect(
                x: ((index * emojiSize)), // + (index * 4.0)),
                y: 0,
                width: emojiSize,
                height: emojiSize
            )
            transition.updateFrame(
                node: node,
                frame: f
            )
            index += 1
        }
        
        return CGSize(width: totalEmojiWidth, height: emojiSize)
    }
    
}

final class CallControllerKeyPreviewNode: ASDisplayNode {
    
    private let keyTextNode: ASTextNode
    private let infoTitleNode: ASTextNode
    private let infoTextNode: ASTextNode
    private let dividerNode: ASDisplayNode
    private let buttonNode: ASButtonNode
    private let emojiNode: CallControllerEmojiNode
    
    private let dismiss: () -> Void
    
    private let containerNode: ASDisplayNode
    private let imageNode: TransformImageNode
    private let maskLayer = CAShapeLayer()

    init(context: AccountContext, keyText: String, titleText: String, infoText: String, emojis: @escaping () -> [String: [StickerPackItem]], dismiss: @escaping () -> Void) {
        self.emojiNode = CallControllerEmojiNode(
            context: context,
            keyText: keyText,
            emojis: emojis
        )
        self.containerNode = ASDisplayNode()
        self.keyTextNode = ASTextNode()
        self.dividerNode = ASDisplayNode()
        self.buttonNode = ASButtonNode()
        buttonNode.displaysAsynchronously = false
        self.keyTextNode.displaysAsynchronously = false
        self.infoTitleNode = ASTextNode()
        self.infoTitleNode.displaysAsynchronously = false
        self.infoTextNode = ASTextNode()
        self.infoTextNode.displaysAsynchronously = false
        self.dismiss = dismiss
       
        self.imageNode = TransformImageNode()

        super.init()
        
        self.containerNode.backgroundColor = UIColor.white.withAlphaComponent(0.25)
        self.containerNode.cornerRadius = 20.0
        self.keyTextNode.attributedText = NSAttributedString(string: keyText, attributes: [NSAttributedString.Key.font: Font.regular(38.0), NSAttributedString.Key.kern: 11.0 as NSNumber])
        self.infoTitleNode.attributedText = NSAttributedString(string: titleText, font: Font.semibold(16.0), textColor: UIColor.white, paragraphAlignment: .center)
        self.infoTextNode.attributedText = NSAttributedString(string: infoText, font: Font.regular(16.0), textColor: UIColor.white, paragraphAlignment: .center)
        buttonNode.setAttributedTitle(
            NSAttributedString(string: "OK", font: Font.regular(20.0), textColor: .white, paragraphAlignment: .center),
            for: .normal
        )
        
        self.addSubnode(self.containerNode)
        self.addSubnode(self.emojiNode)
        self.addSubnode(self.infoTitleNode)
        self.addSubnode(self.infoTextNode)
        self.addSubnode(self.buttonNode)
        buttonNode.addTarget(self, action: #selector(self.buttonDidPress), forControlEvents: .touchUpInside)
    }
    
    @objc private func buttonDidPress() {
        self.dismiss()
    }
    
    override func didLoad() {
        super.didLoad()
        
        self.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:))))
    }

    func updateLayout(size: CGSize, transition: ContainedViewLayoutTransition) {
        var totalHeight: CGFloat = 20 + 10 + 10 + 20 + 56 //margins
        let width = floor(size.width * 0.78)
        let constraintedSize = CGSize(width: width, height: .greatestFiniteMagnitude)

        let titleSize = infoTitleNode.measure(constraintedSize)
        let textSize = infoTextNode.measure(constraintedSize)
        
        totalHeight += 45.0 //Emoji
        totalHeight += titleSize.height
        totalHeight += textSize.height
        
        let containerFrame: CGRect = CGRect(
            x: (size.width - width) / 2,
            y: floor(size.height * 0.154),
            width: width,
            height: totalHeight
        )
        
        transition.updateFrame(
            node: containerNode,
            frame: containerFrame
        )
        
        let emojiSize = emojiNode.updateLayout(width: width, transition: transition)
        
        let emojiFrame = CGRect(
            x: containerFrame.minX + ((containerFrame.width - emojiSize.width) / 2),
            y: containerFrame.minY + 20,
            width: emojiSize.width,
            height: emojiSize.height
        )
        
        transition.updateFrame(
            node: emojiNode,
            frame: emojiFrame
        )
        
        let titleFrame = CGRect(
            x: containerFrame.minX + 28,
            y: emojiFrame.maxY + 10,
            width: titleSize.width,
            height: titleSize.height
        )
        
        let textFrame = CGRect(
            x: containerFrame.minX + 16,
            y: titleFrame.maxY + 10,
            width: textSize.width,
            height: textSize.height
        )
        
        let buttonFrame = CGRect(
            x: containerFrame.minX,
            y: textFrame.maxY + 20,
            width: containerFrame.width,
            height: 56
        )
        
        let maskFrame = CGRect(
            x: 0,
            y: containerFrame.height - 56,
            width: containerFrame.width,
            height: 1
        )
        maskLayerWith(layer: containerNode.layer, maskFrame: maskFrame)
        
        transition.updateFrame(node: self.infoTitleNode, frame: titleFrame)
        transition.updateFrame(node: self.infoTextNode, frame: textFrame)
        transition.updateFrame(node: self.buttonNode, frame: buttonFrame)
        
        transition.updateFrame(
            node: self.imageNode,
            frame: .init(x: 270, y: 50, width: 122, height: 44)
        )
        
    }
    
    private func maskLayerWith(layer: CALayer, maskFrame: CGRect) {
        let finalPath = UIBezierPath(rect: layer.bounds)
        let maskLayer = CAShapeLayer()
        maskLayer.frame = layer.bounds
        let path = UIBezierPath(rect: maskFrame)
        finalPath.append(path)
        maskLayer.fillRule = .evenOdd
        maskLayer.path = finalPath.cgPath
        layer.mask = maskLayer
    }
    
    func animateIn(from rect: CGRect, fromNode: ASDisplayNode) {
        self.containerNode.layer.animatePosition(from: CGPoint(x: rect.midX, y: rect.midY), to: self.containerNode.layer.position, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring)
        self.emojiNode.layer.animatePosition(from: CGPoint(x: rect.midX, y: rect.midY), to: self.emojiNode.layer.position, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring)

        self.infoTitleNode.layer.animatePosition(from: CGPoint(x: rect.midX, y: rect.midY), to: self.infoTitleNode.layer.position, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring)
        self.infoTextNode.layer.animatePosition(from: CGPoint(x: rect.midX, y: rect.midY), to: self.infoTextNode.layer.position, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring)
        self.buttonNode.layer.animatePosition(from: CGPoint(x: rect.midX, y: rect.midY), to: self.buttonNode.layer.position, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring)

        if let transitionView = fromNode.view.snapshotView(afterScreenUpdates: false) {
            self.view.addSubview(transitionView)
            transitionView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false)
            transitionView.layer.animatePosition(from: CGPoint(x: rect.midX, y: rect.midY), to: self.emojiNode.layer.position, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false, completion: { [weak transitionView] _ in
                transitionView?.removeFromSuperview()
            })
            
            transitionView.layer.animateScale(from: 1.0, to: 210.0 / rect.size.width, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false)
        }
        self.containerNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.15)
        
        self.infoTitleNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.15)
        self.infoTextNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.15)
        self.buttonNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.15)

        emojiNode.layer.animateScale(from: rect.size.width / emojiNode.frame.size.width, to: 1.0, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring)
        self.containerNode.layer.animateScale(from: 0.2, to: 1.0, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring)
        self.infoTitleNode.layer.animateScale(from: 0.2, to: 1.0, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring)
        self.infoTextNode.layer.animateScale(from: 0.2, to: 1.0, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring)
        self.buttonNode.layer.animateScale(from: 0.2, to: 1.0, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring)
    }
    
    func animateOut(to rect: CGRect, toNode: ASDisplayNode, completion: @escaping (Bool) -> Void) {
        self.containerNode.layer.animatePosition(from: self.containerNode.layer.position, to: CGPoint(x: rect.midX + 2.0, y: rect.midY + 20), duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false)
        self.containerNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.1, removeOnCompletion: false)
        self.containerNode.layer.animateScale(from: 1.0, to: rect.size.width / (self.containerNode.frame.size.width - 2.0), duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false)

        //deadline 5 sec
        var isStopped = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard self == nil, !isStopped else { return }
            isStopped = true
            completion(self?.emojiNode.isAnimated ?? false)
        }
        self.emojiNode.stopAnimation { [weak self] in
            guard !isStopped else { return }
            isStopped = true
            completion(self?.emojiNode.isAnimated ?? false)
        }

        self.emojiNode.layer.animateScale(from: 1.0, to:  rect.size.width / (self.emojiNode.frame.size.width - 4.0), duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false)
        self.emojiNode.layer.animatePosition(from: self.emojiNode.layer.position, to: CGPoint(x: rect.midX - 1, y: rect.midY), duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false)

        self.infoTextNode.layer.animatePosition(from: self.infoTextNode.layer.position, to: CGPoint(x: rect.midX + 2.0, y: rect.midY), duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false)
        self.infoTextNode.layer.animateScale(from: 1.0, to: rect.size.width / (self.infoTextNode.frame.size.width - 2.0), duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false)
        self.infoTextNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.1, removeOnCompletion: false)
        
        self.infoTitleNode.layer.animatePosition(from: self.infoTitleNode.layer.position, to: CGPoint(x: rect.midX + 2.0, y: rect.midY), duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false)
        self.infoTitleNode.layer.animateScale(from: 1.0, to: rect.size.width / (self.infoTitleNode.frame.size.width - 2.0), duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false)
        self.infoTitleNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.1, removeOnCompletion: false)
        
        self.buttonNode.layer.animatePosition(from: self.buttonNode.layer.position, to: CGPoint(x: rect.midX + 2.0, y: rect.midY), duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false)
        self.buttonNode.layer.animateScale(from: 1.0, to: rect.size.width / (self.buttonNode.frame.size.width - 2.0), duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false)
        self.buttonNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.1, removeOnCompletion: false)
    }
    
    @objc func tapGesture(_ recognizer: UITapGestureRecognizer) {
        if case .ended = recognizer.state {
            self.dismiss()
        }
    }
}
