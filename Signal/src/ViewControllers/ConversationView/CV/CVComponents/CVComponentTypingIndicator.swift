//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

public class CVComponentTypingIndicator: CVComponentBase, CVRootComponent {

    public var componentKey: CVComponentKey { .typingIndicator }

    public var cellReuseIdentifier: CVCellReuseIdentifier {
        CVCellReuseIdentifier.typingIndicator
    }

    public let isDedicatedCell = true

    private let typingIndicator: CVComponentState.TypingIndicator

    required init(itemModel: CVItemModel,
                  typingIndicator: CVComponentState.TypingIndicator) {
        self.typingIndicator = typingIndicator

        super.init(itemModel: itemModel)
    }

    public func configureCellRootComponent(cellView: UIView,
                                           cellMeasurement: CVCellMeasurement,
                                           componentDelegate: CVComponentDelegate,
                                           messageSwipeActionState: CVMessageSwipeActionState,
                                           componentView: CVComponentView) {
        Self.configureCellRootComponent(rootComponent: self,
                                        cellView: cellView,
                                        cellMeasurement: cellMeasurement,
                                        componentDelegate: componentDelegate,
                                        componentView: componentView)
    }

    public func buildComponentView(componentDelegate: CVComponentDelegate) -> CVComponentView {
        CVComponentViewTypingIndicator()
    }

    public func configureForRendering(componentView: CVComponentView,
                                      cellMeasurement: CVCellMeasurement,
                                      componentDelegate: CVComponentDelegate) {
        guard let componentView = componentView as? CVComponentViewTypingIndicator else {
            owsFailDebug("Unexpected componentView.")
            return
        }

        // TODO: Reuse?

        let outerStackView = componentView.outerStackView
        let innerStackView = componentView.innerStackView

        innerStackView.reset()
        outerStackView.reset()

        var outerViews = [UIView]()

        if let avatarImage = typingIndicator.avatar {
            let avatarView = componentView.avatarView
            avatarView.image = avatarImage
            outerViews.append(avatarView)
        }

        let bubbleView = componentView.bubbleView
        bubbleView.backgroundColor = conversationStyle.bubbleColorIncoming
        innerStackView.addSubviewToFillSuperviewEdges(bubbleView)

        let typingIndicatorView = componentView.typingIndicatorView
        typingIndicatorView.configureForConversationView(cellMeasurement: cellMeasurement)

        outerViews.append(innerStackView)

        // We always use a stretching spacer.
        outerViews.append(UIView.hStretchingSpacer())

        innerStackView.configure(config: innerStackViewConfig,
                             cellMeasurement: cellMeasurement,
                             measurementKey: Self.measurementKey_innerStack,
                             subviews: [ typingIndicatorView ])
        outerStackView.configure(config: outerStackViewConfig,
                                 cellMeasurement: cellMeasurement,
                                 measurementKey: Self.measurementKey_outerStack,
                                 subviews: outerViews)
    }

    private var outerStackViewConfig: CVStackViewConfig {
        CVStackViewConfig(axis: .horizontal,
                          alignment: .center,
                          spacing: ConversationStyle.messageStackSpacing,
                          layoutMargins: UIEdgeInsets(top: 0,
                                                      leading: conversationStyle.gutterLeading,
                                                      bottom: 0,
                                                      trailing: conversationStyle.gutterTrailing))
    }

    private var innerStackViewConfig: CVStackViewConfig {
        CVStackViewConfig(axis: .horizontal,
                          alignment: .center,
                          spacing: 0,
                          layoutMargins: conversationStyle.textInsets)
    }

    private let minBubbleHeight: CGFloat = 36

    private static let measurementKey_outerStack = "CVComponentTypingIndicator.measurementKey_outerStack"
    private static let measurementKey_innerStack = "CVComponentTypingIndicator.measurementKey_innerStack"

    public func measure(maxWidth: CGFloat, measurementBuilder: CVCellMeasurement.Builder) -> CGSize {
        owsAssertDebug(maxWidth > 0)

        var outerSubviewInfos = [ManualStackSubviewInfo]()
        var innerSubviewInfos = [ManualStackSubviewInfo]()

        if typingIndicator.avatar != nil {
            let avatarSize: CGSize = .square(CGFloat(ConversationStyle.groupMessageAvatarDiameter))
            outerSubviewInfos.append(avatarSize.asManualSubviewInfo(hasFixedSize: true))
        }

        let typingIndicatorSize = TypingIndicatorView.measure(measurementBuilder: measurementBuilder)
        innerSubviewInfos.append(typingIndicatorSize.asManualSubviewInfo(hasFixedSize: true))

        let innerStackMeasurement = ManualStackView.measure(config: innerStackViewConfig,
                                                            measurementBuilder: measurementBuilder,
                                                            measurementKey: Self.measurementKey_innerStack,
                                                            subviewInfos: innerSubviewInfos)
        var innerStackSize = innerStackMeasurement.measuredSize
        innerStackSize.height = max(minBubbleHeight, innerStackSize.height)
        outerSubviewInfos.append(innerStackSize.asManualSubviewInfo(hasFixedWidth: true))

        // We always use a stretching spacer.
        outerSubviewInfos.append(ManualStackSubviewInfo.empty)

        let outerStackMeasurement = ManualStackView.measure(config: outerStackViewConfig,
                                                            measurementBuilder: measurementBuilder,
                                                            measurementKey: Self.measurementKey_outerStack,
                                                            subviewInfos: outerSubviewInfos,
                                                            maxWidth: maxWidth)
        return outerStackMeasurement.measuredSize
    }

    // MARK: -

    // Used for rendering some portion of an Conversation View item.
    // It could be the entire item or some part thereof.
    public class CVComponentViewTypingIndicator: NSObject, CVComponentView {

        fileprivate let outerStackView = ManualStackView(name: "Typing indicator outer")
        fileprivate let innerStackView = ManualStackView(name: "Typing indicator inner")

        fileprivate let avatarView = AvatarImageView(shouldDeactivateConstraints: true)
        fileprivate let bubbleView = ManualLayoutViewWithLayer.pillView(name: "bubbleView")
        fileprivate let typingIndicatorView = TypingIndicatorView()

        public var isDedicatedCellView = false

        public var rootView: UIView {
            outerStackView
        }

        // MARK: -

        public func setIsCellVisible(_ isCellVisible: Bool) {
            if isCellVisible {
                typingIndicatorView.startAnimation()
            } else {
                typingIndicatorView.stopAnimation()
            }
        }

        public func reset() {
            owsAssertDebug(isDedicatedCellView)

            outerStackView.reset()
            innerStackView.reset()
            bubbleView.reset()

            avatarView.image = nil

            typingIndicatorView.reset()
            typingIndicatorView.removeFromSuperview()
        }

    }
}
