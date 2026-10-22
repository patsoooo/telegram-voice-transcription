import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import Postbox
import TelegramPresentationData
import TelegramUIPreferences
import AccountContext
import AudioWaveform
import ComponentFlow
import ComponentDisplayAdapters
import MultilineTextComponent
import GlassControls
import GlassBackgroundComponent
import HorizontalTabsComponent
import ShimmerEffect
import TelegramStringFormatting
import ContextUI
import SliderContextItem
import MediaPlaybackHeaderPanelComponent
import UniversalMediaPlayer
import ManagedAnimationNode
import LottieSettings
import SearchBarNode
import EdgeEffect
import UndoUI

// The design colours have no theme variable: 0088FF and 727272 are used as is in the light theme,
// and the closest theme colours stand in for them in the dark one. Read text is the theme's primary text colour.
private func voiceTranscriptBlue(_ theme: PresentationTheme) -> UIColor {
    return theme.overallDarkAppearance ? theme.list.itemAccentColor : UIColor(rgb: 0x0088FF)
}

/// The colour of the time of the line being spoken: 008BFF.
private func voiceTranscriptLineBlue() -> UIColor {
    return UIColor(rgb: 0x008BFF)
}

/// The grey of the lines that are not being spoken: 3C3C43 in the light theme (the system's secondary label colour), the
/// theme's text colour in the dark one, at the given strength.
private func voiceTranscriptTextColor(_ theme: PresentationTheme, alpha: CGFloat) -> UIColor {
    if theme.overallDarkAppearance {
        return theme.list.itemPrimaryTextColor.withAlphaComponent(alpha)
    } else {
        return UIColor(rgb: 0x3C3C43).withAlphaComponent(alpha)
    }
}

private func voiceTranscriptIconGray(_ theme: PresentationTheme) -> UIColor {
    return theme.overallDarkAppearance ? theme.list.itemSecondaryTextColor : UIColor(rgb: 0x727272)
}

private enum VoiceTranscriptPlaceholder {
    case loading
    case unavailable
}

/// A display link must not retain the node, so it fires through this object.
private final class VoiceTranscriptLinkTarget: NSObject {
    var action: (() -> Void)?

    @objc func fire() {
        self.action?()
    }
}

/// The size of the transcript text and of its line. The time column is exactly one line tall, so it follows these.
private struct VoiceTranscriptTextMetrics: Equatable {
    let fontSize: CGFloat
    let lineHeight: CGFloat
    let kerning: CGFloat
    let timeFontSize: CGFloat
    let timeLineHeight: CGFloat

    static let standard = VoiceTranscriptTextMetrics(fontSize: 18.0, lineHeight: 24.0, kerning: -0.26, timeFontSize: 13.0, timeLineHeight: 18.0)
}

/// An SF Symbol scaled so that its larger side is exactly `fit` points: the point size of a symbol does not give its
/// real glyph size, which differs from symbol to symbol.
private func voiceTranscriptSymbolImage(_ name: String, fit: CGFloat, weight: UIImage.SymbolWeight) -> UIImage? {
    guard let source = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 60.0, weight: weight)) else {
        return nil
    }
    let ratio = min(fit / source.size.width, fit / source.size.height)
    let size = CGSize(width: source.size.width * ratio, height: source.size.height * ratio)
    let image = UIGraphicsImageRenderer(size: size).image { _ in
        source.draw(in: CGRect(origin: CGPoint(), size: size))
    }
    return image.withRenderingMode(.alwaysTemplate)
}

/// The checkbox of a task, drawn to fill exactly `diameter` points: an outline, or a filled circle with a check. An SF Symbol of
/// this size is smaller than its image (the symbols have space around the glyph), so the circle is drawn here instead.
private func voiceSummaryCheckboxImage(isChecked: Bool, diameter: CGFloat, outlineColor: UIColor, fillColor: UIColor) -> UIImage {
    let size = CGSize(width: diameter, height: diameter)
    return UIGraphicsImageRenderer(size: size).image { context in
        let cgContext = context.cgContext
        if isChecked {
            cgContext.setFillColor(fillColor.cgColor)
            cgContext.fillEllipse(in: CGRect(origin: CGPoint(), size: size))
            cgContext.setStrokeColor(UIColor.white.cgColor)
            cgContext.setLineWidth(2.0)
            cgContext.setLineCap(.round)
            cgContext.setLineJoin(.round)
            cgContext.move(to: CGPoint(x: diameter * 0.29, y: diameter * 0.52))
            cgContext.addLine(to: CGPoint(x: diameter * 0.44, y: diameter * 0.67))
            cgContext.addLine(to: CGPoint(x: diameter * 0.72, y: diameter * 0.35))
            cgContext.strokePath()
        } else {
            let lineWidth: CGFloat = 1.5
            cgContext.setStrokeColor(outlineColor.cgColor)
            cgContext.setLineWidth(lineWidth)
            cgContext.strokeEllipse(in: CGRect(origin: CGPoint(), size: size).insetBy(dx: lineWidth / 2.0, dy: lineWidth / 2.0))
        }
    }.withRenderingMode(.alwaysOriginal)
}

/// The plain "→A" glyph of the Transcript tab (the app's own transcription icons carry a microphone or a lock).
private func voiceTranscriptTranscriptGlyph() -> UIImage? {
    return generateImage(CGSize(width: 22.0, height: 16.0), rotatedContext: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        context.setStrokeColor(UIColor.black.cgColor)
        context.setLineWidth(1.6)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        context.move(to: CGPoint(x: 1.5, y: 8.0))
        context.addLine(to: CGPoint(x: 11.0, y: 8.0))
        context.strokePath()
        context.move(to: CGPoint(x: 7.5, y: 4.0))
        context.addLine(to: CGPoint(x: 11.0, y: 8.0))
        context.addLine(to: CGPoint(x: 7.5, y: 12.0))
        context.strokePath()

        context.move(to: CGPoint(x: 13.0, y: 13.5))
        context.addLine(to: CGPoint(x: 17.0, y: 2.5))
        context.addLine(to: CGPoint(x: 21.0, y: 13.5))
        context.strokePath()
        context.move(to: CGPoint(x: 14.4, y: 9.6))
        context.addLine(to: CGPoint(x: 19.6, y: 9.6))
        context.strokePath()
    })?.withRenderingMode(.alwaysTemplate)
}

/// A rounded rectangle whose top and bottom corners have different radii.
private func voiceTranscriptSheetPath(size: CGSize, topRadius: CGFloat, bottomRadius: CGFloat) -> UIBezierPath {
    let width = size.width
    let height = size.height
    let top = min(topRadius, width / 2.0, height / 2.0)
    let bottom = min(bottomRadius, width / 2.0, height / 2.0)
    let path = UIBezierPath()
    path.move(to: CGPoint(x: top, y: 0.0))
    path.addLine(to: CGPoint(x: width - top, y: 0.0))
    path.addArc(withCenter: CGPoint(x: width - top, y: top), radius: top, startAngle: -.pi / 2.0, endAngle: 0.0, clockwise: true)
    path.addLine(to: CGPoint(x: width, y: height - bottom))
    path.addArc(withCenter: CGPoint(x: width - bottom, y: height - bottom), radius: bottom, startAngle: 0.0, endAngle: .pi / 2.0, clockwise: true)
    path.addLine(to: CGPoint(x: bottom, y: height))
    path.addArc(withCenter: CGPoint(x: bottom, y: height - bottom), radius: bottom, startAngle: .pi / 2.0, endAngle: .pi, clockwise: true)
    path.addLine(to: CGPoint(x: 0.0, y: top))
    path.addArc(withCenter: CGPoint(x: top, y: top), radius: top, startAngle: .pi, endAngle: .pi * 3.0 / 2.0, clockwise: true)
    path.close()
    return path
}

public final class VoiceTranscriptScreen: ViewController {
    private let context: AccountContext
    fileprivate let messageId: EngineMessage.Id
    fileprivate let peerTitle: String
    fileprivate let provider: VoiceTranscriptProvider

    private var animatedIn = false

    private var controllerNode: VoiceTranscriptScreenNode {
        return self.displayNode as! VoiceTranscriptScreenNode
    }

    public init(
        context: AccountContext,
        messageId: EngineMessage.Id,
        peerTitle: String,
        provider: VoiceTranscriptProvider = ServerVoiceTranscriptProvider()
    ) {
        self.context = context
        self.messageId = messageId
        self.peerTitle = peerTitle
        self.provider = provider

        super.init(navigationBarPresentationData: nil)

        self.statusBar.statusBarStyle = .Ignore
        self.automaticallyControlPresentationContextLayout = false

        self.ready.set(.single(true))
    }

    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func loadDisplayNode() {
        self.displayNode = VoiceTranscriptScreenNode(
            context: self.context,
            messageId: self.messageId,
            peerTitle: self.peerTitle,
            provider: self.provider,
            getController: { [weak self] in
                return self
            },
            requestDismiss: { [weak self] in
                self?.dismiss()
            },
            requestReply: { [weak self] messageId, fragment in
                guard let self else {
                    return
                }
                // The sheet's own navigation controller is gone once it has been dismissed, so take it first.
                let navigationController = self.navigationController as? NavigationController
                // The usual case: the chat of the voice message is right under the sheet. Once the sheet is gone the reply is set up
                // in that chat directly, instead of opening the chat again and scrolling to the message first. Setting it up while
                // the sheet is still sliding away made the chat's layout and the keyboard compete with the slide, so it waits.
                let chat = navigationController?.viewControllers.last(where: {
                    guard let chat = $0 as? ChatController else {
                        return false
                    }
                    return chat.accountId == self.context.account.id && chat.chatLocation.peerId == messageId.peerId
                }) as? ChatController
                if let fragment {
                    VoiceReplyFragmentStore.shared.set(fragment, for: messageId, accountId: self.context.account.id.int64)
                }
                self.dismiss(completion: { [weak self, weak chat] in
                    if let chat, chat.setupReply(toMessageId: messageId) {
                        return
                    }
                    self?.openReply(messageId: messageId, fragment: fragment, navigationController: navigationController)
                })
            }
        )
        self.displayNodeDidLoad()
    }

    /// Opens the chat of the voice message with a reply to it already in the input panel. For a fragment of the voice message,
    /// the panel shows the time and the words that were chosen; without one it is a reply to the whole voice message.
    private func openReply(messageId: EngineMessage.Id, fragment: VoiceReplyFragment?, navigationController: NavigationController?) {
        guard let navigationController else {
            return
        }
        let context = self.context
        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: messageId.peerId))
        |> deliverOnMainQueue).start(next: { peer in
            guard let peer else {
                return
            }
            // The chat sets the reply up by message id alone, so a chosen fragment is handed over through the store.
            if let fragment {
                VoiceReplyFragmentStore.shared.set(fragment, for: messageId, accountId: context.account.id.int64)
            }
            context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer), subject: .message(id: .id(messageId), highlight: ChatControllerSubject.MessageHighlight(quote: nil), timecode: nil, setupReply: true)))
        })
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        if !self.animatedIn {
            self.animatedIn = true
            self.controllerNode.animateIn()
        }
    }

    override public func dismiss(completion: (() -> Void)? = nil) {
        self.controllerNode.animateOut(completion: { [weak self] in
            if let _ = self?.navigationController {
                self?.dismiss(animated: false, completion: nil)
            } else {
                self?.presentingViewController?.dismiss(animated: false, completion: nil)
            }
            completion?()
        })
    }

    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)

        self.controllerNode.containerLayoutUpdated(layout, transition: transition)
    }
}

// MARK: - Node

private final class VoiceTranscriptScreenNode: ViewControllerTracingNode, UIGestureRecognizerDelegate {
    private let context: AccountContext
    private var messageId: EngineMessage.Id
    private var peerTitle: String
    private var provider: VoiceTranscriptProvider
    private let getController: () -> ViewController?
    private let requestDismiss: () -> Void
    private let requestReply: (EngineMessage.Id, VoiceReplyFragment?) -> Void

    private let presentationData: PresentationData
    private var validLayout: ContainerViewLayout?

    private let dimNode: ASDisplayNode
    private let contentNode: ASDisplayNode
    private let sheetNode: ASDisplayNode
    private let grabberNode: ASDisplayNode

    private let headerButtons = ComponentView<Empty>()
    private let title = ComponentView<Empty>()
    private let tabsBackgroundContainer = GlassBackgroundContainerView()
    private let tabsBackgroundView = GlassBackgroundView()
    private let tabs = ComponentView<Empty>()
    /// The AI Summary tab has no player: it ends with this button instead.
    private let closeButton = UIButton(type: .custom)
    /// The fade with a blur under the big button, as under the fixed buttons of other sheets, so the content does not run into it.
    private let summaryEdgeEffect = EdgeEffectView()
    private var summaryEdgeEffectSize = CGSize()
    private let sheetMaskLayer = CAShapeLayer()
    /// Everything inside the sheet is laid out at one fixed width in here, so expanding the sheet never re-wraps the text.
    private let innerView = UIView()
    private let linkTarget = VoiceTranscriptLinkTarget()
    private var expansionLink: CADisplayLink?
    private var expansionAnimation: (from: CGFloat, to: CGFloat, start: Double, duration: Double)?
    /// How far the search is open: 0 is the sheet as it is, 1 is the search bar in place of the header, with the list under it
    /// and the player gone. It is animated on the same display link, with the same curve, as the expansion, so the header, the
    /// list, the player and the sheet itself move together.
    private var searchProgress: CGFloat = 0.0
    private var searchAnimation: (from: CGFloat, to: CGFloat, start: Double, duration: Double)?
    private var listTopSearch: CGFloat = 0.0
    private var topExpanded: CGFloat = 0.0
    private var topCollapsed: CGFloat = 0.0
    private var contentWidth: CGFloat = 0.0
    private var controlsHeight: CGFloat = 0.0
    private var listTop: CGFloat = 0.0
    /// The search field of the chat list (glass style), so the search looks exactly like the one on the main page.
    private var searchBar: SearchBarNode?
    private let syncButton = VoiceTranscriptSyncButton()
    private var isPlayingNow = false
    private var isActiveRowVisible = true
    private var isSearching = false
    private var scrubbingTime: Double?
    private var animatesComponents = false
    /// Whether the dialog has a voice message after this one and before it: the menu's Next and Previous follow it.
    private var hasNextVoice = false
    private var hasPreviousVoice = false
    private var isSwitchingTabs = false
    private var messageDuration: Double?
    // Fail closed until the source message and chat protection policy are loaded.
    private var canExportText = false
    private weak var activeTextExportController: ViewController?
    private var panStartExpansion: CGFloat = 0.0
    private var didRequestTranscript = false
    private var didRequestSummary = false
    /// When the transcript started to load: one that took a while was asked of the server, and costs a free try.
    private var transcriptLoadingStartTime: Double?
    private let transcriptDisposable = MetaDisposable()
    private let summaryDisposable = MetaDisposable()

    private let transcriptView: VoiceTranscriptListView
    private let summaryView: VoiceSummaryView
    private let controlsView: VoiceTranscriptControlsView

    private enum Tab: String {
        case transcript
        case summary
    }
    private var selectedTab: Tab = .transcript

    /// 0 is the floating card with side insets, 1 is the expanded full-width sheet.
    private var expansion: CGFloat = 0.0
    private var expandDistance: CGFloat = 1.0

    private var transcript: VoiceTranscript?
    private var statusValue: MediaPlayerStatus?
    private var displayLinkTimer: SwiftSignalKit.Timer?
    private var stateDisposable: Disposable?
    private let messageDisposable = MetaDisposable()

    private static let cardInset: CGFloat = 6.0
    private static let closeButtonHeight: CGFloat = 50.0
    private static let closeButtonInset: CGFloat = 22.0
    /// The sheet first opens at 65% of the screen height.
    private static let collapsedHeightFraction: CGFloat = 0.65

    init(
        context: AccountContext,
        messageId: EngineMessage.Id,
        peerTitle: String,
        provider: VoiceTranscriptProvider,
        getController: @escaping () -> ViewController?,
        requestDismiss: @escaping () -> Void,
        requestReply: @escaping (EngineMessage.Id, VoiceReplyFragment?) -> Void
    ) {
        self.context = context
        self.messageId = messageId
        self.peerTitle = peerTitle
        self.provider = provider
        self.getController = getController
        self.requestDismiss = requestDismiss
        self.requestReply = requestReply
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }

        let theme = self.presentationData.theme

        self.dimNode = ASDisplayNode()
        self.dimNode.backgroundColor = UIColor(white: 0.0, alpha: 0.4)

        self.contentNode = ASDisplayNode()

        self.sheetNode = ASDisplayNode()
        self.sheetNode.backgroundColor = theme.list.modalBlocksBackgroundColor

        self.grabberNode = ASDisplayNode()
        self.grabberNode.backgroundColor = theme.list.controlSecondaryColor
        self.grabberNode.cornerRadius = 3.0

        self.transcriptView = VoiceTranscriptListView(theme: theme)
        self.summaryView = VoiceSummaryView(theme: theme, strings: self.presentationData.strings, baseFontSize: voiceSummaryBaseFontSize(self.presentationData.listsFontSize))
        self.controlsView = VoiceTranscriptControlsView(theme: theme, lottieSettings: context.lottieRenderingSettings)

        super.init()

        self.addSubnode(self.dimNode)
        self.addSubnode(self.contentNode)
        self.contentNode.addSubnode(self.sheetNode)

        self.sheetNode.view.addSubview(self.innerView)
        self.innerView.addSubview(self.transcriptView)
        self.innerView.addSubview(self.summaryView)
        self.innerView.addSubview(self.controlsView)
        self.innerView.addSubview(self.syncButton)
        self.syncButton.configure(title: self.presentationData.strings.VoiceTranscript_Synchronize, textColor: theme.list.itemPrimaryTextColor, isDark: theme.overallDarkAppearance)
        self.syncButton.pressed = { [weak self] in
            self?.transcriptView.resumeFollowing()
        }
        self.transcriptView.activeRowVisibilityChanged = { [weak self] visible in
            self?.isActiveRowVisible = visible
            self?.updateSyncButton(animated: true)
        }
        self.innerView.addSubview(self.closeButton)
        self.innerView.insertSubview(self.summaryEdgeEffect, belowSubview: self.closeButton)
        self.summaryEdgeEffect.isUserInteractionEnabled = false
        self.summaryEdgeEffect.isHidden = true
        // The button is Share under the summary: it is dimmed and does nothing until there is a real summary to share.
        self.closeButton.setTitle(self.presentationData.strings.Conversation_ContextMenuShare, for: .normal)
        self.closeButton.isEnabled = false
        self.closeButton.setTitleColor(theme.list.itemCheckColors.foregroundColor, for: .normal)
        self.closeButton.titleLabel?.font = Font.semibold(17.0)
        self.closeButton.setTitleColor(theme.list.itemCheckColors.foregroundColor.withAlphaComponent(0.7), for: .disabled)
        self.closeButton.backgroundColor = self.closeButtonFill(isEnabled: false)
        self.closeButton.layer.cornerRadius = VoiceTranscriptScreenNode.closeButtonHeight / 2.0
        self.closeButton.isHidden = true
        self.closeButton.isUserInteractionEnabled = false
        self.closeButton.addAction(UIAction { [weak self] _ in
            self?.closeButtonPressed()
        }, for: .touchUpInside)
        self.summaryView.copied = { [weak self] in
            self?.showCopiedToast()
        }
        self.summaryView.stateChanged = { [weak self] in
            self?.updateCloseButtonTitle()
        }
        self.sheetNode.addSubnode(self.grabberNode)
        self.innerView.addSubview(self.tabsBackgroundContainer)
        self.tabsBackgroundContainer.contentView.addSubview(self.tabsBackgroundView)
        self.sheetNode.layer.mask = self.sheetMaskLayer

        self.summaryView.isHidden = true

        self.transcriptView.canExportText = { [weak self] in self?.canExportText == true }
        self.summaryView.canExportText = { [weak self] in self?.canExportText == true }

        self.transcriptView.seekTo = { [weak self] time in
            self?.seek(to: time)
        }
        self.transcriptView.requestReply = { [weak self] text, timeText in
            guard let self, self.canExportText else {
                return
            }
            self.requestReply(self.messageId, VoiceReplyFragment(timeText: timeText, text: text))
        }
        self.transcriptView.requestTranslate = { [weak self] text in
            self?.presentTranslate(text: text)
        }
        self.transcriptView.requestShareQuote = { [weak self] text, timeText in
            self?.presentShareQuote(text: text, timeText: timeText)
        }
        self.transcriptView.presentationData = self.presentationData
        self.transcriptView.consumeScroll = { [weak self] delta in
            return self?.consumeExpansion(delta: delta) ?? 0.0
        }
        self.transcriptView.scrollEnded = { [weak self] in
            return self?.snapExpansion() ?? false
        }
        // The ticked tasks are kept for each voice message, so they are still ticked the next time the sheet is opened.
        self.summaryView.loadTaskStates = { [weak self] in
            guard let self else { return [:] }
            return (UserDefaults.standard.dictionary(forKey: self.tasksKey) as? [String: Bool]) ?? [:]
        }
        self.summaryView.saveTaskStates = { [weak self] states in
            guard let self, self.canExportText else { return }
            UserDefaults.standard.set(states, forKey: self.tasksKey)
        }
        self.summaryView.itemMenuRequested = { [weak self] sourceView, setActive, text, time in
            self?.presentItemMenu(sourceView: sourceView, setActive: setActive, text: text, time: time)
        }
        self.summaryView.seekTo = { [weak self] time in
            guard let self else {
                return
            }
            // A key point takes the listener to that moment in the Transcript tab.
            self.seek(to: time)
            self.selectTab(.transcript)
            self.transcriptView.scrollToTime(time)
        }
        self.summaryView.consumeScroll = { [weak self] delta in
            return self?.consumeExpansion(delta: delta) ?? 0.0
        }
        self.summaryView.scrollEnded = { [weak self] in
            return self?.snapExpansion() ?? false
        }

        self.controlsView.seekTo = { [weak self] time in
            self?.scrubbingTime = nil
            self?.seek(to: time)
        }
        self.controlsView.scrubbingChanged = { [weak self] time in
            guard let self else {
                return
            }
            self.scrubbingTime = time
            if let time {
                // The transcript follows the finger while the waveform is dragged.
                self.transcriptView.currentTime = time
            }
        }
        self.controlsView.openMoreMenu = { [weak self] sourceView in
            self?.presentMoreMenu(sourceView: sourceView)
        }
        self.controlsView.togglePlayPause = { [weak self] in
            self?.context.sharedContext.mediaManager.playlistControl(.playback(.togglePlayPause), type: .voice)
        }
        // Back and forward five seconds within the voice message.
        self.controlsView.skip = { [weak self] delta in
            guard let self, let status = self.statusValue else {
                return
            }
            let target = min(max(0.0, self.currentTime(status: status) + delta), status.duration)
            self.seek(to: target)
        }
        self.controlsView.openRateMenu = { [weak self] referenceNode, gesture in
            self?.presentRateMenu(referenceNode: referenceNode, gesture: gesture)
        }
        self.controlsView.cycleRate = { [weak self] in
            guard let self, let status = self.statusValue else {
                return
            }
            let next: AudioPlaybackRate
            if status.baseRate < 1.25 {
                next = .x1_5
            } else if status.baseRate < 1.75 {
                next = .x2
            } else {
                next = .x1
            }
            self.context.sharedContext.mediaManager.playlistControl(.setBaseRate(next), type: .voice)
        }

        self.stateDisposable = (context.sharedContext.mediaManager.globalMediaPlayerState
        |> deliverOnMainQueue).start(next: { [weak self] state in
            guard let self else {
                return
            }
            if let (_, valueOrLoading, type) = state, case .voice = type, case let .state(value) = valueOrLoading {
                if let itemId = value.item.id as? PeerMessagesMediaPlaylistItemId, itemId.messageId != self.messageId {
                    self.switchMessage(itemId.messageId, item: value.item)
                }
                self.hasNextVoice = value.nextItem != nil
                self.hasPreviousVoice = value.previousItem != nil
                self.updateStatus(value.status)
            }
        })

        self.loadMessage()

        self.displayLinkTimer = SwiftSignalKit.Timer(timeout: 0.05, repeat: true, completion: { [weak self] in
            self?.tick()
        }, queue: Queue.mainQueue())
        self.displayLinkTimer?.start()
    }

    deinit {
        self.stateDisposable?.dispose()
        self.messageDisposable.dispose()
        self.transcriptDisposable.dispose()
        self.summaryDisposable.dispose()
        self.displayLinkTimer?.invalidate()
        self.expansionLink?.invalidate()
    }

    override func didLoad() {
        super.didLoad()

        self.dimNode.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.dimTapped)))

        // On the node's own view, not on the sheet: the drag moves the sheet, and a recognizer on a view that moves with
        // the finger measures its translation against itself.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(self.panGesture(_:)))
        pan.delegate = self
        self.view.addGestureRecognizer(pan)
    }

    @objc private func dimTapped(_ recognizer: UITapGestureRecognizer) {
        if case .ended = recognizer.state {
            self.requestDismiss()
        }
    }

    /// Made when the search is first opened, so that opening the sheet does not pay for it.
    private func ensureSearchBar() -> SearchBarNode {
        if let searchBar = self.searchBar {
            return searchBar
        }
        let theme = self.presentationData.theme
        let searchBar = SearchBarNode(
            theme: SearchBarNodeTheme(theme: theme, hasBackground: false, hasSeparator: false),
            presentationTheme: theme,
            strings: self.presentationData.strings,
            fieldStyle: .glass,
            forceSeparator: false,
            displayBackground: false
        )
        self.searchBar = searchBar
        self.innerView.addSubview(searchBar.view)
        searchBar.placeholderString = NSAttributedString(string: self.presentationData.strings.Common_Search, font: Font.regular(17.0), textColor: theme.rootController.navigationSearchBar.inputPlaceholderTextColor)
        searchBar.textUpdated = { [weak self] text, _ in
            let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self?.transcriptView.searchQuery = query.isEmpty ? nil : query
        }
        searchBar.textReturned = { [weak self] _ in
            self?.searchBar?.deactivate(clear: false)
        }
        searchBar.cancel = { [weak self] in
            self?.endSearch()
        }
        return searchBar
    }

    /// The fill of the big button. A button that cannot be used yet is not made see-through (the content scrolls under it): its
    /// colour is mixed with the colour of the sheet instead.
    private func closeButtonFill(isEnabled: Bool) -> UIColor {
        let theme = self.presentationData.theme
        let fill = theme.list.itemCheckColors.fillColor
        return isEnabled ? fill : fill.mixedWith(theme.list.modalBlocksBackgroundColor, alpha: 0.55)
    }

    /// The big button under the summary is always "Share": it is dimmed until there is a real summary to share, so its title
    /// does not change when the summary arrives.
    private func updateCloseButtonTitle() {
        let isShareable = self.canExportText && self.summaryView.shareableText != nil
        self.closeButton.isEnabled = isShareable
        #if DEBUG
        switch self.summaryView.state {
        case .loading:
            print("[VoiceSummary] Share is off: the summary is still being made")
        case .unavailable:
            print("[VoiceSummary] Share is off: there is no summary")
        case let .ready(summary):
            print("[VoiceSummary] Share is \(isShareable ? "on" : "off"): the summary is ready, placeholder: \(summary.isPlaceholder)")
        }
        #endif
        UIView.animate(withDuration: 0.2, delay: 0.0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
            self.closeButton.backgroundColor = self.closeButtonFill(isEnabled: isShareable)
        })
    }

    /// The translator of the app, with `text` in it.
    private func presentTranslate(text: String) {
        guard self.canExportText, let controller = self.getController() else {
            return
        }
        let context = self.context
        let messageId = self.messageId
        Task { @MainActor [weak self, weak controller] in
            let translateController = await context.sharedContext.makeTextProcessingScreen(
                context: context,
                theme: nil,
                // The information button is left out: this sheet is already one of two on screen, and the information screen
                // it opens could not be shown over them.
                mode: .translate(fromLanguage: nil, applyResult: nil, displaysInfoButton: false),
                inputText: .plain(text: text, entities: []),
                copyResult: { [weak self] result in
                    guard let self, self.canExportText, self.messageId == messageId else { return }
                    if case let .plain(text, _) = result {
                        UIPasteboard.general.string = text
                    }
                },
                translateChat: nil
            )
            guard let self, self.canExportText, self.messageId == messageId else { return }
            self.activeTextExportController = translateController
            controller?.present(translateController, in: .window(.root))
        }
    }

    private func closeButtonPressed() {
        guard self.canExportText else { return }
        guard let text = self.summaryView.shareableText, let controller = self.getController() else {
            self.requestDismiss()
            return
        }
        let shareController = self.context.sharedContext.makeShareController(context: self.context, params: ShareControllerParams(subject: .text(text), externalShare: false))
        self.activeTextExportController = shareController
        controller.present(shareController, in: .window(.root))
    }

    /// Recipient-visible plain text, using Telegram's confirmation UI. Never sends automatically.
    private func presentShareQuote(text: String, timeText: String) {
        guard self.canExportText, let controller = self.getController() else { return }
        let quote = timeText + " — " + text
        let shareController = self.context.sharedContext.makeShareController(context: self.context, params: ShareControllerParams(subject: .text(quote), externalShare: false))
        self.activeTextExportController = shareController
        controller.present(shareController, in: .window(.root))
    }

    /// The search bar, in the place of the header. Only its own layout; the rest of the sheet is not laid out again for it.
    private func layoutSearchBar(width: CGFloat, transition: ContainedViewLayoutTransition) {
        let barFrame = CGRect(x: 0.0, y: 16.0, width: width, height: 44.0)
        let searchBar = self.ensureSearchBar()
        transition.updateFrame(node: searchBar, frame: barFrame)
        searchBar.updateLayout(boundingSize: barFrame.size, leftInset: 0.0, rightInset: 0.0, transition: transition)
    }

    /// Made a moment after the sheet has opened, so that pressing search does not pay for it in the middle of the animation.
    private func prepareSearchBar() {
        if self.searchBar != nil || self.contentWidth <= 0.0 {
            return
        }
        let searchBar = self.ensureSearchBar()
        searchBar.view.isHidden = true
        self.layoutSearchBar(width: self.contentWidth, transition: .immediate)
    }

    private func beginSearch() {
        if self.isSearching {
            return
        }
        self.isSearching = true
        self.selectedTab = .transcript
        self.transcriptView.isHidden = false
        self.summaryView.isHidden = true
        self.transcriptView.isAutoScrollEnabled = false
        // As little as possible happens before the first frame of the animation. The search bar exists already (or is made here
        // and laid out on its own), and the keyboard comes when the animation has finished: it takes the main thread for a while the
        // first time, and the animation runs on it.
        self.prepareSearchBar()
        if self.searchBar == nil {
            self.layoutSearchBar(width: self.contentWidth, transition: .immediate)
        }
        self.searchBar?.view.alpha = 0.0
        self.animateSearch(to: 1.0)
        self.animateExpansion(to: 1.0, duration: 0.4)
        // The words are not highlighted while searching; it is applied after the first frame, not before it.
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.transcriptView.isSearchMode = self.isSearching
        }
    }

    private func endSearch() {
        if !self.isSearching {
            return
        }
        self.isSearching = false
        self.transcriptView.isSearchMode = false
        self.searchBar?.text = ""
        self.searchBar?.deactivate(clear: false)
        self.transcriptView.searchQuery = nil
        self.transcriptView.isAutoScrollEnabled = true
        self.applyPageVisibility()
        self.animateSearch(to: 0.0)
    }

    /// The search is open or closed: the player and the header are put back, or taken away, for good.
    private func searchAnimationFinished() {
        if self.searchProgress <= 0.001 {
            self.searchBar?.view.isHidden = true
        }
        self.applyPageVisibility()
        if self.isSearching && self.searchProgress >= 0.999 {
            self.searchBar?.activate()
        }
    }

    private func animateSearch(to target: CGFloat, duration: Double = 0.4) {
        self.searchAnimation = (self.searchProgress, target, CACurrentMediaTime(), duration)
        self.ensureDisplayLink()
    }

    /// The "more" menu above the button: the actions on the whole voice message, then the neighbouring voice messages. It is
    /// Telegram's own vertical context menu, which opens above the button because there is no room under it.
    private func showCopiedToast() {
        guard let controller = self.getController() else {
            return
        }
        let presentationData = self.presentationData
        controller.present(UndoOverlayController(presentationData: presentationData, content: .copy(text: presentationData.strings.Conversation_TextCopied), elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .window(.root))
    }

    /// The menu of a key point or a question: Reply (to the voice message, with the item and its time quoted) and Copy. It opens right
    /// under the item, and above it only when there is no room below.
    private func presentItemMenu(sourceView: UIView, setActive: @escaping (Bool) -> Void, text: String, time: Double) {
        guard self.canExportText, let controller = self.getController() else {
            return
        }
        let presentationData = self.presentationData
        let strings = presentationData.strings

        let sourceMessageId = self.messageId

        func icon(_ name: String) -> (PresentationTheme) -> UIImage? {
            return { theme in
                return generateTintedImage(image: UIImage(bundleImageName: name), color: theme.contextMenu.primaryColor)
            }
        }
        var items: [ContextMenuItem] = []
        items.append(.action(ContextMenuActionItem(text: strings.Conversation_ContextMenuReply, icon: icon("Chat/Context Menu/Reply"), action: { [weak self] _, f in
            f(.default)
            guard let self else {
                return
            }
            guard self.canExportText, self.messageId == sourceMessageId else { return }
            self.requestReply(self.messageId, VoiceReplyFragment(timeText: formatVoiceTranscriptTime(time), text: text))
        })))
        items.append(.action(ContextMenuActionItem(text: strings.Conversation_ContextMenuCopy, icon: icon("Chat/Context Menu/Copy"), action: { [weak self] _, f in
            f(.default)
            guard let self, self.canExportText, self.messageId == sourceMessageId else { return }
            UIPasteboard.general.string = text
            self.showCopiedToast()
        })))
        items.append(.action(ContextMenuActionItem(text: strings.Conversation_ContextMenuShare, icon: icon("Chat/Context Menu/Forward"), action: { [weak self] _, f in
            f(.default)
            guard let self, self.messageId == sourceMessageId else { return }
            self.presentShareQuote(text: text, timeText: formatVoiceTranscriptTime(time))
        })))
        let contextController = makeContextController(
            presentationData: presentationData,
            source: .reference(VoiceTranscriptItemContextSource(referenceView: sourceView)),
            items: .single(ContextController.Items(content: .list(items))),
            gesture: nil
        )
        setActive(true)
        contextController.dismissed = {
            setActive(false)
        }
        controller.presentInGlobalOverlay(contextController)
    }

    private func presentMoreMenu(sourceView: UIView) {
        guard let controller = self.getController() else {
            return
        }
        let presentationData = self.presentationData
        let strings = presentationData.strings
        let context = self.context
        let messageId = self.messageId
        let mediaManager = context.sharedContext.mediaManager
        let transcriptText = (self.transcript?.segments.map { $0.text }.joined(separator: " ") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTranscript = !transcriptText.isEmpty
        let hasSelection = self.transcriptView.selectedTextAndTimes() != nil
        let hasSearchQuery = !(self.transcriptView.searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let copyTranscriptTitle: String
        if hasSelection {
            copyTranscriptTitle = strings.Conversation_ContextMenuCopy
        } else if hasSearchQuery {
            copyTranscriptTitle = NSLocalizedString("VoiceTranscript.CopySearchQuery", value: "Copy Search Query", comment: "Copy only the current transcript search query")
        } else {
            copyTranscriptTitle = strings.VoiceTranscript_CopyTranscript
        }

        func icon(_ name: String) -> (PresentationTheme) -> UIImage? {
            return { theme in
                return generateTintedImage(image: UIImage(bundleImageName: name), color: theme.contextMenu.primaryColor)
            }
        }
        // Next / previous have no line icon in the app's context menu assets (only the filled music-player ones), so they
        // are SF Symbols, drawn like the other menu icons.
        func symbolIcon(_ name: String) -> (PresentationTheme) -> UIImage? {
            return { theme in
                return generateTintedImage(image: voiceTranscriptSymbolImage(name, fit: 18.0, weight: .regular), color: theme.contextMenu.primaryColor)
            }
        }

        var items: [ContextMenuItem] = []
        if let transcript = self.transcript {
            let timingDescription: String
            switch transcript.timingProvenance {
            case .estimated:
                timingDescription = NSLocalizedString("VoiceTranscript.TimingEstimated", value: "Estimated timing — word seeks may be inaccurate", comment: "Transcript timing accuracy")
            case .measured:
                timingDescription = NSLocalizedString("VoiceTranscript.TimingMeasured", value: "Speech-recognizer timing — recognition can contain errors", comment: "Transcript timing accuracy")
            case .aligned:
                timingDescription = NSLocalizedString("VoiceTranscript.TimingAligned", value: "Server words matched to speech timing — not guaranteed exact", comment: "Strict lexical alignment timing accuracy")
            case .demo:
                timingDescription = NSLocalizedString("VoiceTranscript.TimingDemo", value: "Demo transcript — not derived from this recording", comment: "Transcript timing accuracy")
            }
            items.append(.action(ContextMenuActionItem(text: timingDescription, textColor: .disabled, icon: symbolIcon("info.circle"), action: { _, f in f(.default) })))
        }
        items.append(.action(ContextMenuActionItem(text: NSLocalizedString("VoiceTranscript.UseAlignedTranscript", value: "Match server words to speech timing (strict)", comment: "Strict alignment: refuses mismatched speech instead of guessing"), icon: symbolIcon("text.magnifyingglass"), action: { [weak self] _, f in
            f(.default)
            self?.switchTranscriptProvider(AlignedVoiceTranscriptProvider())
        })))
        let usesMeasuredTiming = self.provider is RecognizedVoiceTranscriptProvider || self.provider is AlignedVoiceTranscriptProvider
        let timingActionTitle = usesMeasuredTiming
            ? NSLocalizedString("VoiceTranscript.UseServerTranscript", value: "Use server transcript (estimated timing)", comment: "Switch transcript provider")
            : NSLocalizedString("VoiceTranscript.UseMeasuredTranscript", value: "Use speech timing (device language)", comment: "Explicitly opt into speech recognition with the device locale")
        items.append(.action(ContextMenuActionItem(text: timingActionTitle, icon: symbolIcon("waveform"), action: { [weak self] _, f in
            f(.default)
            guard let self else { return }
            if usesMeasuredTiming {
                self.switchTranscriptProvider(ServerVoiceTranscriptProvider())
            } else {
                self.switchTranscriptProvider(RecognizedVoiceTranscriptProvider())
            }
        })))
        items.append(.action(ContextMenuActionItem(text: strings.Conversation_ContextMenuReply, icon: icon("Chat/Context Menu/Reply"), action: { [weak self] _, f in
            f(.default)
            // A reply to the whole voice message.
            self?.requestReply(messageId, nil)
        })))
        items.append(.action(ContextMenuActionItem(text: copyTranscriptTitle, textColor: hasTranscript ? .primary : .disabled, icon: icon("Chat/Context Menu/Copy"), action: { [weak self] _, f in
            f(.default)
            guard let self, self.canExportText, self.messageId == messageId, hasTranscript else {
                return
            }
            let selectedText = self.transcriptView.selectedTextAndTimes()?.text
            let searchQuery = self.transcriptView.searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
            UIPasteboard.general.string = selectedText ?? searchQuery.flatMap { $0.isEmpty ? nil : $0 } ?? transcriptText
            if selectedText != nil {
                self.transcriptView.clearSelection()
            }
        })))
        items.append(.action(ContextMenuActionItem(text: strings.VoiceTranscript_TranslateTranscript, textColor: hasTranscript ? .primary : .disabled, icon: icon("Chat/Context Menu/Translate"), action: { [weak self] _, f in
            f(.default)
            guard let self, self.canExportText, self.messageId == messageId, hasTranscript else {
                return
            }
            // The translator of the app, with the whole transcript in it.
            self.presentTranslate(text: transcriptText)
        })))
        items.append(.action(ContextMenuActionItem(text: strings.Conversation_ContextMenuForward, icon: icon("Chat/Context Menu/Forward"), action: { [weak self, weak controller] _, f in
            f(.default)
            guard let self, self.canExportText, self.messageId == messageId else { return }
            // The whole voice message, through the chat picker the app forwards with.
            let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
            |> deliverOnMainQueue).startStandalone(next: { [weak self, weak controller] message in
                guard let self, self.canExportText, self.messageId == messageId,
                      let message, !message._asMessage().isCopyProtected(), let controller else {
                    return
                }
                let shareController = context.sharedContext.makeShareController(context: context, params: ShareControllerParams(subject: .messages([message._asMessage()]), externalShare: false))
                self.activeTextExportController = shareController
                controller.present(shareController, in: .window(.root))
            })
        })))
        items.append(.separator)
        items.append(.action(ContextMenuActionItem(text: strings.VoiceTranscript_NextVoice, textColor: self.hasNextVoice ? .primary : .disabled, icon: symbolIcon("forward.end"), action: { [weak self] _, f in
            f(.default)
            if self?.hasNextVoice == true {
                mediaManager.playlistControl(.next, type: .voice)
            }
        })))
        items.append(.action(ContextMenuActionItem(text: strings.VoiceTranscript_PreviousVoice, textColor: self.hasPreviousVoice ? .primary : .disabled, icon: symbolIcon("backward.end"), action: { [weak self] _, f in
            f(.default)
            if self?.hasPreviousVoice == true {
                mediaManager.playlistControl(.previous, type: .voice)
            }
        })))

        let contextController = makeContextController(
            presentationData: presentationData,
            source: .reference(VoiceTranscriptViewContextSource(referenceView: sourceView)),
            items: .single(ContextController.Items(content: .list(items))),
            gesture: nil
        )
        controller.presentInGlobalOverlay(contextController)
    }

    /// The same speed menu the top playback panel shows: four presets and a slider.
    private func presentRateMenu(referenceNode: ContextReferenceContentNode, gesture: ContextGesture?) {
        guard let controller = self.getController() else {
            return
        }
        let presentationData = self.presentationData
        let strings = presentationData.strings
        let theme = presentationData.theme
        let currentRate = self.statusValue?.baseRate ?? 1.0
        let mediaManager = self.context.sharedContext.mediaManager

        let sliderValuePromise = ValuePromise<Double?>(nil)
        let sliderItem: ContextMenuItem = .custom(SliderContextItem(minValue: 0.2, maxValue: 2.5, value: currentRate, valueChanged: { newValue, _ in
            let normalized = round(newValue * 10.0) / 10.0
            mediaManager.playlistControl(.setBaseRate(AudioPlaybackRate(normalized)), type: .voice)
            sliderValuePromise.set(normalized)
        }), true)

        let speeds: [(String, AudioPlaybackRate)] = [
            ("0.5x", .x0_5),
            (strings.PlaybackSpeed_Normal, .x1),
            ("1.5x", .x1_5),
            ("2x", .x2)
        ]
        var presetItems: [ContextMenuItem] = []
        for (text, rate) in speeds {
            let isSelected = AudioPlaybackRate(currentRate) == rate
            presetItems.append(.action(ContextMenuActionItem(text: text, icon: { _ in return nil }, iconSource: ContextMenuActionItemIconSource(size: CGSize(width: 24.0, height: 24.0), signal: sliderValuePromise.get()
            |> map { value in
                if isSelected && value == nil {
                    return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Check"), color: theme.contextMenu.primaryColor)
                } else {
                    return UIImage()
                }
            }), action: { _, f in
                f(.default)
                mediaManager.playlistControl(.setBaseRate(rate), type: .voice)
            })))
        }

        let contextController = makeContextController(
            presentationData: presentationData,
            source: .reference(VoiceTranscriptRateContextSource(controller: controller, sourceNode: referenceNode)),
            items: .single(ContextController.Items(content: .twoLists(presetItems, [sliderItem]))),
            gesture: gesture
        )
        controller.presentInGlobalOverlay(contextController)
    }

    /// Which of the two pages is on screen: the transcript with the player, or the summary with the Close button. While one
    /// replaces the other both are shown, and this is applied again when it ends.
    private func applyPageVisibility() {
        if self.isSwitchingTabs {
            return
        }
        let transcript = self.selectedTab == .transcript
        self.transcriptView.isHidden = !transcript
        self.summaryView.isHidden = transcript
        // The player stays until the search has fully opened (it fades out on the way), and is back at once when it closes.
        let isSearchOpen = self.isSearching && self.searchProgress >= 0.999
        self.controlsView.isHidden = isSearchOpen || !transcript
        self.syncButton.isHidden = isSearchOpen || !transcript
        self.closeButton.isHidden = self.isSearching || transcript
        self.summaryEdgeEffect.isHidden = self.isSearching || transcript
    }

    private var pageViews: (transcript: [UIView], summary: [UIView]) {
        return ([self.transcriptView, self.controlsView, self.syncButton], [self.summaryView, self.summaryEdgeEffect, self.closeButton])
    }

    private func finishTabSwitch() {
        for view in self.pageViews.transcript + self.pageViews.summary {
            view.layer.removeAllAnimations()
            view.transform = .identity
        }
        self.isSwitchingTabs = false
        self.applyPageVisibility()
    }

    /// The two tabs are two pages side by side: choosing the other tab slides the current page out and the other in, the
    /// player and the Close button going with their own content, so nothing fades away in place.
    private func selectTab(_ tab: Tab) {
        if self.selectedTab == tab {
            return
        }
        self.finishTabSwitch()
        self.selectedTab = tab
        if tab == .summary, let transcript = self.transcript {
            self.startSummary(transcript: transcript)
        }
        self.closeButton.isUserInteractionEnabled = tab == .summary
        self.controlsView.isUserInteractionEnabled = tab == .transcript

        if !self.isSearching {
            let toSummary = tab == .summary
            let leaving = toSummary ? self.pageViews.transcript : self.pageViews.summary
            let arriving = toSummary ? self.pageViews.summary : self.pageViews.transcript
            // The sheet's width, not the content's: when the sheet is wide the content is inset from its edges, and a page
            // moved by the content's width alone would still show a sliver at the edge.
            let distance = max(self.contentWidth, self.sheetNode.frame.width)
            let direction: CGFloat = toSummary ? 1.0 : -1.0

            self.isSwitchingTabs = true
            for view in leaving + arriving {
                view.isHidden = false
            }
            for view in arriving {
                view.transform = CGAffineTransform(translationX: direction * distance, y: 0.0)
            }
            UIView.animate(withDuration: 0.45, delay: 0.0, usingSpringWithDamping: 1.0, initialSpringVelocity: 0.0, options: [], animations: {
                for view in leaving {
                    view.transform = CGAffineTransform(translationX: -direction * distance, y: 0.0)
                }
                for view in arriving {
                    view.transform = .identity
                }
            }, completion: { [weak self] _ in
                guard let self else {
                    return
                }
                // Only when this is still the switch that is running (a newer one has already put things right).
                if self.isSwitchingTabs && self.selectedTab == tab {
                    self.finishTabSwitch()
                }
            })
        } else {
            self.applyPageVisibility()
        }

        if let layout = self.validLayout {
            self.animatesComponents = true
            self.containerLayoutUpdated(layout, transition: .animated(duration: 0.3, curve: .spring))
            self.animatesComponents = false
        }
    }

    /// Dragging the content up first grows the card to the full sheet, exactly like the music sheet does: the drag is
    /// spent on the expansion before the content scrolls. Returns how many points of the drag were used.
    private func consumeExpansion(delta: CGFloat) -> CGFloat {
        if self.isSearching {
            return 0.0
        }
        let distance = max(1.0, self.expandDistance)
        let target = min(1.0, max(0.0, self.expansion + delta / distance))
        let consumed = (target - self.expansion) * distance
        if abs(consumed) > 0.0001 {
            self.stopExpansionAnimation()
            self.expansion = target
            self.applyGeometry()
        }
        return consumed
    }

    /// When the finger lifts halfway, the sheet settles on the nearer state. Returns true if it moved.
    private func snapExpansion() -> Bool {
        if self.isSearching || self.expansion < 0.001 || self.expansion > 0.999 {
            return false
        }
        self.animateExpansion(to: self.expansion >= 0.5 ? 1.0 : 0.0)
        return true
    }

    /// One number drives the whole sheet and every frame is recomputed from it, so the sheet, its mask, the list and the
    /// bottom panel always agree. Animating each view separately let them drift apart mid-animation.
    private func animateExpansion(to target: CGFloat, duration: Double = 0.4) {
        self.expansionAnimation = (self.expansion, target, CACurrentMediaTime(), duration)
        self.ensureDisplayLink()
    }

    private func ensureDisplayLink() {
        if self.expansionLink == nil {
            self.linkTarget.action = { [weak self] in
                self?.stepExpansionAnimation()
            }
            let link = CADisplayLink(target: self.linkTarget, selector: #selector(VoiceTranscriptLinkTarget.fire))
            link.add(to: .main, forMode: .common)
            self.expansionLink = link
        }
    }

    private func stepExpansionAnimation() {
        if self.expansionAnimation == nil && self.searchAnimation == nil {
            self.invalidateDisplayLink()
            return
        }
        let now = CACurrentMediaTime()
        var searchFinished = false
        if let animation = self.expansionAnimation {
            let progress = CGFloat(min(1.0, (now - animation.start) / animation.duration))
            // The curve every Telegram spring animation uses (the same one as the standard `.spring` transitions).
            let eased = progress >= 1.0 ? 1.0 : listViewAnimationCurveSystem(progress)
            self.expansion = animation.from + (animation.to - animation.from) * eased
            if progress >= 1.0 {
                self.expansion = animation.to
                self.expansionAnimation = nil
            }
        }
        if let animation = self.searchAnimation {
            let progress = CGFloat(min(1.0, (now - animation.start) / animation.duration))
            let eased = progress >= 1.0 ? 1.0 : listViewAnimationCurveSystem(progress)
            self.searchProgress = animation.from + (animation.to - animation.from) * eased
            if progress >= 1.0 {
                self.searchProgress = animation.to
                self.searchAnimation = nil
                searchFinished = true
            }
        }
        self.applyGeometry()
        if searchFinished {
            self.searchAnimationFinished()
        }
        if self.expansionAnimation == nil && self.searchAnimation == nil {
            self.invalidateDisplayLink()
        }
    }

    private func invalidateDisplayLink() {
        self.expansionLink?.invalidate()
        self.expansionLink = nil
    }

    /// Stops the animation of the expansion only: the search animation, when there is one, goes on.
    private func stopExpansionAnimation() {
        self.expansionAnimation = nil
        if self.searchAnimation == nil {
            self.invalidateDisplayLink()
        }
    }

    private var tasksKey: String {
        let id = self.messageId
        return "voiceSummaryTasks_v2_\(self.context.account.peerId.toInt64())_\(id.peerId.toInt64())_\(id.namespace)_\(id.id)"
    }

    private func loadMessage() {
        let messageId = self.messageId
        self.messageDisposable.set((self.context.engine.data.subscribe(
            TelegramEngine.EngineData.Item.Messages.Message(id: messageId),
            TelegramEngine.EngineData.Item.Peer.CopyProtectionEnabled(id: messageId.peerId),
            TelegramEngine.EngineData.Item.Peer.MyCopyProtectionEnabled(id: messageId.peerId)
        ) |> deliverOnMainQueue).start(next: { [weak self] message, peerProtected, myProtected in
            guard let self, self.messageId == messageId else { return }
            let allowed = voiceTranscriptAllowsTextExport(
                messageExists: message != nil,
                messageProtected: message?._asMessage().isCopyProtected() ?? true,
                peerProtected: peerProtected, myProtected: myProtected,
                isSecret: messageId.peerId.namespace == Namespaces.Peer.SecretChat,
                isViewOnce: message?._asMessage().minAutoremoveOrClearTimeout == viewOnceTimeout
            )
            self.canExportText = allowed
            self.updateCloseButtonTitle()
            guard allowed, let message else {
                self.activeTextExportController?.dismiss()
                self.activeTextExportController = nil
                self.transcriptDisposable.set(nil)
                self.summaryDisposable.set(nil)
                self.didRequestTranscript = false
                self.didRequestSummary = false
                self.transcript = nil
                self.transcriptView.clearSelection()
                self.transcriptView.transcript = nil
                self.transcriptView.placeholder = .unavailable
                self.transcriptView.unavailableMessage = "Transcript unavailable for protected content."
                self.summaryView.state = .unavailable
                return
            }
            // "today at 13:40", "yesterday at 13:40", or the date and time.
            // "today at 13:40" is written with a capital letter at the start of the label: "Today at 13:40".
            let sentText = humanReadableStringForTimestamp(strings: self.presentationData.strings, dateTimeFormat: self.presentationData.dateTimeFormat, timestamp: message.timestamp, alwaysShowTime: true).string
            self.controlsView.sentText = sentText.prefix(1).uppercased() + sentText.dropFirst()
            for media in message.media {
                if let file = media as? TelegramMediaFile {
                    for attribute in file.attributes {
                        if case let .Audio(_, duration, _, _, waveform) = attribute {
                            if let waveform {
                                self.controlsView.waveform = AudioWaveform(bitstream: waveform, bitsPerSample: 5)
                            }
                            self.messageDuration = Double(duration)
                            self.ensureTranscript(duration: Double(duration))
                        }
                    }
                }
            }
        }))
    }

    /// The player moved on to another voice message (previous / next, or the end of this one): the sheet follows it.
    private func switchMessage(_ messageId: EngineMessage.Id, item: SharedMediaPlaylistItem) {
        self.activeTextExportController?.dismiss()
        self.activeTextExportController = nil
        self.canExportText = false
        self.messageId = messageId
        if let displayData = item.displayData, case let .voice(author, _) = displayData, let author {
            self.peerTitle = author.displayTitle(strings: self.presentationData.strings, displayOrder: self.presentationData.nameDisplayOrder)
        }
        self.messageDuration = nil
        self.didRequestTranscript = false
        self.didRequestSummary = false
        self.transcriptDisposable.set(nil)
        self.summaryDisposable.set(nil)
        self.summaryView.state = .loading
        self.transcript = nil
        self.transcriptView.placeholder = nil
        self.transcriptView.unavailableMessage = nil
        self.transcriptLoadingStartTime = nil
        self.transcriptView.transcript = nil
        self.scrubbingTime = nil
        self.controlsView.waveform = nil
        // The new voice's own status follows right after, and the transcript waits for it.
        self.statusValue = nil
        self.loadMessage()
        if let layout = self.validLayout {
            self.containerLayoutUpdated(layout, transition: .immediate)
        }
    }

    /// The summary is made of the transcript, so it starts when the transcript is ready, and shows its skeleton until then.
    private func switchTranscriptProvider(_ provider: VoiceTranscriptProvider) {
        self.transcriptDisposable.set(nil)
        self.summaryDisposable.set(nil)
        self.provider = provider
        self.transcript = nil
        self.transcriptView.transcript = nil
        self.transcriptView.unavailableMessage = nil
        self.transcriptView.placeholder = .loading
        self.summaryView.state = .loading
        self.didRequestTranscript = false
        self.didRequestSummary = false
        self.ensureTranscript(duration: self.statusValue?.duration ?? self.messageDuration ?? 0)
    }

    private func startSummary(transcript: VoiceTranscript) {
        // Opening a transcript must not automatically send its text to the AI service.
        guard self.canExportText, self.selectedTab == .summary, !self.didRequestSummary else { return }
        self.didRequestSummary = true
        let messageId = self.messageId
        self.summaryDisposable.set((self.provider.summary(context: self.context, messageId: self.messageId, transcript: transcript)
        |> deliverOnMainQueue).start(next: { [weak self] state in
            guard let self, self.canExportText, self.messageId == messageId else {
                return
            }
            self.summaryView.state = state
        }))
    }

    /// For an account without Premium, after a transcript was made by the server: how many free ones are left this week, in the
    /// same words and the same tip as in the chat.
    private func showFreeTranscriptionTooltip() {
        if self.context.isPremium {
            return
        }
        let _ = (self.context.engine.data.get(TelegramEngine.EngineData.Item.Configuration.AudioTranscriptionTrial())
        |> deliverOnMainQueue).start(next: { [weak self] trial in
            guard let self, let controller = self.getController(), trial.remainingCount > 0 else {
                return
            }
            let presentationData = self.presentationData
            let text = presentationData.strings.Conversation_FreeTranscriptionLimitTooltip(trial.remainingCount)
            controller.present(UndoOverlayController(presentationData: presentationData, content: .universal(animation: "Transcribe", scale: 0.06, colors: [:], title: nil, text: text, customUndoText: nil, timeout: 5.0), elevatedLayout: false, position: .top, animateInAsReplacement: false, action: { _ in return false }), in: .window(.root))
        })
    }

    /// When the free transcriptions of the week are used up, the empty list says so (and when they come back), instead of the
    /// general "not available".
    private func updateTranscriptUnavailableMessage() {
        if self.context.isPremium {
            return
        }
        let context = self.context
        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Configuration.AudioTranscriptionTrial())
        |> deliverOnMainQueue).start(next: { [weak self] trial in
            guard let self, let cooldownUntilTime = trial.cooldownUntilTime, cooldownUntilTime > Int32(Date().timeIntervalSince1970) else {
                return
            }
            let presentationData = self.presentationData
            let strings = presentationData.strings
            let premiumConfiguration = PremiumConfiguration.with(appConfiguration: context.currentAppConfiguration.with { $0 })
            let time = stringForMediumDate(timestamp: cooldownUntilTime, strings: strings, dateTimeFormat: presentationData.dateTimeFormat)
            let used = strings.Conversation_FreeTranscriptionCooldownTooltip(premiumConfiguration.audioTransciptionTrialCount)
            let wait = strings.Conversation_FreeTranscriptionWaitOrSubscribe(time).string
            // The strings carry markup for the tip of the chat; this is plain text.
            let text = (used + " " + wait).replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "[Telegram Premium]()", with: "Telegram Premium")
            self.transcriptView.unavailableMessage = text
        })
    }

    private func ensureTranscript(duration: Double) {
        // Wait for the player's position so the list opens already scrolled to the spoken word.
        guard self.canExportText, !self.didRequestTranscript, duration.isFinite, duration > 0.0, self.statusValue != nil else {
            return
        }
        self.didRequestTranscript = true
        let messageId = self.messageId
        self.transcriptDisposable.set((self.provider.transcript(context: self.context, messageId: self.messageId, duration: duration)
        |> deliverOnMainQueue).start(next: { [weak self] state in
            guard let self, self.canExportText, self.messageId == messageId else {
                return
            }
            switch state {
            case .loading:
                self.transcriptLoadingStartTime = CACurrentMediaTime()
                self.transcriptView.placeholder = .loading
            case .unavailable:
                self.transcriptView.placeholder = .unavailable
                #if DEBUG
                self.transcriptView.unavailableMessage = "Transcript unavailable\n\n[debug] " + (voiceTranscriptDebugReason ?? "No provider diagnostic")
                #endif
                self.updateTranscriptUnavailableMessage()
                // No transcript, nothing to summarise.
                self.summaryDisposable.set(nil)
                #if DEBUG
                if self.provider is ServerVoiceTranscriptProvider {
                    voiceSummaryDebugReason = voiceTranscriptDebugReason ?? "Telegram did not return transcript text; inspect transcript diagnostics"
                } else {
                    voiceSummaryDebugReason = "speech recognition did not return transcript text"
                }
                #endif
                self.summaryView.state = .unavailable
            case let .ready(transcript):
                self.transcriptView.placeholder = nil
                if let start = self.transcriptLoadingStartTime, CACurrentMediaTime() - start > 0.5 {
                    self.showFreeTranscriptionTooltip()
                }
                self.transcriptLoadingStartTime = nil
                if let status = self.statusValue {
                    self.transcriptView.currentTime = self.currentTime(status: status)
                }
                self.transcript = transcript
                self.transcriptView.transcript = transcript
                self.startSummary(transcript: transcript)
            }
        }))
    }


    private func updateStatus(_ status: MediaPlayerStatus) {
        self.statusValue = status
        self.ensureTranscript(duration: status.duration > 0.0 ? status.duration : (self.messageDuration ?? 0.0))
        self.tick()
    }

    private func currentTime(status: MediaPlayerStatus) -> Double {
        if case .playing = status.status {
            let elapsed = (CACurrentMediaTime() - status.generationTimestamp) * status.baseRate
            return min(status.duration, status.timestamp + max(0.0, elapsed))
        }
        return status.timestamp
    }

    private func seek(to time: Double) {
        guard time.isFinite, let duration = self.statusValue?.duration, duration.isFinite, duration > 0 else {
            return
        }
        let time = min(duration, max(0, time))
        self.context.sharedContext.mediaManager.playlistControl(.seek(time), type: .voice)
        if let status = self.statusValue {
            // Apply immediately so the highlight does not lag behind the player's status round trip.
            self.statusValue = MediaPlayerStatus(generationTimestamp: CACurrentMediaTime(), duration: status.duration, dimensions: status.dimensions, timestamp: time, baseRate: status.baseRate, seekId: status.seekId, status: status.status, soundEnabled: status.soundEnabled)
            self.tick()
        }
    }

    private func tick() {
        guard let status = self.statusValue else {
            return
        }
        let time = self.currentTime(status: status)
        var isPlaying = false
        if case .playing = status.status {
            isPlaying = true
        } else if case let .buffering(_, whilePlaying, _, _) = status.status, whilePlaying {
            isPlaying = true
        }
        if self.scrubbingTime == nil {
            self.transcriptView.currentTime = time
        }
        self.controlsView.update(time: time, duration: status.duration, isPlaying: isPlaying, rate: status.baseRate)
        if isPlaying != self.isPlayingNow {
            let didStart = isPlaying
            self.isPlayingNow = isPlaying
            if didStart {
                // Playing again after a pause (the text may have been scrolled meanwhile): smoothly back to the active line.
                self.transcriptView.resumeFollowing()
            }
            self.updateSyncButton(animated: true)
        }
    }

    /// "Synchronize" is offered while a voice message plays and the line being spoken is out of view.
    private func updateSyncButton(animated: Bool) {
        self.syncButton.setVisible(self.isPlayingNow && !self.isActiveRowVisible && !self.isSearching, animated: animated)
    }

    func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        // While the search is open or opening, a change of the keyboard is not a reason to lay the whole sheet out again (the header
        // and the tabs are glass views that are expensive to update); only the inset of the list follows it.
        if let previous = self.validLayout, self.isSearching || self.searchProgress > 0.001, previous.size == layout.size, previous.intrinsicInsets == layout.intrinsicInsets, previous.safeInsets == layout.safeInsets, previous.statusBarHeight == layout.statusBarHeight {
            self.validLayout = layout
            self.applyGeometry()
            return
        }
        self.validLayout = layout
        let theme = self.presentationData.theme

        transition.updateFrame(node: self.dimNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        transition.updateFrame(node: self.contentNode, frame: CGRect(origin: CGPoint(), size: layout.size))

        // On a regular width class the sheet is always the expanded one.
        if case .regular = layout.metrics.widthClass {
            self.stopExpansionAnimation()
            self.expansion = 1.0
        }

        let cardInset = VoiceTranscriptScreenNode.cardInset
        let topExpanded = max(layout.statusBarHeight ?? 0.0, layout.safeInsets.top) + 10.0
        let collapsedHeight = min(floor(layout.size.height * VoiceTranscriptScreenNode.collapsedHeightFraction), layout.size.height - topExpanded - cardInset)
        self.topExpanded = topExpanded
        self.topCollapsed = layout.size.height - cardInset - collapsedHeight
        self.expandDistance = max(1.0, self.topCollapsed - topExpanded)

        // The content is always as wide as the collapsed card, whatever the sheet's width is right now.
        let width = layout.size.width - cardInset * 2.0
        self.contentWidth = width

        let componentTransition = self.animatesComponents ? ComponentTransition(transition) : ComponentTransition.immediate

        // Header: glass close and search buttons with the title between them.
        let headerInset: CGFloat = 16.0
        let headerButtonsSize = self.headerButtons.update(
            transition: componentTransition,
            component: AnyComponent(
                GlassControlPanelComponent(
                    theme: theme,
                    leftItem: GlassControlPanelComponent.Item(
                        items: [
                            GlassControlGroupComponent.Item(
                                id: AnyHashable("close"),
                                content: .icon("Navigation/Close"),
                                action: { [weak self] in
                                    self?.requestDismiss()
                                }
                            )
                        ],
                        background: .panel
                    ),
                    centralItem: nil,
                    // Search belongs to the transcript. The summary has the information button instead: it opens the Cocoon
                    // screen, the same one the information button of the translate popup opens.
                    rightItem: GlassControlPanelComponent.Item(
                        items: [
                            self.selectedTab == .summary ? GlassControlGroupComponent.Item(
                                id: AnyHashable("info"),
                                content: .icon("Navigation/Info"),
                                action: { [weak self] in
                                    guard let self, let controller = self.getController() else {
                                        return
                                    }
                                    controller.push(self.context.sharedContext.makeCocoonInfoScreen(context: self.context))
                                }
                            ) : GlassControlGroupComponent.Item(
                                id: AnyHashable("search"),
                                content: .icon("Navigation/Search"),
                                action: { [weak self] in
                                    self?.beginSearch()
                                }
                            )
                        ],
                        background: .panel
                    ),
                    centerAlignmentIfPossible: true,
                    isDark: theme.overallDarkAppearance
                )
            ),
            environment: {},
            containerSize: CGSize(width: width - headerInset * 2.0, height: 44.0)
        )
        if let headerButtonsView = self.headerButtons.view {
            if headerButtonsView.superview == nil {
                self.innerView.addSubview(headerButtonsView)
            }
            headerButtonsView.frame = CGRect(origin: CGPoint(x: headerInset, y: headerInset), size: headerButtonsSize)
        }

        let titleSize = self.title.update(
            transition: componentTransition,
            component: AnyComponent(
                MultilineTextComponent(text: .plain(NSAttributedString(string: self.peerTitle, font: Font.semibold(17.0), textColor: theme.list.itemPrimaryTextColor)))
            ),
            environment: {},
            containerSize: CGSize(width: width - 70.0 * 2.0, height: 44.0)
        )
        if let titleView = self.title.view {
            if titleView.superview == nil {
                self.innerView.addSubview(titleView)
            }
            titleView.frame = CGRect(origin: CGPoint(x: floor((width - titleSize.width) / 2.0), y: headerInset + floor((44.0 - titleSize.height) / 2.0)), size: titleSize)
        }

        // Tabs: the same component the profile uses for Posts / Gifts.
        // The selected pill is the bar minus a 3pt glass border on each side, so a 41pt bar gives a 35pt pill.
        let tabsHeight: CGFloat = 41.0
        let tabsY = headerInset + 44.0 + 12.0
        let tabsSize = self.tabs.update(
            transition: componentTransition,
            component: AnyComponent(HorizontalTabsComponent(
                context: self.context,
                theme: theme,
                tabs: [
                    HorizontalTabsComponent.Tab(
                        id: AnyHashable(Tab.transcript.rawValue),
                        content: .custom(AnyComponent(VoiceTranscriptTabContentComponent(
                            title: self.presentationData.strings.VoiceTranscript_Transcript,
                            usesTranscriptGlyph: true,
                            iconSymbol: nil,
                            iconColor: self.selectedTab == .transcript ? voiceTranscriptBlue(theme) : theme.list.itemPrimaryTextColor,
                            textColor: theme.list.itemPrimaryTextColor
                        ))),
                        badge: nil,
                        action: { [weak self] in
                            self?.selectTab(.transcript)
                        }
                    ),
                    HorizontalTabsComponent.Tab(
                        id: AnyHashable(Tab.summary.rawValue),
                        content: .custom(AnyComponent(VoiceTranscriptTabContentComponent(
                            title: self.presentationData.strings.VoiceTranscript_AISummary,
                            usesTranscriptGlyph: false,
                            iconSymbol: "sparkles",
                            iconColor: self.selectedTab == .summary ? voiceTranscriptBlue(theme) : theme.list.itemPrimaryTextColor,
                            textColor: theme.list.itemPrimaryTextColor
                        ))),
                        badge: nil,
                        action: { [weak self] in
                            self?.selectTab(.summary)
                        }
                    )
                ],
                selectedTab: AnyHashable(self.selectedTab.rawValue),
                isEditing: false,
                layout: .fill,
                liftWhileSwitching: true
            )),
            environment: {},
            containerSize: CGSize(width: width - headerInset * 2.0, height: tabsHeight)
        )
        let tabsFrame = CGRect(origin: CGPoint(x: headerInset, y: tabsY), size: tabsSize)
        transition.updateFrame(view: self.tabsBackgroundContainer, frame: tabsFrame)
        self.tabsBackgroundContainer.update(size: tabsFrame.size, isDark: theme.overallDarkAppearance, transition: componentTransition)
        transition.updateFrame(view: self.tabsBackgroundView, frame: CGRect(origin: CGPoint(), size: tabsFrame.size))
        self.tabsBackgroundView.update(size: tabsFrame.size, cornerRadius: tabsFrame.height * 0.5, isDark: theme.overallDarkAppearance, tintColor: .init(kind: .panel), transition: componentTransition)
        if let tabsView = self.tabs.view as? HorizontalTabsComponent.View {
            if tabsView.superview == nil {
                self.tabsBackgroundView.contentView.addSubview(tabsView)
                tabsView.setOverlayContainerView(overlayContainerView: self.sheetNode.view)
            }
            transition.updateFrame(view: tabsView, frame: CGRect(origin: CGPoint(), size: tabsFrame.size))
        }

        self.applyPageVisibility()
        if self.isSearching || self.searchProgress > 0.001 {
            self.layoutSearchBar(width: width, transition: transition)
        }

        self.controlsHeight = self.controlsView.preferredHeight(bottomInset: layout.intrinsicInsets.bottom)
        self.controlsView.updateLayout(size: CGSize(width: width, height: self.controlsHeight), bottomInset: layout.intrinsicInsets.bottom)
        self.listTop = tabsY + tabsHeight + 8.0
        self.listTopSearch = headerInset + 44.0 + 8.0

        self.applyGeometry()
    }

    /// Puts a view at a place and size without setting `frame`: that is undefined while the view has a transform, and the pages
    /// have one for as long as one slides in over the other. Bounds and centre are always safe.
    private func place(_ view: UIView, in frame: CGRect) {
        view.bounds = CGRect(origin: CGPoint(), size: frame.size)
        view.center = CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Only frames, and only what depends on the expansion. This runs for every frame of a drag or an animation.
    private func applyGeometry() {
        guard let layout = self.validLayout else {
            return
        }
        let cardInset = VoiceTranscriptScreenNode.cardInset
        let expansion = min(1.0, max(0.0, self.expansion))
        // Every edge lands on a whole pixel, and the content is pinned to the same screen position (the card's inset)
        // however wide the sheet is: nothing inside moves sideways while the sheet grows, and text is never drawn between pixels.
        let sideInset = floorToScreenPixels(cardInset * (1.0 - expansion))
        let bottomGap = floorToScreenPixels(cardInset * (1.0 - expansion))
        let top = floorToScreenPixels(self.topCollapsed + (self.topExpanded - self.topCollapsed) * expansion)
        let sheetFrame = CGRect(x: sideInset, y: top, width: layout.size.width - sideInset * 2.0, height: layout.size.height - bottomGap - top)
        self.sheetNode.frame = sheetFrame
        self.innerView.frame = CGRect(origin: CGPoint(x: cardInset - sideInset, y: 0.0), size: CGSize(width: self.contentWidth, height: sheetFrame.height))

        // The top corners are fixed; the bottom ones follow the device's screen corners, inset by the card's gap.
        let screenRadius = layout.deviceMetrics.screenCornerRadius
        let bottomRadius = screenRadius > 0.0 ? max(0.0, screenRadius - bottomGap) : 22.0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.sheetMaskLayer.frame = CGRect(origin: CGPoint(), size: sheetFrame.size)
        self.sheetMaskLayer.path = voiceTranscriptSheetPath(size: sheetFrame.size, topRadius: 38.0, bottomRadius: bottomRadius).cgPath
        CATransaction.commit()
        self.grabberNode.frame = CGRect(origin: CGPoint(x: floor((sheetFrame.width - 36.0) / 2.0), y: 5.0), size: CGSize(width: 36.0, height: 6.0))

        let search = min(1.0, max(0.0, self.searchProgress))
        let controlsFrame = CGRect(origin: CGPoint(x: 0.0, y: sheetFrame.height - self.controlsHeight), size: CGSize(width: self.contentWidth, height: self.controlsHeight))
        // The player slides down and fades while the search opens.
        self.place(self.controlsView, in: controlsFrame.offsetBy(dx: 0.0, dy: search * 36.0))
        self.controlsView.alpha = max(0.0, 1.0 - search * 2.0)
        // The header and the tabs fade out and the search bar fades in, in the place of the header.
        let headerAlpha = max(0.0, 1.0 - search * 2.5)
        let isSearchOpen = search >= 0.999
        self.headerButtons.view?.alpha = headerAlpha
        self.headerButtons.view?.isHidden = isSearchOpen
        self.title.view?.alpha = headerAlpha
        self.title.view?.isHidden = isSearchOpen
        self.tabsBackgroundContainer.alpha = headerAlpha
        self.tabsBackgroundContainer.isHidden = isSearchOpen
        if let searchBarView = self.searchBar?.view {
            searchBarView.alpha = min(1.0, max(0.0, (search - 0.25) / 0.75))
            searchBarView.isHidden = search <= 0.001
        }
        let syncSize = self.syncButton.preferredSize
        self.place(self.syncButton, in: CGRect(x: floor((self.contentWidth - syncSize.width) / 2.0), y: controlsFrame.minY - syncSize.height - 12.0, width: syncSize.width, height: syncSize.height))
        let buttonInset = VoiceTranscriptScreenNode.closeButtonInset
        let buttonHeight = VoiceTranscriptScreenNode.closeButtonHeight
        self.place(self.closeButton, in: CGRect(x: buttonInset, y: sheetFrame.height - buttonHeight - buttonInset, width: max(0.0, self.contentWidth - buttonInset * 2.0), height: buttonHeight))
        // The fade starts 36pt above the button and covers the space under it, like the one under the fixed buttons of other sheets.
        let edgeHeight = buttonHeight + 36.0
        let edgeFrame = CGRect(x: 0.0, y: sheetFrame.height - edgeHeight - buttonInset, width: self.contentWidth, height: edgeHeight + buttonInset)
        self.place(self.summaryEdgeEffect, in: edgeFrame)
        if self.summaryEdgeEffectSize != edgeFrame.size {
            self.summaryEdgeEffectSize = edgeFrame.size
            self.summaryEdgeEffect.update(content: self.presentationData.theme.list.modalBlocksBackgroundColor, blur: true, alpha: 1.0, rect: edgeFrame, edge: .bottom, edgeSize: edgeHeight, transition: .immediate)
        }

        // The list moves up under the search bar and grows down to the keyboard (or the bottom of the sheet) as the search opens.
        // The list goes down to the bottom of the sheet; the keyboard is only an inset of its content, so that the list is not
        // resized (and its text is not laid out again) while the keyboard comes or goes.
        let searchListBottom = sheetFrame.height
        self.transcriptView.keyboardInset = search > 0.001 || self.isSearching ? (layout.inputHeight ?? 0.0) : 0.0
        self.transcriptView.setSearchProgress(search)
        let listTop = self.listTop + (self.listTopSearch - self.listTop) * search
        let listBottom = controlsFrame.minY + (searchListBottom - controlsFrame.minY) * search
        let listFrame = CGRect(origin: CGPoint(x: 0.0, y: listTop), size: CGSize(width: self.contentWidth, height: max(0.0, listBottom - listTop)))
        self.place(self.transcriptView, in: listFrame)
        self.transcriptView.updateLayout(size: listFrame.size)
        let summaryFrame = CGRect(origin: CGPoint(x: 0.0, y: self.listTop), size: CGSize(width: self.contentWidth, height: sheetFrame.height - self.listTop))
        self.place(self.summaryView, in: summaryFrame)
        self.summaryView.updateLayout(size: summaryFrame.size, bottomInset: layout.intrinsicInsets.bottom)
    }

    func animateIn() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.prepareSearchBar()
        }
        self.layer.animateBoundsOriginYAdditive(from: -self.bounds.size.height, to: 0.0, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring)
        self.dimNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
        self.dimNode.layer.animatePosition(from: CGPoint(x: 0.0, y: -self.bounds.size.height), to: CGPoint(), duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: true, additive: true)
    }

    func animateOut(completion: (() -> Void)?) {
        // Nothing else may compete with the slide: stop the transcript ticks and any touches.
        self.displayLinkTimer?.invalidate()
        self.displayLinkTimer = nil
        self.searchAnimation = nil
        self.stopExpansionAnimation()
        self.view.isUserInteractionEnabled = false
        self.searchBar?.deactivate(clear: false)
        self.layer.animateBoundsOriginYAdditive(from: self.bounds.origin.y, to: -self.bounds.size.height, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false, completion: { _ in
            completion?()
        })
        self.dimNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false)
        self.dimNode.layer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: -self.bounds.size.height), duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false, additive: true)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if !self.bounds.contains(point) {
            return nil
        }
        if !self.sheetNode.frame.contains(point) {
            return self.dimNode.view
        }
        return super.hitTest(point, with: event)
    }

    // Dragging the header (the name, the tabs) moves the sheet; it only starts there, so it never fights the content's own
    // scrolling, and only for a mostly vertical drag, so the tabs can still be swiped sideways.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return true
        }
        if self.isSearching {
            return false
        }
        let location = pan.location(in: self.sheetNode.view)
        let velocity = pan.velocity(in: self.sheetNode.view)
        return location.y < self.transcriptView.frame.minY && abs(velocity.y) > abs(velocity.x)
    }

    /// Dragging the header up grows the sheet to full size, dragging it down shrinks it back, and once it is as small as it
    /// gets, dragging further down takes it off the screen. One drag can do all of it.
    @objc private func panGesture(_ recognizer: UIPanGestureRecognizer) {
        let distance = max(1.0, self.expandDistance)
        switch recognizer.state {
        case .began:
            self.stopExpansionAnimation()
            self.panStartExpansion = self.expansion
        case .changed:
            let translation = recognizer.translation(in: self.view).y
            let desired = self.panStartExpansion - translation / distance
            self.expansion = min(1.0, max(0.0, desired))
            self.applyGeometry()

            // The part of the drag that is left over once the sheet is collapsed moves the whole sheet down.
            var bounds = self.contentNode.bounds
            bounds.origin.y = desired < 0.0 ? desired * distance : 0.0
            self.contentNode.bounds = bounds
        case .ended, .cancelled:
            let translation = recognizer.translation(in: self.view).y
            let velocity = recognizer.velocity(in: self.view).y
            let desired = self.panStartExpansion - translation / distance
            let leftover = -min(0.0, desired) * distance

            if case .ended = recognizer.state, leftover > 60.0 || (desired <= 0.0 && velocity > 300.0) {
                self.requestDismiss()
                return
            }
            if leftover > 0.0 {
                let previousBounds = self.contentNode.bounds
                var bounds = previousBounds
                bounds.origin.y = 0.0
                self.contentNode.bounds = bounds
                self.contentNode.layer.animateBounds(from: previousBounds, to: bounds, duration: 0.3, timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue)
            }

            // Settle on a state: the direction of a flick decides, otherwise the nearer one.
            let target: CGFloat
            if case .ended = recognizer.state, velocity < -300.0 {
                target = 1.0
            } else if case .ended = recognizer.state, velocity > 300.0 {
                target = 0.0
            } else {
                target = self.expansion >= 0.5 ? 1.0 : 0.0
            }
            if abs(self.expansion - target) > 0.001 {
                self.animateExpansion(to: target)
            }
        default:
            break
        }
    }
}

/// A tab's content: an icon (an app asset or an SF Symbol) followed by the title.
private final class VoiceTranscriptTabContentComponent: Component {
    let title: String
    let usesTranscriptGlyph: Bool
    let iconSymbol: String?
    let iconColor: UIColor
    let textColor: UIColor

    init(title: String, usesTranscriptGlyph: Bool, iconSymbol: String?, iconColor: UIColor, textColor: UIColor) {
        self.title = title
        self.usesTranscriptGlyph = usesTranscriptGlyph
        self.iconSymbol = iconSymbol
        self.iconColor = iconColor
        self.textColor = textColor
    }

    static func ==(lhs: VoiceTranscriptTabContentComponent, rhs: VoiceTranscriptTabContentComponent) -> Bool {
        return lhs.title == rhs.title && lhs.usesTranscriptGlyph == rhs.usesTranscriptGlyph && lhs.iconSymbol == rhs.iconSymbol && lhs.iconColor == rhs.iconColor && lhs.textColor == rhs.textColor
    }

    final class View: UIView {
        private let iconView = UIImageView()
        private let label = UILabel()

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.isUserInteractionEnabled = false
            self.iconView.contentMode = .center
            self.label.font = Font.semibold(15.0)
            self.addSubview(self.iconView)
            self.addSubview(self.label)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(component: VoiceTranscriptTabContentComponent) -> CGSize {
            var image: UIImage?
            if component.usesTranscriptGlyph {
                image = voiceTranscriptTranscriptGlyph()
            } else if let symbol = component.iconSymbol {
                image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14.0, weight: .medium))?.withRenderingMode(.alwaysTemplate)
            }
            self.iconView.image = image
            self.iconView.tintColor = component.iconColor
            self.label.text = component.title
            self.label.textColor = component.textColor

            let iconSize = image?.size ?? CGSize()
            let spacing: CGFloat = image != nil ? 5.0 : 0.0
            let labelSize = self.label.sizeThatFits(CGSize(width: 300.0, height: 100.0))
            let height = max(iconSize.height, ceil(labelSize.height))
            self.iconView.frame = CGRect(origin: CGPoint(x: 0.0, y: floor((height - iconSize.height) / 2.0)), size: iconSize)
            self.label.frame = CGRect(origin: CGPoint(x: iconSize.width + spacing, y: floor((height - labelSize.height) / 2.0)), size: CGSize(width: ceil(labelSize.width), height: ceil(labelSize.height)))
            return CGSize(width: iconSize.width + spacing + ceil(labelSize.width), height: height)
        }
    }

    func makeView() -> View {
        return View()
    }

    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self)
    }
}

private final class VoiceTranscriptViewContextSource: ContextReferenceContentSource {
    private let referenceView: UIView

    init(referenceView: UIView) {
        self.referenceView = referenceView
    }

    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        return ContextControllerReferenceViewInfo(referenceView: self.referenceView, contentAreaInScreenSpace: UIScreen.main.bounds, actionsPosition: .top)
    }
}

private final class VoiceTranscriptItemContextSource: ContextReferenceContentSource {
    private let referenceView: UIView

    init(referenceView: UIView) {
        self.referenceView = referenceView
    }

    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        // Two items of the menu are about 110pt tall; the menu goes right under the item when it fits between the item and the bottom
        // of the safe area, and above the item otherwise.
        let frame = self.referenceView.convert(self.referenceView.bounds, to: nil)
        let bottomInset = self.referenceView.window?.safeAreaInsets.bottom ?? 0.0
        let position: ContextControllerReferenceViewInfo.ActionsPosition = frame.maxY + 130.0 <= UIScreen.main.bounds.height - bottomInset ? .bottom : .top
        return ContextControllerReferenceViewInfo(referenceView: self.referenceView, contentAreaInScreenSpace: UIScreen.main.bounds, actionsPosition: position)
    }
}

private final class VoiceTranscriptRateContextSource: ContextReferenceContentSource {
    private let controller: ViewController
    private let sourceNode: ContextReferenceContentNode

    init(controller: ViewController, sourceNode: ContextReferenceContentNode) {
        self.controller = controller
        self.sourceNode = sourceNode
    }

    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        return ContextControllerReferenceViewInfo(referenceView: self.sourceNode.view, contentAreaInScreenSpace: UIScreen.main.bounds, actionsPosition: .top)
    }
}

/// The pill that brings the text back to the line being spoken after the user has scrolled away from it.
private final class VoiceTranscriptSyncButton: UIView {
    private let container = GlassBackgroundContainerView()
    private let background = GlassBackgroundView()
    private let iconView = UIImageView()
    private let label = UILabel()
    private let button = UIButton(type: .custom)
    private var isShown = false
    private var lastSize = CGSize()
    private var isDark = false

    var pressed: (() -> Void)?
    private static let sidePadding: CGFloat = 12.0
    private static let iconSize: CGFloat = 22.0
    private static let iconGap: CGFloat = 4.0
    /// The width is the text and the icon with 12pt on each side.
    private(set) var preferredSize = CGSize(width: 138.0, height: 36.0)

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.alpha = 0.0
        self.isUserInteractionEnabled = false
        self.addSubview(self.container)
        self.container.contentView.addSubview(self.background)
        self.background.contentView.addSubview(self.iconView)
        self.background.contentView.addSubview(self.label)
        self.background.contentView.addSubview(self.button)
        self.iconView.image = UIImage(systemName: "waveform", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15.0, weight: .medium))
        self.iconView.contentMode = .center
        self.iconView.tintColor = .black
        self.label.text = "Synchronize"
        self.label.font = Font.medium(14.0)
        let textWidth = ceil(self.label.sizeThatFits(CGSize(width: 1000.0, height: 100.0)).width)
        self.preferredSize = CGSize(width: VoiceTranscriptSyncButton.sidePadding * 2.0 + VoiceTranscriptSyncButton.iconSize + VoiceTranscriptSyncButton.iconGap + textWidth, height: 36.0)
        self.label.textColor = .black
        self.button.addAction(UIAction { [weak self] _ in
            self?.pressed?()
        }, for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, textColor: UIColor, isDark: Bool) {
        self.label.text = title
        let textWidth = ceil(self.label.sizeThatFits(CGSize(width: 1000.0, height: 100.0)).width)
        self.preferredSize = CGSize(width: VoiceTranscriptSyncButton.sidePadding * 2.0 + VoiceTranscriptSyncButton.iconSize + VoiceTranscriptSyncButton.iconGap + textWidth, height: 36.0)
        self.isDark = isDark
        self.iconView.tintColor = textColor
        self.label.textColor = textColor
        self.lastSize = CGSize()
        self.setNeedsLayout()
    }

    func setVisible(_ visible: Bool, animated: Bool) {
        if visible == self.isShown {
            return
        }
        self.isShown = visible
        self.isUserInteractionEnabled = visible
        let apply = {
            self.alpha = visible ? 1.0 : 0.0
            self.container.transform = visible ? .identity : CGAffineTransform(scaleX: 0.9, y: 0.9)
        }
        if animated {
            UIView.animate(withDuration: 0.25, delay: 0.0, options: [.beginFromCurrentState, .allowUserInteraction], animations: apply)
        } else {
            apply()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = self.bounds.size
        if size != self.lastSize {
            self.lastSize = size
            let isDark = self.isDark
            self.container.bounds = CGRect(origin: CGPoint(), size: size)
            self.container.center = CGPoint(x: size.width / 2.0, y: size.height / 2.0)
            self.container.update(size: size, isDark: isDark, transition: .immediate)
            self.background.frame = CGRect(origin: CGPoint(), size: size)
            self.background.update(size: size, cornerRadius: size.height * 0.5, isDark: isDark, tintColor: .init(kind: .panel), transition: .immediate)
            self.button.frame = CGRect(origin: CGPoint(), size: size)
        }
        let labelSize = self.label.sizeThatFits(size)
        let contentWidth = 22.0 + 4.0 + labelSize.width
        let startX = floor((size.width - contentWidth) / 2.0)
        self.iconView.frame = CGRect(x: startX, y: floor((size.height - 22.0) / 2.0), width: 22.0, height: 22.0)
        self.label.frame = CGRect(x: startX + 26.0, y: floor((size.height - labelSize.height) / 2.0), width: labelSize.width, height: labelSize.height)
    }
}

// MARK: - Transcript list

private final class VoiceTranscriptRowView: UIView, UITextViewDelegate, UIGestureRecognizerDelegate {
    let segment: VoiceTranscriptSegment
    private let theme: PresentationTheme
    private let metrics: VoiceTranscriptTextMetrics
    private let timeLabel: UILabel
    private let highlightView = UIView()
    private var verticalPadding: CGFloat {
        return VoiceTranscriptRowView.verticalPadding
    }

    private var activeWordRange: NSRange?
    private var lastQuery: String?
    private var lastSelection: ClosedRange<Int>?
    private var lastCurrentTime: Double = -1.0

    var searchQuery: String? {
        didSet {
            if self.searchQuery != oldValue {
                self.applyState(currentTime: self.lastCurrentTime)
            }
        }
    }

    /// While the search is open the word being spoken is not shown.
    var isSearchMode: Bool = false {
        didSet {
            if self.isSearchMode != oldValue {
                self.lastStateKey = Int.min
                self.applyState(currentTime: self.lastCurrentTime)
            }
        }
    }

    func matches(_ query: String) -> Bool {
        return self.segment.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
    let textView: UITextView
    // An explicit TextKit 1 stack: touching `UITextView.layoutManager` on a default text view silently switches it from
    // TextKit 2 and corrupts its layout (lines vanish, geometry is off).
    private let textStorage: NSTextStorage
    private let layoutManager: NSLayoutManager
    private var wordRanges: [NSRange] = []
    private var lastStateKey: Int = Int.min

    var seekTo: ((Double) -> Void)?

    // Each line has 4pt of vertical padding and none at the sides, inside the list's side inset; the time column is 32pt
    // wide and one text line tall, with an 8pt gap to the text.
    static let outerInset: CGFloat = 20.0
    static let horizontalPadding: CGFloat = 0.0
    /// Every line has 8pt above and below it, the line being spoken included, so nothing moves when the line changes.
    static let verticalPadding: CGFloat = 8.0
    static let seekInset: Double = 0.06
    static let timeWidth: CGFloat = 32.0
    static let timeGap: CGFloat = 8.0

    static var textLeftInset: CGFloat {
        return outerInset + horizontalPadding + timeWidth + timeGap
    }

    static var rightInset: CGFloat {
        return outerInset + horizontalPadding
    }

    private func timeText(_ value: String, color: UIColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = self.metrics.timeLineHeight
        paragraph.maximumLineHeight = self.metrics.timeLineHeight
        let font = Font.regular(self.metrics.timeFontSize)
        return NSAttributedString(string: value, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
            .baselineOffset: (self.metrics.timeLineHeight - font.lineHeight) / 4.0
        ])
    }

    private var timeColor: UIColor {
        // Primary text at 50%: black 50% in the light theme, white 50% in the dark one.
        return self.theme.list.itemPrimaryTextColor.withAlphaComponent(0.5)
    }

    init(segment: VoiceTranscriptSegment, theme: PresentationTheme, metrics: VoiceTranscriptTextMetrics) {
        self.segment = segment
        self.theme = theme
        self.metrics = metrics

        self.timeLabel = UILabel()

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(width: 0.0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        self.textStorage = textStorage
        self.layoutManager = layoutManager
        self.textView = UITextView(frame: CGRect(), textContainer: textContainer)
        self.textView.isEditable = false
        // The list does the selecting itself, across lines; a text view could only ever select inside its own.
        self.textView.isSelectable = false
        self.textView.isScrollEnabled = false
        self.textView.backgroundColor = .clear
        self.textView.textContainerInset = .zero
        self.textView.textContainer.lineFragmentPadding = 0.0

        super.init(frame: CGRect())

        self.timeLabel.attributedText = self.timeText(formatVoiceTranscriptTime(segment.start), color: self.timeColor)
        // The active word's background sits behind the text and never affects its layout.
        self.highlightView.backgroundColor = UIColor(rgb: 0x008BFF)
        self.highlightView.isHidden = true
        self.addSubview(self.highlightView)
        self.addSubview(self.timeLabel)
        self.addSubview(self.textView)

        self.applyState(currentTime: -1.0)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func measuredHeight(width: CGFloat) -> CGFloat {
        let textWidth = width - VoiceTranscriptRowView.textLeftInset - VoiceTranscriptRowView.rightInset
        let size = self.textView.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        return ceil(size.height) + self.verticalPadding * 2.0
    }

    func updateLayout(width: CGFloat) -> CGFloat {
        let height = self.measuredHeight(width: width)
        let textWidth = width - VoiceTranscriptRowView.textLeftInset - VoiceTranscriptRowView.rightInset
        self.timeLabel.frame = CGRect(origin: CGPoint(x: VoiceTranscriptRowView.outerInset + VoiceTranscriptRowView.horizontalPadding, y: self.verticalPadding), size: CGSize(width: VoiceTranscriptRowView.timeWidth, height: self.metrics.lineHeight))
        self.textView.frame = CGRect(origin: CGPoint(x: VoiceTranscriptRowView.textLeftInset, y: self.verticalPadding), size: CGSize(width: textWidth, height: height - self.verticalPadding * 2.0))
        self.updateHighlight()
        return height
    }

    /// Where this line stands against the line being spoken. The list decides it, so that exactly one line is always the active
    /// one: a pause between two words, or between two lines, does not leave the text without an active word.
    enum LineState {
        case past
        case active
        case upcoming
    }

    var lineState: LineState = .upcoming

    /// Index of the word being spoken at `time`: the last word that has started, so the word stays active through a pause until
    /// the next one starts. -1 for a line still to come, `words.count` for a line that is read.
    private func activeWordIndex(time: Double) -> Int {
        switch self.lineState {
        case .upcoming:
            return -1
        case .past:
            return self.segment.words.count
        case .active:
            var result = 0
            for (index, word) in self.segment.words.enumerated() {
                if word.start <= time {
                    result = index
                } else {
                    break
                }
            }
            return result
        }
    }

    func applyState(currentTime: Double, animated: Bool = false) {
        self.lastCurrentTime = currentTime
        let activeIndex = currentTime < 0.0 || self.isSearchMode ? -1 : self.activeWordIndex(time: currentTime)
        if activeIndex == self.lastStateKey && self.searchQuery == self.lastQuery && self.selectedWords == self.lastSelection {
            return
        }
        self.lastStateKey = activeIndex
        self.lastQuery = self.searchQuery
        self.lastSelection = self.selectedWords

        let font = Font.semibold(self.metrics.fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = self.metrics.lineHeight
        paragraph.maximumLineHeight = self.metrics.lineHeight
        let baselineOffset = (self.metrics.lineHeight - font.lineHeight) / 4.0
        // Every line that is not being spoken, read or not, is 30%; the line being spoken is black, and its current word is F0F0F5 on blue.
        let played = voiceTranscriptTextColor(self.theme, alpha: 0.3)
        let upcoming = played
        let activeLine = self.theme.list.itemPrimaryTextColor
        let isPast = activeIndex >= self.segment.words.count

        let result = NSMutableAttributedString()
        var ranges: [NSRange] = []
        for (index, word) in self.segment.words.enumerated() {
            let location = result.length
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .kern: self.metrics.kerning, .paragraphStyle: paragraph, .baselineOffset: baselineOffset]
            if isPast {
                attributes[.foregroundColor] = played
            } else if activeIndex < 0 {
                // While searching every line is dark (nothing is being spoken, and the matches have to be easy to read).
                attributes[.foregroundColor] = self.isSearchMode ? activeLine : upcoming
            } else if index == activeIndex {
                attributes[.foregroundColor] = UIColor(rgb: 0xF0F0F5)
            } else {
                attributes[.foregroundColor] = activeLine
            }
            // A selected word is black whether its line was read, is being read or is still to come, and goes back to its own
            // colour when the selection goes. The word being spoken keeps its colour: it sits on the blue.
            let isActiveWord = activeIndex >= 0 && index == activeIndex && activeIndex < self.segment.words.count
            if let selected = self.selectedWords, selected.contains(index), !isActiveWord {
                attributes[.foregroundColor] = activeLine
            }
            result.append(NSAttributedString(string: word.text, attributes: attributes))
            ranges.append(NSRange(location: location, length: word.text.utf16.count))
            if index != self.segment.words.count - 1 {
                result.append(NSAttributedString(string: " ", attributes: [.font: font, .kern: self.metrics.kerning, .paragraphStyle: paragraph, .baselineOffset: baselineOffset, .foregroundColor: upcoming]))
            }
        }
        if let query = self.searchQuery {
            let string = result.string as NSString
            var searchRange = NSRange(location: 0, length: string.length)
            while searchRange.length > 0 {
                let found = string.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                if found.location == NSNotFound {
                    break
                }
                result.addAttribute(.backgroundColor, value: voiceTranscriptBlue(self.theme).withAlphaComponent(0.3), range: found)
                searchRange = NSRange(location: found.location + found.length, length: string.length - found.location - found.length)
            }
        }
        if let selected = self.selectedWords, selected.lowerBound >= 0, selected.upperBound < ranges.count {
            let first = ranges[selected.lowerBound]
            let last = ranges[selected.upperBound]
            result.addAttribute(.backgroundColor, value: voiceTranscriptBlue(self.theme).withAlphaComponent(0.25), range: NSRange(location: first.location, length: last.location + last.length - first.location))
        }
        self.wordRanges = ranges
        self.activeWordRange = activeIndex >= 0 && activeIndex < ranges.count ? ranges[activeIndex] : nil

        // The words never change, only their colours, so the attributes are changed in place: re-assigning the whole text
        // drops a selection, and the line being spoken must stay selectable while it is highlighted.
        let apply = {
            if self.textStorage.length == result.length && self.textStorage.string == result.string {
                self.textStorage.beginEditing()
                result.enumerateAttributes(in: NSRange(location: 0, length: result.length), options: []) { attributes, range, _ in
                    self.textStorage.setAttributes(attributes, range: range)
                }
                self.textStorage.endEditing()
            } else {
                self.textView.attributedText = result
            }
        }
        if animated {
            // The colours and the selection's background fade to their new values instead of switching.
            UIView.transition(with: self.textView, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState], animations: apply)
        } else {
            apply()
        }
        let isActive = activeIndex >= 0 && activeIndex < self.segment.words.count
        // The time beside a line: the colour of the line's text (30%), and blue while the line is spoken.
        let timeColor = isActive ? voiceTranscriptLineBlue() : played
        self.timeLabel.alpha = 1.0
        self.timeLabel.attributedText = self.timeText(formatVoiceTranscriptTime(self.segment.start), color: timeColor)
        self.updateHighlight()
    }

    /// 24pt tall, exactly as wide as the word, with square corners, centred on the word's line.
    private func updateHighlight() {
        guard let range = self.activeWordRange, self.textView.bounds.width > 0.0 else {
            self.highlightView.isHidden = true
            return
        }
        let layoutManager = self.layoutManager
        layoutManager.ensureLayout(for: self.textView.textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: self.textView.textContainer)
        // The line is 24pt but its text sits low in it, so centre on the glyphs instead: halfway between the middle of
        // the capitals and the middle of the lowercase letters, measured from the baseline.
        let font = Font.semibold(self.metrics.fontSize)
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        let baselineY = lineRect.minY + layoutManager.location(forGlyphAt: glyphRange.location).y
        let glyphCenterY = baselineY - (font.capHeight + font.xHeight) / 4.0
        let height = self.metrics.lineHeight
        self.highlightView.frame = CGRect(
            x: self.textView.frame.minX + rect.minX,
            y: self.textView.frame.minY + glyphCenterY - height / 2.0,
            width: rect.width,
            height: height
        )
        self.highlightView.isHidden = false
    }

    /// The words of this line that are selected (a range of word indexes), drawn with a background.
    var selectedWords: ClosedRange<Int>? {
        didSet {
            if self.selectedWords != oldValue {
                self.applyState(currentTime: self.lastCurrentTime, animated: true)
            }
        }
    }

    var wordCount: Int {
        return self.segment.words.count
    }

    func text(forWords range: ClosedRange<Int>) -> String {
        return range.map { self.segment.words[$0].text }.joined(separator: " ")
    }

    /// The word nearest to a point given in this row's coordinates.
    func nearestWord(at location: CGPoint) -> Int? {
        if self.wordRanges.isEmpty {
            return nil
        }
        // Through the layout manager rather than the text view's own `closestPosition`: with selection switched off the text
        // view may not answer that at all. This answers for any point, nearest character if it is outside the text.
        let point = self.convert(location, to: self.textView)
        self.layoutManager.ensureLayout(for: self.textView.textContainer)
        let index = self.layoutManager.characterIndex(for: point, in: self.textView.textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        var best: (word: Int, distance: Int)?
        for (word, range) in self.wordRanges.enumerated() {
            let distance: Int
            if index < range.location {
                distance = range.location - index
            } else if index > range.location + range.length {
                distance = index - (range.location + range.length)
            } else {
                distance = 0
            }
            if best == nil || distance < best!.distance {
                best = (word, distance)
            }
        }
        return best?.word
    }

    /// The rectangle of a word in this row's coordinates: as tall as its line, as wide as the word itself.
    func wordRect(_ word: Int) -> CGRect? {
        guard word >= 0, word < self.wordRanges.count else {
            return nil
        }
        self.layoutManager.ensureLayout(for: self.textView.textContainer)
        let glyphRange = self.layoutManager.glyphRange(forCharacterRange: self.wordRanges[word], actualCharacterRange: nil)
        let bounding = self.layoutManager.boundingRect(forGlyphRange: glyphRange, in: self.textView.textContainer)
        let line = self.layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        return CGRect(x: self.textView.frame.minX + bounding.minX, y: self.textView.frame.minY + line.minY, width: bounding.width, height: line.height)
    }

    /// A tap on the time seeks to the start of the line; a tap anywhere else in the row seeks to the word nearest to it.
    func handleTap(at location: CGPoint) {
        // Seeks land a few hundredths of a second either side of the target, so aim a little inside the word: aiming at
        // its exact start can land in the word before.
        let inset = VoiceTranscriptRowView.seekInset
        if self.timeLabel.frame.insetBy(dx: -6.0, dy: -6.0).contains(location) {
            self.seekTo?(self.segment.start + inset)
            return
        }
        if let word = self.nearestWord(at: location) {
            self.seekTo?(self.segment.words[word].start + inset)
        }
    }
}

/// One end of a selection: a thin line the height of the text line with a knob, above the line at the start of the selection
/// and below it at the end. It is easy to grab: its touch area is much larger than what is drawn.
private final class VoiceTranscriptSelectionHandle: UIView {
    static let knobSize: CGFloat = 10.0
    static let lineWidth: CGFloat = 2.0

    let isStart: Bool
    private let lineView = UIView()
    private let knobView = UIView()

    init(isStart: Bool, color: UIColor) {
        self.isStart = isStart
        super.init(frame: CGRect())
        self.lineView.backgroundColor = color
        self.knobView.backgroundColor = color
        self.knobView.layer.cornerRadius = VoiceTranscriptSelectionHandle.knobSize / 2.0
        self.addSubview(self.lineView)
        self.addSubview(self.knobView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let knob = VoiceTranscriptSelectionHandle.knobSize
        let lineWidth = VoiceTranscriptSelectionHandle.lineWidth
        let centerX = floor((self.bounds.width - lineWidth) / 2.0)
        if self.isStart {
            self.knobView.frame = CGRect(x: floor((self.bounds.width - knob) / 2.0), y: 0.0, width: knob, height: knob)
            self.lineView.frame = CGRect(x: centerX, y: knob - 2.0, width: lineWidth, height: max(0.0, self.bounds.height - knob + 2.0))
        } else {
            self.lineView.frame = CGRect(x: centerX, y: 0.0, width: lineWidth, height: max(0.0, self.bounds.height - knob + 2.0))
            self.knobView.frame = CGRect(x: floor((self.bounds.width - knob) / 2.0), y: self.bounds.height - knob, width: knob, height: knob)
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        return self.bounds.insetBy(dx: -14.0, dy: -14.0).contains(point)
    }
}

private final class VoiceTranscriptListView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let startHandle: VoiceTranscriptSelectionHandle
    private let endHandle: VoiceTranscriptSelectionHandle
    private var isDraggingHandle = false
    /// A long press that began on a handle belongs to the handle's own drag, and the selection ignores it.
    private var isLongPressOnHandle = false
    /// The menu's strings.
    var presentationData: PresentationData?
    private var editMenuInteractionObject: AnyObject?
    /// What the menu sits above: the visible part of the selection, in this view's coordinates.
    fileprivate var menuTargetRect = CGRect()
    // A selection of words that can run over several lines, from the anchor to the focus, in either order.
    private var selectionAnchor: (row: Int, word: Int)?
    private var selectionFocus: (row: Int, word: Int)?
    private var lastLongPressEnd: Double = 0.0

    private let theme: PresentationTheme
    private let scrollView: UIScrollView
    private var rows: [VoiceTranscriptRowView] = []
    private var currentActiveIndex: Int?
    /// Whether the list scrolls to the line being spoken as it changes. A drag by the user stops it; it starts again when the
    /// line being spoken is on screen again, when playback is resumed, or when the Synchronize button is pressed.
    private var isFollowing = true
    private var isActiveRowVisible = true
    /// Called when the line being spoken goes out of view or comes back.
    var activeRowVisibilityChanged: ((Bool) -> Void)?
    private var isUserScrolling = false
    private var lastUserScrollTime: Double = 0.0
    private var validSize = CGSize()

    var seekTo: ((Double) -> Void)?
    var requestReply: ((String, String) -> Void)?
    /// A selection is to be translated: the text of it.
    var requestTranslate: ((String) -> Void)?
    var requestShareQuote: ((String, String) -> Void)?
    var canExportText: (() -> Bool)?
    var consumeScroll: ((CGFloat) -> CGFloat)?
    var scrollEnded: (() -> Bool)?
    private var isAdjustingOffset = false
    var isAutoScrollEnabled = true

    private let placeholderLabel = UILabel()
    /// The skeleton shown while the transcript is being made: grey bars where the lines will be, with a shimmer.
    private let skeletonNode = ShimmerEffectNode()

    /// What the list says while there are no lines: that recognition is running, or that it is not available.
    var placeholder: VoiceTranscriptPlaceholder? {
        didSet {
            self.updatePlaceholder()
        }
    }

    /// What the list says instead of the general "not available" (the free transcriptions are used up).
    var unavailableMessage: String? {
        didSet {
            self.updatePlaceholder()
        }
    }

    private func updatePlaceholder() {
        switch self.placeholder {
        case .loading:
            self.placeholderLabel.isHidden = true
            self.skeletonNode.view.isHidden = false
        case .unavailable:
            self.placeholderLabel.text = self.unavailableMessage ?? self.presentationData?.strings.VoiceTranscript_TranscriptUnavailable ?? "Transcript is not available for this voice message"
            self.placeholderLabel.isHidden = false
            self.skeletonNode.view.isHidden = true
        case nil:
            self.placeholderLabel.isHidden = true
            self.skeletonNode.view.isHidden = true
        }
        self.layoutPlaceholder()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else {
            return
        }
        if self.isOnHandle(recognizer.location(in: self.scrollView)) {
            return
        }
        // The tap that ends a long press is not a tap.
        if CACurrentMediaTime() - self.lastLongPressEnd < 0.4 {
            return
        }
        // A tap anywhere drops a selection, and does not seek.
        if self.hasSelection {
            self.clearSelection()
            return
        }
        let point = recognizer.location(in: self.scrollView)
        if let row = self.rows.first(where: { $0.frame.contains(point) }) {
            row.handleTap(at: self.scrollView.convert(point, to: row))
        }
    }

    var hasSelection: Bool {
        return self.selectionAnchor != nil
    }

    func clearSelection() {
        self.selectionAnchor = nil
        self.selectionFocus = nil
        for row in self.rows {
            row.selectedWords = nil
        }
        self.dismissEditMenu()
        self.updateHandles()
    }

    /// The word under a point of the scroll view. Past the first or last line it clamps to the first or last word, so a
    /// drag that goes beyond the text still selects up to its edge.
    private func word(at location: CGPoint, clamping: Bool) -> (row: Int, word: Int)? {
        guard let firstRow = self.rows.first, let lastRow = self.rows.last else {
            return nil
        }
        if let index = self.rows.firstIndex(where: { location.y >= $0.frame.minY && location.y < $0.frame.maxY }) {
            let row = self.rows[index]
            if let word = row.nearestWord(at: self.scrollView.convert(location, to: row)) {
                return (index, word)
            }
            return nil
        }
        if !clamping {
            return nil
        }
        if location.y < firstRow.frame.minY {
            return (0, 0)
        }
        if location.y >= lastRow.frame.maxY {
            return (self.rows.count - 1, max(0, lastRow.wordCount - 1))
        }
        return nil
    }

    private func orderedSelection() -> (start: (row: Int, word: Int), end: (row: Int, word: Int))? {
        guard let anchor = self.selectionAnchor, let focus = self.selectionFocus else {
            return nil
        }
        if anchor.row < focus.row || (anchor.row == focus.row && anchor.word <= focus.word) {
            return (anchor, focus)
        }
        return (focus, anchor)
    }

    private func applySelection() {
        let selection = self.orderedSelection()
        for (index, row) in self.rows.enumerated() {
            guard let selection, index >= selection.start.row, index <= selection.end.row, row.wordCount > 0 else {
                row.selectedWords = nil
                continue
            }
            let first = index == selection.start.row ? selection.start.word : 0
            let last = index == selection.end.row ? selection.end.word : row.wordCount - 1
            row.selectedWords = first <= last ? first ... last : nil
        }
        self.updateHandles()
    }

    private func wordRect(_ reference: (row: Int, word: Int)) -> CGRect? {
        guard reference.row >= 0, reference.row < self.rows.count else {
            return nil
        }
        let row = self.rows[reference.row]
        guard let rect = row.wordRect(reference.word) else {
            return nil
        }
        return rect.offsetBy(dx: row.frame.minX, dy: row.frame.minY)
    }

    /// The handles sit on the first and the last selected word, and are hidden when nothing is selected.
    private func updateHandles() {
        guard let selection = self.orderedSelection(), let startRect = self.wordRect(selection.start), let endRect = self.wordRect(selection.end) else {
            self.startHandle.isHidden = true
            self.endHandle.isHidden = true
            return
        }
        let knob = VoiceTranscriptSelectionHandle.knobSize
        let width: CGFloat = 28.0
        self.startHandle.frame = CGRect(x: startRect.minX - width / 2.0, y: startRect.minY - knob, width: width, height: startRect.height + knob)
        self.endHandle.frame = CGRect(x: endRect.maxX - width / 2.0, y: endRect.minY, width: width, height: endRect.height + knob)
        self.startHandle.isHidden = false
        self.endHandle.isHidden = false
        self.scrollView.bringSubviewToFront(self.startHandle)
        self.scrollView.bringSubviewToFront(self.endHandle)
    }

    /// The menu for a selection is the system's horizontal one: Quote, Copy and Translate.
    private func presentMenu() {
        guard let target = self.selectionTargetRect() else {
            return
        }
        self.menuTargetRect = target
        if #available(iOS 16.0, *), let interaction = self.editMenuInteractionObject as? UIEditMenuInteraction {
            let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: target.midX, y: target.minY))
            // The menu goes above the selection (it only goes below when there is no room above).
            configuration.preferredArrowDirection = .down
            interaction.presentEditMenu(with: configuration)
        }
    }

    /// The part of the selection that is on screen, as a rectangle in this view's coordinates: the width of the selected
    /// words when they are all on one line, the width of the text otherwise, and from the top of the first selected word to
    /// the bottom of the last one. Clipped to what is visible, so the menu is never anchored to a line scrolled out of sight.
    private func selectionTargetRect() -> CGRect? {
        guard let selection = self.orderedSelection(), let startRect = self.wordRect(selection.start), let endRect = self.wordRect(selection.end) else {
            return nil
        }
        var rect: CGRect
        if selection.start.row == selection.end.row && abs(startRect.minY - endRect.minY) < 1.0 {
            rect = CGRect(x: startRect.minX, y: startRect.minY, width: max(1.0, endRect.maxX - startRect.minX), height: startRect.height)
        } else {
            let left = VoiceTranscriptRowView.textLeftInset
            rect = CGRect(x: left, y: startRect.minY, width: max(1.0, self.scrollView.bounds.width - left - VoiceTranscriptRowView.rightInset), height: max(1.0, endRect.maxY - startRect.minY))
        }
        let visible = self.scrollView.bounds
        let clipped = rect.intersection(visible)
        if !clipped.isNull && clipped.height > 0.0 {
            rect = clipped
        }
        return self.scrollView.convert(rect, to: self)
    }

    private func dismissEditMenu() {
        if #available(iOS 16.0, *), let interaction = self.editMenuInteractionObject as? UIEditMenuInteraction {
            interaction.dismissMenu()
        }
    }

    fileprivate func menuForSelection() -> UIMenu? {
        guard self.canExportText?() == true, self.selectedTextAndTimes() != nil, let strings = self.presentationData?.strings else {
            return nil
        }
        // Quote works like Reply: the chat gets a reply to the voice message, with the chosen time and words.
        let quote = UIAction(title: strings.Conversation_ContextMenuQuote, image: UIImage(systemName: "arrowshape.turn.up.left")) { [weak self] _ in
            guard let self, self.canExportText?() == true, let selected = self.selectedTextAndTimes() else {
                return
            }
            self.requestReply?(selected.text, selected.timeText)
            self.clearSelection()
        }
        let copy = UIAction(title: strings.Conversation_ContextMenuCopy, image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            guard let self, self.canExportText?() == true, let selected = self.selectedTextAndTimes() else {
                return
            }
            UIPasteboard.general.string = selected.text
            self.clearSelection()
        }
        // Translate opens the translator of the app (the same popup as for the whole transcript) with the selected text in it.
        let translate = UIAction(title: strings.Conversation_ContextMenuTranslate) { [weak self] _ in
            guard let self, self.canExportText?() == true, let selected = self.selectedTextAndTimes() else {
                return
            }
            self.requestTranslate?(selected.text)
            self.clearSelection()
        }
        let share = UIAction(title: strings.Conversation_ContextMenuShare, image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
            guard let self, self.canExportText?() == true, let selected = self.selectedTextAndTimes() else { return }
            self.requestShareQuote?(selected.text, selected.timeText)
            self.clearSelection()
        }
        return UIMenu(children: [quote, copy, translate, share])
    }

    private func isOnHandle(_ location: CGPoint) -> Bool {
        if self.startHandle.isHidden {
            return false
        }
        return self.startHandle.frame.insetBy(dx: -14.0, dy: -14.0).contains(location) || self.endHandle.frame.insetBy(dx: -14.0, dy: -14.0).contains(location)
    }

    @objc private func handlePanned(_ recognizer: UIPanGestureRecognizer) {
        guard let handle = recognizer.view as? VoiceTranscriptSelectionHandle else {
            return
        }
        switch recognizer.state {
        case .began:
            guard let selection = self.orderedSelection() else {
                return
            }
            self.dismissEditMenu()
            self.scrollView.isScrollEnabled = false
            self.isDraggingHandle = true
            // The end that is not dragged stays where it is.
            self.selectionAnchor = handle.isStart ? selection.end : selection.start
            self.selectionFocus = handle.isStart ? selection.start : selection.end
        case .changed:
            guard self.isDraggingHandle, let anchor = self.selectionAnchor else {
                return
            }
            // The finger is on the knob, a little off the line: aim at the line itself.
            var point = recognizer.location(in: self.scrollView)
            point.y += handle.isStart ? 16.0 : -16.0
            guard var target = self.word(at: point, clamping: true) else {
                return
            }
            // A handle never goes past the other one.
            if handle.isStart {
                if target.row > anchor.row || (target.row == anchor.row && target.word > anchor.word) {
                    target = anchor
                }
            } else {
                if target.row < anchor.row || (target.row == anchor.row && target.word < anchor.word) {
                    target = anchor
                }
            }
            if self.selectionFocus?.row != target.row || self.selectionFocus?.word != target.word {
                self.selectionFocus = target
                self.applySelection()
            }
            self.scrollNearEdge(recognizer.location(in: self.scrollView))
        case .ended, .cancelled:
            self.scrollView.isScrollEnabled = true
            self.isDraggingHandle = false
            if self.selectionAnchor != nil {
                self.presentMenu()
            }
        default:
            break
        }
    }

    /// Near the top or bottom edge the list follows the finger, so a selection can be taken further.
    private func scrollNearEdge(_ location: CGPoint) {
        let visibleY = location.y - self.scrollView.contentOffset.y
        let maxOffset = max(0.0, self.scrollView.contentSize.height - self.scrollView.bounds.height)
        if visibleY < 50.0 {
            self.scrollView.contentOffset.y = max(0.0, self.scrollView.contentOffset.y - 8.0)
        } else if visibleY > self.scrollView.bounds.height - 50.0 {
            self.scrollView.contentOffset.y = min(maxOffset, self.scrollView.contentOffset.y + 8.0)
        }
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        let location = recognizer.location(in: self.scrollView)
        switch recognizer.state {
        case .began:
            self.isLongPressOnHandle = self.isOnHandle(location)
            if self.isLongPressOnHandle {
                return
            }
            self.dismissEditMenu()
            guard let target = self.word(at: location, clamping: false) else {
                return
            }
            // The finger now selects instead of scrolling.
            self.scrollView.isScrollEnabled = false
            self.selectionAnchor = target
            self.selectionFocus = target
            self.applySelection()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .changed:
            guard !self.isLongPressOnHandle, self.selectionAnchor != nil, let target = self.word(at: location, clamping: true) else {
                return
            }
            if self.selectionFocus?.row != target.row || self.selectionFocus?.word != target.word {
                self.selectionFocus = target
                self.applySelection()
            }
            self.scrollNearEdge(location)
        case .ended:
            self.lastLongPressEnd = CACurrentMediaTime()
            if self.isLongPressOnHandle {
                self.isLongPressOnHandle = false
                return
            }
            self.scrollView.isScrollEnabled = true
            if self.selectionAnchor != nil {
                self.presentMenu()
            }
        case .cancelled, .failed:
            self.lastLongPressEnd = CACurrentMediaTime()
            if self.isLongPressOnHandle {
                self.isLongPressOnHandle = false
                return
            }
            self.scrollView.isScrollEnabled = true
            self.clearSelection()
        default:
            break
        }
    }

    /// The selected words as one text, with the time the selection starts and ends at.
    fileprivate func selectedTextAndTimes() -> (text: String, start: Double, end: Double, timeText: String)? {
        guard let selection = self.orderedSelection() else {
            return nil
        }
        var parts: [String] = []
        var start: Double?
        var end: Double = 0.0
        for index in selection.start.row ... selection.end.row {
            let row = self.rows[index]
            let first = index == selection.start.row ? selection.start.word : 0
            let last = index == selection.end.row ? selection.end.word : row.wordCount - 1
            if first > last {
                continue
            }
            parts.append(row.text(forWords: first ... last))
            if start == nil {
                start = row.segment.words[first].start
            }
            end = row.segment.words[last].end
        }
        guard let start else {
            return nil
        }
        // The time as it reads beside the lines: one time for a selection inside a single line, from the first line's time to
        // the last line's time when it runs over several.
        let firstTime = formatVoiceTranscriptTime(self.rows[selection.start.row].segment.start)
        let lastTime = formatVoiceTranscriptTime(self.rows[selection.end.row].segment.start)
        let timeText = selection.start.row == selection.end.row || firstTime == lastTime ? firstTime : firstTime + " - " + lastTime
        return (parts.joined(separator: " "), start, end, timeText)
    }

    private func layoutPlaceholder() {
        let inset: CGFloat = 32.0
        let labelSize = self.placeholderLabel.sizeThatFits(CGSize(width: max(0.0, self.validSize.width - inset * 2.0), height: .greatestFiniteMagnitude))
        let top = floor((self.validSize.height - labelSize.height) / 2.0) - 20.0
        self.placeholderLabel.frame = CGRect(origin: CGPoint(x: inset, y: top), size: CGSize(width: max(0.0, self.validSize.width - inset * 2.0), height: labelSize.height))
        self.layoutSkeleton()
    }

    /// Bars laid out like the lines will be: a short one for the time, then one or two for the text, with the same padding
    /// and the same left edge, so the real lines replace them without anything moving.
    private func layoutSkeleton() {
        if self.skeletonNode.view.isHidden || self.validSize.width <= 0.0 || self.validSize.height <= 0.0 {
            return
        }
        let size = self.validSize
        let patterns: [[CGFloat]] = [[1.0, 0.7], [0.85], [1.0, 0.45], [0.6], [1.0, 0.8], [0.7], [1.0, 0.55], [0.9]]
        let textLeft = VoiceTranscriptRowView.textLeftInset
        let textWidth = size.width - textLeft - VoiceTranscriptRowView.rightInset
        // The bars of text are 16pt tall with corners of 3pt; the time keeps its fully rounded 10pt bar.
        let barHeight: CGFloat = 16.0
        let barCornerRadius: CGFloat = 3.0
        let lineHeight = self.metrics.lineHeight

        var shapes: [ShimmerEffectNode.Shape] = []
        var y = VoiceTranscriptListView.topInset
        var index = 0
        while y < size.height {
            let pattern = patterns[index % patterns.count]
            y += VoiceTranscriptRowView.verticalPadding
            shapes.append(.roundedRectLine(startPoint: CGPoint(x: VoiceTranscriptRowView.outerInset, y: y + floor((lineHeight - 10.0) / 2.0)), width: 26.0, diameter: 10.0))
            for (lineIndex, fraction) in pattern.enumerated() {
                let lineY = y + CGFloat(lineIndex) * lineHeight + floor((lineHeight - barHeight) / 2.0)
                shapes.append(.roundedRect(rect: CGRect(x: textLeft, y: lineY, width: floor(textWidth * fraction), height: barHeight), cornerRadius: barCornerRadius))
            }
            y += CGFloat(pattern.count) * lineHeight + VoiceTranscriptRowView.verticalPadding
            index += 1
        }

        let dark = self.theme.overallDarkAppearance
        self.skeletonNode.frame = CGRect(origin: CGPoint(), size: size)
        self.skeletonNode.update(
            backgroundColor: .clear,
            foregroundColor: voiceTranscriptTextColor(self.theme, alpha: 0.1),
            shimmeringColor: UIColor.white.withAlphaComponent(dark ? 0.12 : 0.6),
            shapes: shapes,
            horizontal: true,
            size: size,
            mask: true
        )
        self.skeletonNode.updateAbsoluteRect(CGRect(origin: CGPoint(), size: size), within: size)
    }

    var isSearchMode: Bool = false {
        didSet {
            for row in self.rows {
                row.isSearchMode = self.isSearchMode
            }
        }
    }

    private var lastSearchProgress: CGFloat = 0.0

    /// While the search is open the text has no fade at its top edge; the fade goes away as the search opens.
    func setSearchProgress(_ progress: CGFloat) {
        if progress == self.lastSearchProgress {
            return
        }
        self.lastSearchProgress = progress
        guard let mask = self.layer.mask as? CAGradientLayer else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.locations = [0.0, NSNumber(value: Double(0.06 * (1.0 - progress))), 0.9, 1.0]
        CATransaction.commit()
    }

    /// The height of the keyboard while searching: the end of the text can be scrolled above it.
    var keyboardInset: CGFloat = 0.0 {
        didSet {
            if self.keyboardInset != oldValue {
                self.scrollView.contentInset.bottom = self.keyboardInset
                self.scrollView.verticalScrollIndicatorInsets.bottom = self.keyboardInset
            }
        }
    }

    var searchQuery: String? {
        didSet {
            for row in self.rows {
                row.searchQuery = self.searchQuery
            }
            if let query = self.searchQuery, let row = self.rows.first(where: { $0.matches(query) }) {
                let maxOffset = max(0.0, self.scrollView.contentSize.height - self.scrollView.bounds.height)
                self.scrollView.setContentOffset(CGPoint(x: 0.0, y: min(max(0.0, row.frame.minY - VoiceTranscriptListView.topInset), maxOffset)), animated: true)
            }
        }
    }

    var transcript: VoiceTranscript? {
        didSet {
            self.rebuildRows()
        }
    }

    var metrics: VoiceTranscriptTextMetrics = .standard {
        didSet {
            if self.metrics != oldValue {
                self.rebuildRows()
            }
        }
    }

    /// The first position is set without animation, so the sheet never shows the list scrolling into place.
    private var didInitialScroll = false

    /// The width the lines were last split for.
    private var splitWidth: CGFloat = 0.0

    /// Cuts the lines so that no time stamp has more than two lines of text under it: more are hard to take in. A line is
    /// cut between words, and each part keeps its words' own times, so the new time stamps are exact.
    private func splitSegments(_ segments: [VoiceTranscriptSegment]) -> [VoiceTranscriptSegment] {
        let textWidth = self.validSize.width - VoiceTranscriptRowView.textLeftInset - VoiceTranscriptRowView.rightInset - 2.0
        if textWidth <= 0.0 {
            return segments
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = self.metrics.lineHeight
        paragraph.maximumLineHeight = self.metrics.lineHeight
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Font.semibold(self.metrics.fontSize),
            .kern: self.metrics.kerning,
            .paragraphStyle: paragraph
        ]
        let maxHeight = self.metrics.lineHeight * 2.0 + 1.0

        func fits(_ words: [VoiceTranscriptWord]) -> Bool {
            let text = words.map(\.text).joined(separator: " ")
            let rect = NSAttributedString(string: text, attributes: attributes).boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil)
            return ceil(rect.height) <= maxHeight
        }

        var result: [VoiceTranscriptSegment] = []
        for segment in segments {
            var current: [VoiceTranscriptWord] = []
            for word in segment.words {
                if !current.isEmpty && !fits(current + [word]) {
                    result.append(VoiceTranscriptSegment(words: current))
                    current = []
                }
                current.append(word)
            }
            if !current.isEmpty {
                result.append(VoiceTranscriptSegment(words: current))
            }
        }

        // Two lines must never carry the same time stamp (0:05 and 0:05 below each other). Where a cut would produce that,
        // the parts stay together, even if that makes a line three rows tall: it is the exception.
        var merged: [VoiceTranscriptSegment] = []
        for segment in result {
            if let previous = merged.last, formatVoiceTranscriptTime(previous.start) == formatVoiceTranscriptTime(segment.start) {
                merged[merged.count - 1] = VoiceTranscriptSegment(words: previous.words + segment.words)
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    private func rebuildRows() {
        self.clearSelection()
        for row in self.rows {
            row.removeFromSuperview()
        }
        self.rows = []
        self.currentActiveIndex = nil
        self.didInitialScroll = false
        guard let transcript = self.transcript else {
            return
        }
        self.splitWidth = self.validSize.width
        for segment in self.splitSegments(transcript.segments) {
            let row = VoiceTranscriptRowView(segment: segment, theme: self.theme, metrics: self.metrics)
            row.seekTo = { [weak self] time in
                self?.seekTo?(time)
            }
            row.searchQuery = self.searchQuery
            row.isSearchMode = self.isSearchMode
            self.scrollView.addSubview(row)
            self.rows.append(row)
        }
        self.layoutRows(width: self.validSize.width)
        self.applyTime()
    }

    var currentTime: Double = 0.0 {
        didSet {
            self.applyTime()
        }
    }

    init(theme: PresentationTheme) {
        self.theme = theme
        self.scrollView = UIScrollView()
        self.startHandle = VoiceTranscriptSelectionHandle(isStart: true, color: voiceTranscriptBlue(theme))
        self.endHandle = VoiceTranscriptSelectionHandle(isStart: false, color: voiceTranscriptBlue(theme))
        super.init(frame: CGRect())

        self.scrollView.delegate = self
        self.scrollView.alwaysBounceVertical = true
        self.scrollView.showsVerticalScrollIndicator = false
        self.addSubview(self.scrollView)

        // One recognizer decides every tap: it first drops a text selection, wherever the tap lands, and only then seeks.
        let tap = UITapGestureRecognizer(target: self, action: #selector(self.tapped(_:)))
        tap.delegate = self
        tap.cancelsTouchesInView = false
        self.scrollView.addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(self.longPressed(_:)))
        longPress.minimumPressDuration = 0.3
        longPress.delegate = self
        self.scrollView.addGestureRecognizer(longPress)
        // A press that became a selection must not also be taken for a tap when the finger lifts: that tap would drop the
        // selection the moment it was made. (A quick tap still goes through at once, as the long press fails when it lifts.)
        tap.require(toFail: longPress)

        if #available(iOS 16.0, *) {
            let interaction = UIEditMenuInteraction(delegate: self)
            self.addInteraction(interaction)
            self.editMenuInteractionObject = interaction
        }

        // The handles at the two ends of a selection. Dragging one moves that end only.
        for handle in [self.startHandle, self.endHandle] {
            handle.isHidden = true
            let pan = UIPanGestureRecognizer(target: self, action: #selector(self.handlePanned(_:)))
            pan.delegate = self
            handle.addGestureRecognizer(pan)
            self.scrollView.addSubview(handle)
        }

        self.placeholderLabel.font = Font.regular(15.0)
        self.placeholderLabel.textColor = theme.list.itemSecondaryTextColor
        self.placeholderLabel.textAlignment = .center
        self.placeholderLabel.numberOfLines = 0
        self.placeholderLabel.isHidden = true
        self.skeletonNode.view.isUserInteractionEnabled = false
        self.skeletonNode.view.isHidden = true
        self.addSubview(self.skeletonNode.view)
        self.addSubview(self.placeholderLabel)

        // Fade the first and last lines like the design does.
        let mask = CAGradientLayer()
        mask.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        mask.locations = [0.0, 0.06, 0.9, 1.0]
        self.layer.mask = mask
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateLayout(size: CGSize) {
        let previousWidth = self.validSize.width
        self.validSize = size
        self.scrollView.frame = CGRect(origin: CGPoint(), size: size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.layer.mask?.frame = CGRect(origin: CGPoint(), size: size)
        CATransaction.commit()

        self.layoutPlaceholder()

        // Rows only need measuring again when the width changes; the height changes on every expansion step.
        if previousWidth != size.width {
            if self.transcript != nil && self.splitWidth != size.width {
                self.rebuildRows()
            } else {
                self.layoutRows(width: size.width)
            }
        } else {
            self.updateContentSize()
        }
    }

    private var contentHeight: CGFloat = 0.0
    /// The first line starts below the fade at the top edge.
    private static let topInset: CGFloat = 16.0

    private func layoutRows(width: CGFloat) {
        var y: CGFloat = VoiceTranscriptListView.topInset
        for row in self.rows {
            let height = row.updateLayout(width: width)
            row.frame = CGRect(origin: CGPoint(x: 0.0, y: y), size: CGSize(width: width, height: height))
            y += height
        }
        self.contentHeight = y
        self.updateContentSize()
        self.updateHandles()
    }

    private func updateContentSize() {
        // Only as much as it takes for the last line to clear the fade at the bottom edge.
        let bottomPadding = self.validSize.height * 0.1
        self.scrollView.contentSize = CGSize(width: self.validSize.width, height: self.contentHeight + bottomPadding)
    }

    private func applyTime() {
        // The line being spoken is the last one that has started, or the first before any has: some line is always active.
        var activeIndex: Int?
        if self.currentTime >= 0.0 && !self.rows.isEmpty {
            activeIndex = self.rows.lastIndex(where: { $0.segment.start <= self.currentTime }) ?? 0
        }
        for (index, row) in self.rows.enumerated() {
            if let activeIndex {
                row.lineState = index < activeIndex ? .past : (index == activeIndex ? .active : .upcoming)
            } else {
                row.lineState = .upcoming
            }
            row.applyState(currentTime: self.currentTime)
        }
        if activeIndex != self.currentActiveIndex {
            let animated = self.didInitialScroll
            self.currentActiveIndex = activeIndex
            self.scrollToActive(animated: animated)
            if activeIndex != nil {
                self.didInitialScroll = true
            }
        }
        self.updateActiveVisibility()
    }

    /// Brings the line that holds `time` into view, whatever the user's last scroll was.
    func scrollToTime(_ time: Double) {
        guard let row = self.rows.last(where: { $0.segment.start <= time }) ?? self.rows.first else {
            return
        }
        self.lastUserScrollTime = 0.0
        let maxOffset = max(0.0, self.scrollView.contentSize.height - self.scrollView.bounds.height)
        let offset = min(max(0.0, row.frame.minY - self.scrollView.bounds.height * 0.3), maxOffset)
        self.scrollView.setContentOffset(CGPoint(x: 0.0, y: offset), animated: false)
    }

    /// Scrolls (smoothly) to the line being spoken, whatever the user did before.
    func resumeFollowing() {
        self.isFollowing = true
        self.lastUserScrollTime = 0.0
        self.scrollToActive(animated: true)
    }

    private func updateActiveVisibility() {
        var visible = true
        if let index = self.currentActiveIndex, index < self.rows.count, self.scrollView.bounds.height > 0.0 {
            visible = self.rows[index].frame.intersects(self.scrollView.bounds)
        }
        if visible && !self.isUserScrolling {
            self.isFollowing = true
        }
        if visible != self.isActiveRowVisible {
            self.isActiveRowVisible = visible
            self.activeRowVisibilityChanged?(visible)
        }
    }

    private func scrollToActive(animated: Bool) {
        guard self.isAutoScrollEnabled, self.isFollowing, let index = self.currentActiveIndex, index < self.rows.count, !self.isUserScrolling else {
            return
        }
        if CACurrentMediaTime() - self.lastUserScrollTime < 2.0 {
            return
        }
        let frame = self.rows[index].frame
        let maxOffset = max(0.0, self.scrollView.contentSize.height - self.scrollView.bounds.height)
        let offset = min(max(0.0, frame.minY - self.scrollView.bounds.height * 0.3), maxOffset)
        self.scrollView.setContentOffset(CGPoint(x: 0.0, y: offset), animated: animated)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        self.updateActiveVisibility()
        if self.isAdjustingOffset || !scrollView.isDragging {
            return
        }
        let offset = scrollView.contentOffset.y
        if offset == 0.0 {
            return
        }
        let consumed = self.consumeScroll?(offset) ?? 0.0
        if consumed != 0.0 {
            self.isAdjustingOffset = true
            scrollView.contentOffset = CGPoint(x: 0.0, y: offset - consumed)
            self.isAdjustingOffset = false
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        self.isUserScrolling = true
        self.isFollowing = false
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if self.scrollEnded?() == true {
            scrollView.setContentOffset(CGPoint(x: 0.0, y: max(0.0, scrollView.contentOffset.y)), animated: false)
        }
        if !decelerate {
            self.isUserScrolling = false
            self.lastUserScrollTime = CACurrentMediaTime()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        self.isUserScrolling = false
        self.lastUserScrollTime = CACurrentMediaTime()
    }
}

@available(iOS 16.0, *)
extension VoiceTranscriptListView: UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        return self.menuForSelection()
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        return self.menuTargetRect
    }
}

// MARK: - Summary

/// The checkbox of a task: its touch area reaches a little past the drawn block, as the block itself is small.
private final class VoiceSummaryTickButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        return self.bounds.insetBy(dx: -4.0, dy: -8.0).contains(point)
    }
}

/// The base size of the text of lists for the text size the user has chosen (17 for the usual one), as the lists of settings use it.
private func voiceSummaryBaseFontSize(_ fontSize: PresentationFontSize) -> CGFloat {
    switch fontSize {
    case .extraSmall:
        return 14.0
    case .small:
        return 15.0
    case .medium:
        return 16.0
    case .regular:
        return 17.0
    case .large:
        return 19.0
    case .extraLarge:
        return 23.0
    case .extraLargeX2:
        return 26.0
    }
}

private final class VoiceSummaryView: UIView, UIScrollViewDelegate {
    private let theme: PresentationTheme
    private let strings: PresentationStrings
    private let baseFontSize: CGFloat

    /// A size from the design (made for the usual text size of 17) at the text size the user has chosen, whole points.
    private func scaled(_ size: CGFloat) -> CGFloat {
        return floor(self.baseFontSize * size / 17.0)
    }
    private let scrollView = UIScrollView()
    private var isUserScrolling = false

    var consumeScroll: ((CGFloat) -> CGFloat)?
    var scrollEnded: (() -> Bool)?
    private var isAdjustingOffset = false
    private var cards: [UIView] = []

    var seekTo: ((Double) -> Void)?

    /// One row of a card: its text, and either the time it points at (key points) or the number of its task (tasks).
    private struct Row {
        var text: String
        var time: Double?
        var taskIndex: Int?
        var isQuestion = false
        /// A tap on the row opens a menu (Reply, Copy); the time at its start is what seeks.
        var showsMenu = false
    }

    /// Which tasks are ticked. Kept here, so a tick survives the view being laid out again.
    private var taskStates: [Bool] = []
    /// Whether the whole headline is shown, when it is longer than three lines.
    private var isHeadlineExpanded = false
    private weak var headlineContainer: UIView?
    private weak var headlineLabel: UILabel?
    private weak var headlineMoreButton: UIButton?
    private var foldedHeadlineSize = CGSize()
    private var fullHeadlineSize = CGSize()

    /// The ticks outlive the sheet: they are saved by the text of the task, and read back when the summary is shown again.
    var loadTaskStates: (() -> [String: Bool])?
    var saveTaskStates: (([String: Bool]) -> Void)?
    var canExportText: (() -> Bool)?
    private var taskStateKeys: [String] = []
    /// A tap on a question: the chat is opened with the question quoted in the reply.
    /// A tap on a key point or a question: the view to anchor the menu to (the text of the item), a function that shows the row as active
    /// while its menu is open, the text, and the time of the item.
    var itemMenuRequested: ((UIView, @escaping (Bool) -> Void, String, Double) -> Void)?

    /// While the summary is made the tab shows a skeleton, then the summary, or that there is none.
    var state: VoiceSummaryState = .loading {
        didSet {
            self.isHeadlineExpanded = false
            if case let .ready(summary) = self.state {
                let saved = self.loadTaskStates?() ?? [:]
                self.taskStateKeys = summary.tasks.map { voiceSummaryTaskStateKey(text: $0.text, time: $0.time) }
                self.taskStates = summary.tasks.enumerated().map { index, task in
                    saved[self.taskStateKeys[index]] ?? saved[task.text] ?? task.isCompleted
                }
            }
            self.rebuild(animated: true)
            self.stateChanged?()
        }
    }

    /// Called when the state changes (the button under the summary shows Share only for a real summary).
    var stateChanged: (() -> Void)?
    /// Called after the text of a card was copied, so the screen can say so.
    var copied: (() -> Void)?

    /// The summary as text to send, with the tasks as they are ticked now. Nil unless a real summary is shown: a placeholder
    /// is not a summary of anything, and is never shared.
    var shareableText: String? {
        guard case let .ready(summary) = self.state, !summary.isPlaceholder else {
            return nil
        }
        var parts: [String] = []
        if !summary.headline.isEmpty {
            parts.append(summary.headline)
        }
        if !summary.keyPoints.isEmpty {
            parts.append(self.strings.VoiceTranscript_KeyPoints + "\n" + summary.keyPoints.map { "\(formatVoiceTranscriptTime($0.time)) \u{2014} \($0.text)" }.joined(separator: "\n"))
        }
        if !summary.tasks.isEmpty {
            parts.append(self.strings.VoiceTranscript_Tasks + "\n" + summary.tasks.enumerated().map { index, task in
                let isDone = index < self.taskStates.count ? self.taskStates[index] : task.isCompleted
                return (isDone ? "\u{2611} " : "\u{2610} ") + (task.time.map { formatVoiceTranscriptTime($0) + " — " } ?? "") + task.text
            }.joined(separator: "\n"))
        }
        if !summary.questions.isEmpty {
            parts.append(self.strings.VoiceTranscript_Questions + "\n" + summary.questions.map { "\(formatVoiceTranscriptTime($0.time)) \u{2014} \($0.text)" }.joined(separator: "\n"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    init(theme: PresentationTheme, strings: PresentationStrings, baseFontSize: CGFloat) {
        self.theme = theme
        self.strings = strings
        self.baseFontSize = baseFontSize
        super.init(frame: CGRect())
        self.scrollView.delegate = self
        self.scrollView.alwaysBounceVertical = true
        self.addSubview(self.scrollView)

        // The same fade at the top edge as the transcript has, so the content goes under the tabs.
        let mask = CAGradientLayer()
        mask.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor]
        // The fade at the top edge grows with the scrolling: there is none when the tab is at its top.
        mask.locations = [0.0, 0.0, 1.0]
        self.layer.mask = mask
    }

    private var lastTopFade: CGFloat = 0.0

    /// The fade at the top edge follows the scroll offset: nothing at the top, the full fade after 30pt of scrolling, smoothly between.
    private func updateTopFade() {
        let fade = min(1.0, max(0.0, self.scrollView.contentOffset.y / 30.0))
        if abs(fade - self.lastTopFade) < 0.002 {
            return
        }
        self.lastTopFade = fade
        guard let mask = self.layer.mask as? CAGradientLayer else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.locations = [0.0, NSNumber(value: Double(0.06 * fade)), 1.0]
        CATransaction.commit()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        self.updateTopFade()
        if self.isAdjustingOffset || !scrollView.isDragging {
            return
        }
        let offset = scrollView.contentOffset.y
        if offset == 0.0 {
            return
        }
        let consumed = self.consumeScroll?(offset) ?? 0.0
        if consumed != 0.0 {
            self.isAdjustingOffset = true
            scrollView.contentOffset = CGPoint(x: 0.0, y: offset - consumed)
            self.isAdjustingOffset = false
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        self.isUserScrolling = true
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if self.scrollEnded?() == true {
            scrollView.setContentOffset(CGPoint(x: 0.0, y: max(0.0, scrollView.contentOffset.y)), animated: false)
        }
        if !decelerate {
            self.isUserScrolling = false
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        self.isUserScrolling = false
    }

    private var validSize = CGSize()
    private var validBottomInset: CGFloat = 0.0

    func updateLayout(size: CGSize, bottomInset: CGFloat) {
        let previousWidth = self.validSize.width
        self.validSize = size
        self.validBottomInset = bottomInset
        self.scrollView.frame = CGRect(origin: CGPoint(), size: size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.layer.mask?.frame = CGRect(origin: CGPoint(), size: size)
        CATransaction.commit()
        if previousWidth != size.width {
            self.rebuild()
        }
    }

    private func label(_ text: String, font: UIFont, color: UIColor) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.font = font
        label.textColor = color
        label.text = text
        return label
    }

    private func rebuild(animated: Bool = false) {
        guard self.validSize.width > 0.0 else {
            return
        }
        let apply = {
            switch self.state {
            case .loading:
                self.buildSkeleton()
            case let .ready(summary):
                self.buildContent(summary)
            case .unavailable:
                self.buildUnavailable()
            }
        }
        if animated {
            UIView.transition(with: self.scrollView, duration: 0.25, options: [.transitionCrossDissolve, .allowUserInteraction], animations: apply)
        } else {
            apply()
        }
    }

    /// Opens or folds the headline in place: the container grows or shrinks, and every view under it moves by the same distance
    /// in the same animation, so nothing is built again and nothing jumps.
    private func toggleHeadline() {
        guard let container = self.headlineContainer, let label = self.headlineLabel else {
            return
        }
        self.isHeadlineExpanded = !self.isHeadlineExpanded
        let expanded = self.isHeadlineExpanded
        let targetHeight = expanded ? self.fullHeadlineSize.height : self.foldedHeadlineSize.height
        let delta = targetHeight - container.frame.height
        let threshold = container.frame.maxY - 0.5
        let below = self.scrollView.subviews.filter { $0 !== container && $0.frame.minY >= threshold }

        // The whole text is laid out for the length of the animation, so it is revealed (or covered) by the container alone.
        label.numberOfLines = 0
        label.frame = CGRect(origin: CGPoint(), size: self.fullHeadlineSize)
        UIView.performWithoutAnimation {
            self.headlineMoreButton?.setTitle(expanded ? self.strings.VoiceTranscript_Less : self.strings.VoiceTranscript_More, for: .normal)
            self.headlineMoreButton?.layoutIfNeeded()
        }
        let contentHeight = self.scrollView.contentSize.height
        UIView.animate(withDuration: 0.35, delay: 0.0, usingSpringWithDamping: 1.0, initialSpringVelocity: 0.0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
            container.frame.size.height = targetHeight
            for view in below {
                view.frame.origin.y += delta
            }
            self.scrollView.contentSize = CGSize(width: self.scrollView.contentSize.width, height: contentHeight + delta)
        }, completion: { [weak self, weak label] _ in
            // Folded again: the third line gets its dots back.
            if let self, let label, !self.isHeadlineExpanded {
                label.numberOfLines = 3
                label.frame = CGRect(origin: CGPoint(), size: self.foldedHeadlineSize)
            }
        })
    }

    private func buildContent(_ summary: VoiceSummary) {
        for view in self.scrollView.subviews {
            view.removeFromSuperview()
        }

        let sideInset: CGFloat = 16.0
        let width = self.validSize.width
        let innerWidth = width - sideInset * 2.0
        var y: CGFloat = 20.0

        // The headline shows three lines. When it is longer, "more" opens all of it, and "less" folds it again; the text is
        // revealed by a container that grows, and everything under it moves by the same amount, in one animation.
        // A microphone and a space in front of the headline: it is what the voice message says.
        let headline = self.label("\u{1F399}\u{FE0F} " + summary.headline, font: Font.semibold(22.0), color: self.theme.list.itemPrimaryTextColor)
        let headlineConstraint = CGSize(width: innerWidth - 8.0, height: .greatestFiniteMagnitude)
        headline.numberOfLines = 0
        let fullHeadlineSize = headline.sizeThatFits(headlineConstraint)
        headline.numberOfLines = 3
        let foldedHeadlineSize = headline.sizeThatFits(headlineConstraint)
        let isHeadlineLong = fullHeadlineSize.height > foldedHeadlineSize.height + 1.0
        let showsFullHeadline = !isHeadlineLong || self.isHeadlineExpanded
        if showsFullHeadline {
            headline.numberOfLines = 0
        }
        let headlineSize = showsFullHeadline ? fullHeadlineSize : foldedHeadlineSize
        let headlineContainer = UIView()
        headlineContainer.clipsToBounds = true
        headlineContainer.frame = CGRect(origin: CGPoint(x: sideInset + 4.0, y: y), size: CGSize(width: headlineSize.width, height: headlineSize.height))
        headline.frame = CGRect(origin: CGPoint(), size: headlineSize)
        headlineContainer.addSubview(headline)
        self.scrollView.addSubview(headlineContainer)
        self.headlineContainer = headlineContainer
        self.headlineLabel = headline
        self.foldedHeadlineSize = foldedHeadlineSize
        self.fullHeadlineSize = fullHeadlineSize
        y += headlineSize.height + 6.0

        let moreWidth: CGFloat = isHeadlineLong ? 60.0 : 0.0
        let source = self.label(self.strings.VoiceTranscript_SummarySource, font: Font.regular(15.0), color: self.theme.list.itemSecondaryTextColor)
        source.frame = CGRect(origin: CGPoint(x: sideInset + 4.0, y: y), size: CGSize(width: innerWidth - moreWidth, height: 20.0))
        self.scrollView.addSubview(source)
        if isHeadlineLong {
            let moreButton = UIButton(type: .system)
            moreButton.titleLabel?.font = Font.regular(15.0)
            moreButton.setTitle(self.isHeadlineExpanded ? self.strings.VoiceTranscript_Less : self.strings.VoiceTranscript_More, for: .normal)
            moreButton.tintColor = voiceTranscriptBlue(self.theme)
            moreButton.contentHorizontalAlignment = .right
            moreButton.frame = CGRect(x: sideInset + innerWidth - moreWidth, y: y - 4.0, width: moreWidth, height: 28.0)
            moreButton.addAction(UIAction { [weak self] _ in
                self?.toggleHeadline()
            }, for: .touchUpInside)
            self.scrollView.addSubview(moreButton)
            self.headlineMoreButton = moreButton
        } else {
            self.headlineMoreButton = nil
        }
        y += 20.0 + 32.0

        // What follows a card, as in the lists of settings: the text under the section (7pt under the card, 7pt of its own below), and
        // then 28pt before the next section.
        func finishSection(hint: String) {
            let hintLabel = self.label(hint, font: Font.regular(self.scaled(13.0)), color: self.theme.list.freeTextColor)
            let hintSize = hintLabel.sizeThatFits(CGSize(width: innerWidth - 32.0, height: .greatestFiniteMagnitude))
            hintLabel.frame = CGRect(origin: CGPoint(x: sideInset + 16.0, y: y + 7.0), size: hintSize)
            self.scrollView.addSubview(hintLabel)
            y += 7.0 + hintSize.height + 7.0 + 28.0
        }

        // Each kind appears only when the summary has something of it. The order is key points, tasks, questions.
        if !summary.keyPoints.isEmpty {
            y = self.addCard(title: self.strings.VoiceTranscript_KeyPoints, y: y, innerWidth: innerWidth, sideInset: sideInset, rows: summary.keyPoints.map { point in
                return Row(text: point.text, time: point.time, taskIndex: nil, showsMenu: true)
            })
            finishSection(hint: self.strings.VoiceTranscript_ItemsHint)
        }

        if !summary.tasks.isEmpty {
            y = self.addCard(title: self.strings.VoiceTranscript_Tasks, y: y, innerWidth: innerWidth, sideInset: sideInset, rows: summary.tasks.enumerated().map { index, task in
                return Row(text: task.text, time: task.time, taskIndex: index)
            }, copyText: { [weak self] in
                // The tasks as they are ticked now.
                return summary.tasks.enumerated().map { index, task in
                    let isDone = (self?.taskStates.indices.contains(index) ?? false) ? (self?.taskStates[index] ?? task.isCompleted) : task.isCompleted
                    return (isDone ? "\u{2611} " : "\u{2610} ") + (task.time.map { formatVoiceTranscriptTime($0) + " — " } ?? "") + task.text
                }.joined(separator: "\n")
            })
            finishSection(hint: self.strings.VoiceTranscript_TasksHint)
        }

        if !summary.questions.isEmpty {
            y = self.addCard(title: self.strings.VoiceTranscript_Questions, y: y, innerWidth: innerWidth, sideInset: sideInset, rows: summary.questions.map { question in
                return Row(text: question.text, time: question.time, taskIndex: nil, isQuestion: true, showsMenu: true)
            })
            finishSection(hint: self.strings.VoiceTranscript_ItemsHint)
        }

        self.scrollView.contentSize = CGSize(width: width, height: y + 80.0 + self.validBottomInset)
    }

    private func buildUnavailable() {
        for view in self.scrollView.subviews {
            view.removeFromSuperview()
        }
        var message = self.strings.VoiceTranscript_SummaryUnavailable
        #if DEBUG
        if let reason = voiceSummaryDebugReason {
            message += "\n\n[debug] " + reason
        }
        #endif
        let label = self.label(message, font: Font.regular(15.0), color: self.theme.list.itemSecondaryTextColor)
        label.textAlignment = .center
        let inset: CGFloat = 32.0
        let size = label.sizeThatFits(CGSize(width: max(0.0, self.validSize.width - inset * 2.0), height: .greatestFiniteMagnitude))
        label.frame = CGRect(origin: CGPoint(x: inset, y: floor((self.validSize.height - size.height) / 2.0) - 40.0), size: CGSize(width: max(0.0, self.validSize.width - inset * 2.0), height: size.height))
        self.scrollView.addSubview(label)
        self.scrollView.contentSize = self.validSize
    }

    private struct SkeletonRow {
        enum Lead {
            case none
            case time
            case checkbox
        }
        var lead: Lead
        var lines: [CGFloat]
    }

    /// The same page with grey bars where the text will be: three bars for the headline (16pt tall, 3pt corners), and in the
    /// cards a time or a checkbox and bars of 12pt for text of two lines. A shimmer runs over all of them.
    private func buildSkeleton() {
        for view in self.scrollView.subviews {
            view.removeFromSuperview()
        }
        let sideInset: CGFloat = 16.0
        let width = self.validSize.width
        let innerWidth = width - sideInset * 2.0
        var y: CGFloat = 20.0
        var shapes: [ShimmerEffectNode.Shape] = []

        let headlineLine: CGFloat = 27.0
        for (index, fraction) in ([1.0, 1.0, 0.55] as [CGFloat]).enumerated() {
            shapes.append(.roundedRect(rect: CGRect(x: sideInset + 4.0, y: y + CGFloat(index) * headlineLine + floor((headlineLine - 16.0) / 2.0), width: floor((innerWidth - 8.0) * fraction), height: 16.0), cornerRadius: 3.0))
        }
        y += headlineLine * 3.0 + 6.0

        let source = self.label(self.strings.VoiceTranscript_SummarySource, font: Font.regular(15.0), color: self.theme.list.itemSecondaryTextColor)
        source.frame = CGRect(origin: CGPoint(x: sideInset + 4.0, y: y), size: CGSize(width: innerWidth, height: 20.0))
        self.scrollView.addSubview(source)
        y += 20.0 + 32.0

        y = self.addSkeletonCard(title: self.strings.VoiceTranscript_KeyPoints, y: y, innerWidth: innerWidth, sideInset: sideInset, rows: [
            SkeletonRow(lead: .time, lines: [1.0, 0.6]),
            SkeletonRow(lead: .time, lines: [0.9, 0.5])
        ], shapes: &shapes)
        y = self.addSkeletonCard(title: self.strings.VoiceTranscript_Tasks, y: y, innerWidth: innerWidth, sideInset: sideInset, rows: [
            SkeletonRow(lead: .checkbox, lines: [1.0, 0.7]),
            SkeletonRow(lead: .checkbox, lines: [0.8])
        ], shapes: &shapes)
        y = self.addSkeletonCard(title: self.strings.VoiceTranscript_Questions, y: y, innerWidth: innerWidth, sideInset: sideInset, rows: [
            SkeletonRow(lead: .time, lines: [0.9, 0.4])
        ], shapes: &shapes)

        let contentSize = CGSize(width: width, height: y)
        self.scrollView.contentSize = CGSize(width: width, height: y + 80.0 + self.validBottomInset)

        let dark = self.theme.overallDarkAppearance
        let node = ShimmerEffectNode()
        node.view.isUserInteractionEnabled = false
        self.scrollView.addSubview(node.view)
        node.frame = CGRect(origin: CGPoint(), size: contentSize)
        node.update(
            backgroundColor: .clear,
            foregroundColor: voiceTranscriptTextColor(self.theme, alpha: 0.1),
            shimmeringColor: UIColor.white.withAlphaComponent(dark ? 0.12 : 0.6),
            shapes: shapes,
            horizontal: true,
            size: contentSize,
            mask: true
        )
        node.updateAbsoluteRect(CGRect(origin: CGPoint(), size: contentSize), within: contentSize)
    }

    private func addSkeletonCard(title: String, y: CGFloat, innerWidth: CGFloat, sideInset: CGFloat, rows: [SkeletonRow], shapes: inout [ShimmerEffectNode.Shape]) -> CGFloat {
        let card = UIView()
        card.backgroundColor = self.theme.list.itemModalBlocksBackgroundColor
        card.layer.cornerRadius = 30.0
        card.layer.cornerCurve = .continuous

        let cardTop = y
        var cardY: CGFloat = 17.0
        let titleLabel = self.label(title, font: Font.semibold(self.scaled(13.0)), color: self.theme.list.itemSecondaryTextColor)
        titleLabel.frame = CGRect(origin: CGPoint(x: 16.0, y: cardY), size: CGSize(width: innerWidth - 32.0, height: 18.0))
        card.addSubview(titleLabel)
        // 25pt from the top of the title to the text as in Translate, and 3pt more to let the title breathe.
        cardY += 16.0

        // The text of a real row is 16pt with a line about 19pt tall; the bars stand where its lines will.
        let linePitch: CGFloat = Font.regular(self.scaled(17.0)).lineHeight
        let barHeight: CGFloat = self.scaled(13.0)
        for (index, row) in rows.enumerated() {
            let hasLead: Bool
            switch row.lead {
            case .none:
                hasLead = false
            default:
                hasLead = true
            }
            let textX: CGFloat = hasLead ? 16.0 + VoiceSummaryView.leftBlockWidth + VoiceSummaryView.leftBlockGap : 16.0
            let textWidth = innerWidth - textX - 16.0
            let textHeight = CGFloat(row.lines.count) * linePitch
            let rowHeight = max(textHeight, hasLead ? VoiceSummaryView.leftContentSize : 0.0) + VoiceSummaryView.rowTopPadding + VoiceSummaryView.rowBottomPadding
            let rowTop = cardTop + cardY + VoiceSummaryView.rowTopPadding

            for (lineIndex, fraction) in row.lines.enumerated() {
                shapes.append(.roundedRect(rect: CGRect(x: sideInset + textX, y: rowTop + CGFloat(lineIndex) * linePitch + floor((linePitch - barHeight) / 2.0), width: floor(textWidth * fraction), height: barHeight), cornerRadius: 3.0))
            }
            switch row.lead {
            case .time:
                shapes.append(.roundedRectLine(startPoint: CGPoint(x: sideInset + 16.0, y: rowTop + floor((linePitch - 10.0) / 2.0)), width: 26.0, diameter: 10.0))
            case .checkbox:
                shapes.append(.circle(CGRect(x: sideInset + 16.0, y: rowTop + floor((linePitch - VoiceSummaryView.leftContentSize) / 2.0), width: VoiceSummaryView.leftContentSize, height: VoiceSummaryView.leftContentSize)))
            case .none:
                break
            }
            cardY += rowHeight

            if index != rows.count - 1 {
                let separator = UIView()
                separator.backgroundColor = self.theme.list.itemPlainSeparatorColor
                separator.frame = CGRect(origin: CGPoint(x: textX, y: cardY), size: CGSize(width: innerWidth - textX - 16.0, height: 1.0 / UIScreenScale))
                card.addSubview(separator)
            }
        }
        cardY += 2.0

        card.frame = CGRect(origin: CGPoint(x: sideInset, y: cardTop), size: CGSize(width: innerWidth, height: cardY))
        self.scrollView.addSubview(card)
        // The next card starts 28pt under this one (the skeleton has no text between the cards).
        return cardTop + cardY + 28.0
    }

    /// The block at the start of a row (the time, or the checkbox) is 40pt wide, 4pt from the text; the checkbox itself is 22x22.
    fileprivate static let leftBlockWidth: CGFloat = 40.0
    fileprivate static let leftBlockGap: CGFloat = 4.0
    fileprivate static let leftContentSize: CGFloat = 22.0
    /// 12pt above the text of a row and 12pt under it, so 12pt between the text and the line, and between the line and the next text.
    fileprivate static let rowTopPadding: CGFloat = 12.0
    fileprivate static let rowBottomPadding: CGFloat = 12.0

    private func applyTask(completed: Bool, button: UIButton, label: UILabel) {
        // The circle fills exactly 22x22, however big the touch area around it is.
        button.setImage(voiceSummaryCheckboxImage(isChecked: completed, diameter: VoiceSummaryView.leftContentSize, outlineColor: self.theme.list.controlSecondaryColor, fillColor: voiceTranscriptBlue(self.theme)), for: .normal)
        label.textColor = completed ? self.theme.list.itemPrimaryTextColor.withAlphaComponent(0.4) : self.theme.list.itemPrimaryTextColor
    }

    private func addCard(title: String, y: CGFloat, innerWidth: CGFloat, sideInset: CGFloat, rows: [Row], copyText: (() -> String)? = nil) -> CGFloat {
        let card = UIView()
        card.backgroundColor = self.theme.list.itemModalBlocksBackgroundColor
        card.layer.cornerRadius = 30.0
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true

        let cardTop = y
        var cardY: CGFloat = 17.0
        let titleLabel = self.label(title, font: Font.semibold(self.scaled(13.0)), color: self.theme.list.itemSecondaryTextColor)
        titleLabel.frame = CGRect(origin: CGPoint(x: 16.0, y: cardY), size: CGSize(width: innerWidth - 32.0, height: 18.0))
        card.addSubview(titleLabel)
        // 25pt from the top of the title to the text as in Translate, and 3pt more to let the title breathe.
        cardY += 16.0

        // The tasks card ends with how many are done; it is kept up to date when a task is ticked.
        let hasTasks = rows.contains(where: { $0.taskIndex != nil })
        let progressLabel = self.label("", font: Font.regular(self.scaled(14.0)), color: voiceTranscriptTextColor(self.theme, alpha: 0.6))
        let updateProgress = { [weak self, weak progressLabel] in
            guard let self else {
                return
            }
            progressLabel?.text = self.strings.VoiceTranscript_TasksCompleted("\(self.taskStates.filter { $0 }.count)", "\(self.taskStates.count)").string
        }
        updateProgress()

        for (index, row) in rows.enumerated() {
            // A row may start with a block 40pt wide (the time of a key point, the tick of a task), with 4pt between it and the text.
            let hasLeftBlock = row.time != nil || row.taskIndex != nil || row.isQuestion
            let textX: CGFloat = hasLeftBlock ? 16.0 + VoiceSummaryView.leftBlockWidth + VoiceSummaryView.leftBlockGap : 16.0
            let text = self.label(row.text, font: Font.regular(self.scaled(17.0)), color: self.theme.list.itemPrimaryTextColor)
            let textSize = text.sizeThatFits(CGSize(width: innerWidth - textX - 16.0, height: .greatestFiniteMagnitude))
            let blockHeight: CGFloat = hasLeftBlock ? VoiceSummaryView.leftContentSize : 0.0
            let taskTimeHeight: CGFloat = row.taskIndex != nil && row.time != nil ? 44.0 : 0.0
            let rowHeightForButton = max(textSize.height, blockHeight) + VoiceSummaryView.rowTopPadding + VoiceSummaryView.rowBottomPadding + taskTimeHeight
            // The whole row is a button (below the text and the left block), so a tap anywhere on it acts like the block does.
            let rowButton = UIButton(type: .custom)
            rowButton.frame = CGRect(origin: CGPoint(x: 0.0, y: cardY), size: CGSize(width: innerWidth, height: rowHeightForButton))
            let highlightColor = self.theme.list.itemHighlightedBackgroundColor
            if !row.showsMenu {
                rowButton.addAction(UIAction { [weak rowButton] _ in
                    rowButton?.backgroundColor = highlightColor
                }, for: .touchDown)
                rowButton.addAction(UIAction { [weak rowButton] _ in
                    rowButton?.backgroundColor = nil
                }, for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
            }
            if hasLeftBlock || row.isQuestion {
                card.addSubview(rowButton)
            }
            if row.showsMenu {
                // A tap on a key point or a question opens a menu: reply to it in the chat, or copy it.
                let rowText = row.text
                let rowTime = row.time ?? 0.0
                rowButton.addAction(UIAction { [weak self, weak text] _ in
                    guard let text else {
                        return
                    }
                    // The text is shown at 60% while its menu is open, and the menu is anchored to the text, not to the whole row.
                    let setActive: (Bool) -> Void = { [weak text] isActive in
                        UIView.animate(withDuration: 0.2) {
                            text?.alpha = isActive ? 0.6 : 1.0
                        }
                    }
                    self?.itemMenuRequested?(text, setActive, rowText, rowTime)
                }, for: .touchUpInside)
            }
            // The block's content is centred on the first line of the text.
            let blockTop = cardY + VoiceSummaryView.rowTopPadding + (text.font.lineHeight - blockHeight) / 2.0
            // The text has 8pt under it before the line, and the left block is never taller than the row.
            let rowHeight = rowHeightForButton

            text.frame = CGRect(origin: CGPoint(x: textX, y: cardY + VoiceSummaryView.rowTopPadding), size: textSize)
            card.addSubview(text)

            if let time = row.time, row.taskIndex == nil {
                let button = UIButton(type: .system)
                button.titleLabel?.font = Font.regular(self.scaled(13.0))
                button.setTitle(formatVoiceTranscriptTime(time), for: .normal)
                button.tintColor = self.theme.list.itemAccentColor
                button.contentHorizontalAlignment = .left
                let seek = UIAction { [weak self] _ in
                    self?.seekTo?(time)
                }
                button.addAction(seek, for: .touchUpInside)
                // Only the time seeks: a tap on the rest of the row opens the menu of the key point or the question.
                button.frame = CGRect(origin: CGPoint(x: 16.0, y: blockTop), size: CGSize(width: VoiceSummaryView.leftBlockWidth, height: blockHeight))
                card.addSubview(button)
            } else if let taskIndex = row.taskIndex {
                // The 40pt block is the checkbox: tapping it ticks the task or takes the tick away.
                let button = VoiceSummaryTickButton(type: .system)
                button.frame = CGRect(origin: CGPoint(x: 16.0, y: blockTop), size: CGSize(width: VoiceSummaryView.leftBlockWidth, height: blockHeight))
                button.contentHorizontalAlignment = .left
                self.applyTask(completed: taskIndex < self.taskStates.count ? self.taskStates[taskIndex] : false, button: button, label: text)
                let toggle = UIAction { [weak self, weak button, weak text] _ in
                    guard let self, let button, let text, taskIndex < self.taskStates.count else {
                        return
                    }
                    self.taskStates[taskIndex] = !self.taskStates[taskIndex]
                    var saved: [String: Bool] = [:]
                    for (index, key) in self.taskStateKeys.enumerated() where index < self.taskStates.count {
                        saved[key] = self.taskStates[index]
                    }
                    self.saveTaskStates?(saved)
                    UIView.transition(with: card, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction], animations: {
                        self.applyTask(completed: self.taskStates[taskIndex], button: button, label: text)
                        updateProgress()
                    })
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                button.addAction(toggle, for: .touchUpInside)
                rowButton.addAction(toggle, for: .touchUpInside)
                card.addSubview(button)
            }
            if let time = row.time, row.taskIndex != nil {
                // A separate 44-point target seeks without changing completion state.
                let button = UIButton(type: .system)
                button.titleLabel?.font = Font.regular(self.scaled(13.0))
                button.setTitle(formatVoiceTranscriptTime(time), for: .normal)
                button.accessibilityLabel = NSLocalizedString("VoiceTranscript.JumpToTime", value: "Jump to audio", comment: "Seek to task timestamp")
                button.accessibilityValue = formatVoiceTranscriptTime(time)
                button.contentHorizontalAlignment = .left
                button.tintColor = self.theme.list.itemAccentColor
                button.frame = CGRect(x: textX, y: cardY + VoiceSummaryView.rowTopPadding + max(textSize.height, blockHeight), width: max(80.0, VoiceSummaryView.leftBlockWidth), height: 44.0)
                button.addAction(UIAction { [weak self] _ in self?.seekTo?(time) }, for: .touchUpInside)
                card.addSubview(button)
            }
            cardY += rowHeight

            if index != rows.count - 1 {
                let separator = UIView()
                separator.backgroundColor = self.theme.list.itemPlainSeparatorColor
                separator.frame = CGRect(origin: CGPoint(x: textX, y: cardY), size: CGSize(width: innerWidth - textX - 16.0, height: 1.0 / UIScreenScale))
                card.addSubview(separator)
            }
        }
        if hasTasks {
            progressLabel.frame = CGRect(origin: CGPoint(x: 16.0, y: cardY + 10.0), size: CGSize(width: innerWidth - 32.0 - 44.0, height: max(16.0, ceil(progressLabel.font.lineHeight))))
            card.addSubview(progressLabel)
            // The copy button is at the bottom right, in line with the counter, as the one of the Translate sheet is at the end of
            // its text. The sheet stays open after the copy.
            if let copyText {
                let icon = generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Copy"), color: self.theme.list.itemAccentColor)
                let iconWidth = icon?.size.width ?? 24.0
                let copyButton = UIButton(type: .custom)
                copyButton.setImage(icon, for: .normal)
                copyButton.frame = CGRect(x: innerWidth - 16.0 - iconWidth / 2.0 - 22.0, y: cardY + 10.0 + 8.0 - 22.0, width: 44.0, height: 44.0)
                copyButton.addAction(UIAction { [weak self] _ in
                    guard self?.canExportText?() == true else { return }
                    UIPasteboard.general.string = copyText()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    self?.copied?()
                }, for: .touchUpInside)
                card.addSubview(copyButton)
            }
            // 12pt between the last line and the text.
            cardY += 10.0 + max(16.0, ceil(progressLabel.font.lineHeight))
        }
        // 14pt under the last text, as in the blocks of the Translate screen (the last row already has 12pt of its own).
        cardY += hasTasks ? 14.0 : 2.0

        card.frame = CGRect(origin: CGPoint(x: sideInset, y: cardTop), size: CGSize(width: innerWidth, height: cardY))
        self.scrollView.addSubview(card)
        return cardTop + cardY
    }
}

// MARK: - Controls

private final class VoiceTranscriptWaveformView: UIView {
    private let theme: PresentationTheme
    private var bars: [CGFloat] = []
    private(set) var progress: CGFloat = 0.0
    private var isScrubbing = false

    var scrubbed: ((CGFloat, Bool) -> Void)?

    var waveform: AudioWaveform? {
        didSet {
            self.rebuildBars()
            self.setNeedsDisplay()
        }
    }

    init(theme: PresentationTheme) {
        self.theme = theme
        super.init(frame: CGRect())
        self.backgroundColor = .clear
        self.contentMode = .redraw
        self.rebuildBars()

        let pan = UIPanGestureRecognizer(target: self, action: #selector(self.panned(_:)))
        self.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(self.tapped(_:)))
        self.addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // The bar count is fixed so the shape never changes when the sheet's width does; the gap absorbs the width.
    private let barWidth: CGFloat = 3.0
    private let barCount: Int = 60

    private func rebuildBars() {
        let count = self.barCount
        var result: [CGFloat] = Array(repeating: 0.35, count: count)
        if let waveform = self.waveform, waveform.samples.count >= 2 {
            let sampleCount = waveform.samples.count / 2
            let samples: [UInt16] = waveform.samples.withUnsafeBytes { buffer in
                return Array(buffer.bindMemory(to: UInt16.self).prefix(sampleCount))
            }
            // The same drawing rules as the waveform in a chat bubble: the loudest sample of the voice message is the
            // full height (not the format's theoretical maximum), and each bar shows the loudest sample in its slice.
            let maxSample = max(1, samples.max() ?? 1)
            for i in 0 ..< count {
                let from = i * sampleCount / count
                let to = max(from + 1, (i + 1) * sampleCount / count)
                var peak: UInt16 = 0
                for j in from ..< min(to, sampleCount) {
                    peak = max(peak, samples[j])
                }
                result[i] = CGFloat(peak) / CGFloat(maxSample)
            }
        }
        self.bars = result
    }

    func setProgress(_ progress: CGFloat) {
        if self.isScrubbing {
            return
        }
        self.progress = min(max(0.0, progress), 1.0)
        self.setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), !self.bars.isEmpty else {
            return
        }
        // Played: 008BFF. Not played yet: CACACA (in the dark theme, the blue at a third of its strength).
        let accent = voiceTranscriptLineBlue()
        let unplayed = self.theme.overallDarkAppearance ? accent.withAlphaComponent(0.35) : UIColor(rgb: 0xCACACA)
        let height = self.bounds.height
        let spacing = max(1.0, (self.bounds.width - CGFloat(self.bars.count) * self.barWidth) / CGFloat(max(1, self.bars.count - 1)))
        for (index, value) in self.bars.enumerated() {
            let x = CGFloat(index) * (self.barWidth + spacing)
            let barHeight = max(self.barWidth, value * height)
            let barRect = CGRect(x: x, y: (height - barHeight) / 2.0, width: self.barWidth, height: barHeight)
            let isPlayed = (x + self.barWidth / 2.0) / max(1.0, self.bounds.width) <= self.progress
            context.setFillColor((isPlayed ? accent : unplayed).cgColor)
            // Round at both ends, and a dot at the smallest, as in the chat's waveform.
            context.addPath(UIBezierPath(roundedRect: barRect, cornerRadius: self.barWidth / 2.0).cgPath)
            context.fillPath()
        }
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        let value = min(max(0.0, recognizer.location(in: self).x / max(1.0, self.bounds.width)), 1.0)
        switch recognizer.state {
        case .began, .changed:
            self.isScrubbing = true
            self.progress = value
            self.setNeedsDisplay()
            self.scrubbed?(value, false)
        case .ended:
            self.isScrubbing = false
            self.progress = value
            self.setNeedsDisplay()
            self.scrubbed?(value, true)
        case .cancelled, .failed:
            self.isScrubbing = false
        default:
            break
        }
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        let value = min(max(0.0, recognizer.location(in: self).x / max(1.0, self.bounds.width)), 1.0)
        self.progress = value
        self.setNeedsDisplay()
        self.scrubbed?(value, true)
    }
}

private func voiceTranscriptRateImage(rate: String, color: UIColor) -> UIImage? {
    return generateImage(CGSize(width: 30.0, height: 30.0), rotatedContext: { size, context in
        UIGraphicsPushContext(context)

        context.clear(CGRect(origin: CGPoint(), size: size))

        if let image = generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Playspeed30"), color: color) {
            image.draw(at: CGPoint(x: 0.0, y: 0.0))
        }

        let string = NSMutableAttributedString(string: rate, font: Font.with(size: 11.0, design: .round, weight: .semibold), textColor: color)

        var offset = CGPoint(x: 1.0, y: 0.0)
        if rate.count >= 3 {
            if rate == "0.5x" {
                string.addAttribute(.kern, value: -0.8 as NSNumber, range: NSRange(string.string.startIndex ..< string.string.endIndex, in: string.string))
                offset.x += -0.5
            } else {
                string.addAttribute(.kern, value: -0.5 as NSNumber, range: NSRange(string.string.startIndex ..< string.string.endIndex, in: string.string))
                offset.x += -0.3
            }
        } else {
            offset.x += -0.3
        }

        let boundingRect = string.boundingRect(with: size, options: [], context: nil)
        string.draw(at: CGPoint(x: offset.x + floor((size.width - boundingRect.width) / 2.0), y: offset.y + floor((size.height - boundingRect.height) / 2.0)))

        UIGraphicsPopContext()
    })
}

private enum VoiceTranscriptPlayPauseState: Equatable {
    case play
    case pause
}

/// The play / pause icon of the music player's sheet: the same Lottie animation ("anim_playpause"), with the same frames and
/// duration, so the icon morphs between the two the way it does there.
private final class VoiceTranscriptPlayPauseIconNode: ManagedAnimationNode {
    private let duration: Double = 0.35
    private var iconState: VoiceTranscriptPlayPauseState = .pause

    // Not `init(size:lottieSettings:)`: that is the superclass's own initialiser, which this one would override.
    init(canvasSize: CGSize, lottieSettings: LottieRenderingSettings) {
        super.init(size: canvasSize, lottieSettings: lottieSettings)

        self.trackTo(item: ManagedAnimationItem(source: .local("anim_playpause"), frames: .range(startFrame: 41, endFrame: 41), duration: 0.01))
    }

    func enqueueState(_ state: VoiceTranscriptPlayPauseState, animated: Bool) {
        guard self.iconState != state else {
            return
        }

        let previousState = self.iconState
        self.iconState = state

        switch previousState {
        case .pause:
            switch state {
            case .play:
                if animated {
                    self.trackTo(item: ManagedAnimationItem(source: .local("anim_playpause"), frames: .range(startFrame: 41, endFrame: 83), duration: self.duration))
                } else {
                    self.trackTo(item: ManagedAnimationItem(source: .local("anim_playpause"), frames: .range(startFrame: 0, endFrame: 0), duration: 0.01))
                }
            case .pause:
                break
            }
        case .play:
            switch state {
            case .pause:
                if animated {
                    self.trackTo(item: ManagedAnimationItem(source: .local("anim_playpause"), frames: .range(startFrame: 0, endFrame: 41), duration: self.duration))
                } else {
                    self.trackTo(item: ManagedAnimationItem(source: .local("anim_playpause"), frames: .range(startFrame: 41, endFrame: 41), duration: 0.01))
                }
            case .play:
                break
            }
        }
    }
}

private final class VoiceTranscriptControlsView: UIView {

    private let theme: PresentationTheme
    private let waveformView: VoiceTranscriptWaveformView
    private let leftTimeLabel = UILabel()
    private let rightTimeLabel = UILabel()
    private let rateButton = AudioRateButton()
    private let backButton = UIButton(type: .system)
    private let playPauseButton = UIButton(type: .custom)
    private let playPauseIconNode: VoiceTranscriptPlayPauseIconNode
    private let forwardButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private let nextLabel = UILabel()

    /// When the voice message was sent, shown under the controls: "today at 13:40".
    var sentText: String = "" {
        didSet {
            if self.sentText != oldValue {
                self.updateInfoLabel()
            }
        }
    }

    private var duration: Double = 0.0
    private var scrubbingTime: Double?
    private var currentRateText: String?
    private var isPlayingShown = false
    private var didShowFirstPlayState = false
    /// The animation's canvas is much larger than the glyph drawn in it (the music sheet draws it at 76pt in a 64pt button), so
    /// this is sized to make the glyph about 36pt.
    private static let playAnimationSize: CGFloat = 74.0

    // Sizes from the design: 36pt play / pause, 24pt skip icons, 36pt gaps, 36x36 side slots, 32pt to the "Next" line and 25pt below it.
    private static let playIconSize: CGFloat = 36.0
    private static let skipIconSize: CGFloat = 22.0
    private static let iconGap: CGFloat = 40.0
    private static let playGlyphWidth: CGFloat = UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 36.0, weight: .semibold))?.size.width ?? 36.0
    private static let slotSize: CGFloat = 36.0
    /// The ellipsis is an SF Symbol set like text: font size 18.
    private static let moreIconSize: CGFloat = 18.0
    private static let nextTopGap: CGFloat = 32.0
    private static let bottomGap: CGFloat = 25.0
    private static let iconsTop: CGFloat = 12.0 + 28.0 + 12.0 + 16.0 + 16.0

    var seekTo: ((Double) -> Void)?
    var togglePlayPause: (() -> Void)?
    var skip: ((Double) -> Void)?
    var cycleRate: (() -> Void)?
    var openRateMenu: ((ContextReferenceContentNode, ContextGesture?) -> Void)?
    var scrubbingChanged: ((Double?) -> Void)?
    /// Opens the "more" menu; it is given the button to open above.
    var openMoreMenu: ((UIView) -> Void)?


    var waveform: AudioWaveform? {
        didSet {
            self.waveformView.waveform = self.waveform
        }
    }


    init(theme: PresentationTheme, lottieSettings: LottieRenderingSettings) {
        self.theme = theme
        self.waveformView = VoiceTranscriptWaveformView(theme: theme)
        self.playPauseIconNode = VoiceTranscriptPlayPauseIconNode(canvasSize: CGSize(width: VoiceTranscriptControlsView.playAnimationSize, height: VoiceTranscriptControlsView.playAnimationSize), lottieSettings: lottieSettings)
        super.init(frame: CGRect())

        let primary = theme.list.itemPrimaryTextColor
        let gray = voiceTranscriptIconGray(theme)

        for label in [self.leftTimeLabel, self.rightTimeLabel] {
            label.font = Font.regular(12.0)
            label.textColor = theme.list.itemSecondaryTextColor
        }
        self.rightTimeLabel.textAlignment = .right
        self.leftTimeLabel.text = "0:00"
        self.rightTimeLabel.text = "-0:00"

        // The 5 second icons are SF Symbols set like text: font size 22, medium weight.
        let skipConfiguration = UIImage.SymbolConfiguration(pointSize: VoiceTranscriptControlsView.skipIconSize, weight: .regular)
        self.backButton.setImage(UIImage(systemName: "gobackward.5", withConfiguration: skipConfiguration), for: .normal)
        self.backButton.tintColor = voiceTranscriptTextColor(theme, alpha: 1.0)
        // The icon is the animation, not an image. It starts as "play", the state of a voice message that is not playing.
        self.playPauseIconNode.customColor = primary
        self.playPauseIconNode.view.isUserInteractionEnabled = false
        self.playPauseButton.addSubview(self.playPauseIconNode.view)
        self.playPauseIconNode.enqueueState(.play, animated: false)
        self.forwardButton.setImage(UIImage(systemName: "goforward.5", withConfiguration: skipConfiguration), for: .normal)
        self.forwardButton.tintColor = voiceTranscriptTextColor(theme, alpha: 1.0)
        // The ellipsis that opens the menu of the voice message, in the colour the speaker and the next button had.
        self.moreButton.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: VoiceTranscriptControlsView.moreIconSize, weight: .regular)), for: .normal)
        self.moreButton.tintColor = gray
        self.moreButton.addAction(UIAction { [weak self] _ in
            guard let self else {
                return
            }
            self.openMoreMenu?(self.moreButton)
        }, for: .touchUpInside)

        self.nextLabel.textAlignment = .center
        self.nextLabel.font = Font.regular(13.0)

        for view in [self.waveformView, self.leftTimeLabel, self.rightTimeLabel, self.backButton, self.playPauseButton, self.forwardButton, self.moreButton, self.nextLabel] as [UIView] {
            self.addSubview(view)
        }
        self.addSubview(self.rateButton.view)

        self.rateButton.setContent(.image(voiceTranscriptRateImage(rate: "1X", color: gray)))
        self.rateButton.addTarget(self, action: #selector(self.ratePressed), forControlEvents: .touchUpInside)
        self.rateButton.contextAction = { [weak self] _, gesture in
            guard let self else {
                return
            }
            self.openRateMenu?(self.rateButton.referenceNode, gesture)
        }

        self.backButton.addAction(UIAction { [weak self] _ in self?.skip?(-5.0) }, for: .touchUpInside)
        self.forwardButton.addAction(UIAction { [weak self] _ in self?.skip?(5.0) }, for: .touchUpInside)
        self.playPauseButton.addAction(UIAction { [weak self] _ in self?.togglePlayPause?() }, for: .touchUpInside)

        self.waveformView.scrubbed = { [weak self] value, isFinal in
            guard let self, self.duration > 0.0 else {
                return
            }
            let time = Double(value) * self.duration
            if isFinal {
                self.scrubbingTime = nil
                self.scrubbingChanged?(nil)
                self.seekTo?(time)
            } else {
                self.scrubbingTime = time
                self.updateTimeLabels(time: time)
                self.scrubbingChanged?(time)
            }
        }

        self.updateInfoLabel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func ratePressed() {
        self.cycleRate?()
    }

    private func updateInfoLabel() {
        // 3C3C43 at 60% in the light theme.
        self.nextLabel.attributedText = NSAttributedString(string: self.sentText, font: Font.regular(13.0), textColor: voiceTranscriptTextColor(self.theme, alpha: 0.6))
    }

    func preferredHeight(bottomInset: CGFloat) -> CGFloat {
        return VoiceTranscriptControlsView.iconsTop + VoiceTranscriptControlsView.playIconSize + VoiceTranscriptControlsView.nextTopGap + 18.0 + VoiceTranscriptControlsView.bottomGap
    }

    func updateLayout(size: CGSize, bottomInset: CGFloat) {
        let sideInset: CGFloat = 24.0
        self.waveformView.frame = CGRect(origin: CGPoint(x: sideInset, y: 12.0), size: CGSize(width: size.width - sideInset * 2.0, height: 28.0))
        self.leftTimeLabel.frame = CGRect(origin: CGPoint(x: sideInset, y: 52.0), size: CGSize(width: 80.0, height: 16.0))
        self.rightTimeLabel.frame = CGRect(origin: CGPoint(x: size.width - sideInset - 80.0, y: 52.0), size: CGSize(width: 80.0, height: 16.0))

        let playSize = VoiceTranscriptControlsView.playIconSize
        let skipSize = VoiceTranscriptControlsView.skipIconSize
        let gap = VoiceTranscriptControlsView.iconGap
        let slot = VoiceTranscriptControlsView.slotSize
        let centerX = size.width / 2.0
        let centerY = VoiceTranscriptControlsView.iconsTop + playSize / 2.0

        // Touch areas are 44pt; the icons inside are the design sizes.
        let hit: CGFloat = 44.0
        self.playPauseButton.frame = CGRect(x: centerX - hit / 2.0, y: centerY - hit / 2.0, width: hit, height: hit)
        let animationSize = VoiceTranscriptControlsView.playAnimationSize
        self.playPauseIconNode.frame = CGRect(x: floor((hit - animationSize) / 2.0), y: floor((hit - animationSize) / 2.0), width: animationSize, height: animationSize)
        // Gaps are measured between the glyphs themselves, not their point sizes.
        let playWidth = VoiceTranscriptControlsView.playGlyphWidth
        let skipWidth = self.backButton.image(for: .normal)?.size.width ?? skipSize
        let backCenterX = centerX - playWidth / 2.0 - gap - skipWidth / 2.0
        let forwardCenterX = centerX + playWidth / 2.0 + gap + skipWidth / 2.0
        self.backButton.frame = CGRect(x: backCenterX - hit / 2.0, y: centerY - hit / 2.0, width: hit, height: hit)
        self.forwardButton.frame = CGRect(x: forwardCenterX - hit / 2.0, y: centerY - hit / 2.0, width: hit, height: hit)

        let rateCenter = CGPoint(x: sideInset - 4.0 + slot / 2.0, y: centerY)
        self.rateButton.frame = CGRect(x: rateCenter.x - 13.0, y: rateCenter.y - 22.0, width: 26.0, height: 44.0)
        self.moreButton.frame = CGRect(x: size.width - sideInset + 4.0 - slot, y: centerY - slot / 2.0, width: slot, height: slot)

        let nextTop = VoiceTranscriptControlsView.iconsTop + playSize + VoiceTranscriptControlsView.nextTopGap
        self.nextLabel.frame = CGRect(x: sideInset, y: nextTop, width: size.width - sideInset * 2.0, height: 18.0)
    }

    private func updateTimeLabels(time: Double) {
        self.leftTimeLabel.text = formatVoiceTranscriptTime(time)
        self.rightTimeLabel.text = "-" + formatVoiceTranscriptTime(max(0.0, self.duration - time))
    }

    func update(time: Double, duration: Double, isPlaying: Bool, rate: Double) {
        self.duration = duration
        if self.scrubbingTime == nil {
            self.updateTimeLabels(time: time)
            self.waveformView.setProgress(duration > 0.0 ? CGFloat(time / duration) : 0.0)
        }
        if self.isPlayingShown != isPlaying {
            self.isPlayingShown = isPlaying
            // The first state after the sheet opens is set without the animation; every change after it morphs.
            self.playPauseIconNode.enqueueState(isPlaying ? .pause : .play, animated: self.didShowFirstPlayState)
        }
        self.didShowFirstPlayState = true

        let rateText = AudioPlaybackRate(rate).stringValue.uppercased()
        if self.currentRateText != rateText {
            self.currentRateText = rateText
            self.rateButton.setContent(.image(voiceTranscriptRateImage(rate: rateText, color: voiceTranscriptIconGray(self.theme))))
        }
    }
}
