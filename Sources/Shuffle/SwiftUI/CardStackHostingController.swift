import SwiftUI
import UIKit

@available(iOS 13.0, *)
@MainActor
internal final class CardStackHostingController<Item: Identifiable, Content: View>: UIViewController {
  private(set) var stack: CardStackView<Item.ID>?
  private var controller: CardStackController<Item.ID>?
  private var itemsByID: [Item.ID: Item] = [:]
  private var environment = EnvironmentValues()
  private var content: ((Item) -> Content)?
  private var onActionAccepted: ((CardAction<Item.ID>) -> Void)?
  private var onTransitionEnded: ((CardTransitionEnd<Item.ID>) -> Void)?
  private var isApplying = false
  private var needsContentUpdate = false

  private struct HostedCard {
    let id: Item.ID
    weak var card: SwipeCard?
    let host: UIHostingController<HostedContent<Content>>
    var containmentCompleted = false
  }
  private var hostedCards: [ObjectIdentifier: HostedCard] = [:]

  override func loadView() {
    view = UIView()
    view.backgroundColor = .clear
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    stack?.frame = view.bounds
  }

  func update(items: [Item], controller: CardStackController<Item.ID>,
              configuration: CardStackConfiguration, environment: EnvironmentValues,
              content: @escaping (Item) -> Content,
              onActionAccepted: @escaping (CardAction<Item.ID>) -> Void,
              onTransitionEnded: @escaping (CardTransitionEnd<Item.ID>) -> Void,
              onError: @escaping (CardStackPresentationError) -> Void) {
    let input: CardStackView<Item.ID>.Input
    do {
      input = try CardStackView<Item.ID>.Input(items.map { item in
        CardStackView<Item.ID>.Entry(id: item.id) { [weak self] in
          Self.makeCard(item: item, content: content, environment: environment, parent: self)
        }
      })
    } catch {
      DispatchQueue.main.async { onError(.duplicateIDs) }
      return
    }

    // Connect the candidate before dismantling a valid presentation.
    if self.controller !== controller || stack == nil {
      let candidate = CardStackView<Item.ID>(configuration: configuration,
                                             restoring: controller.checkpoint, input: input)
      guard controller.connect(candidate) else {
        DispatchQueue.main.async { onError(.controllerAlreadyConnected) }
        return
      }
      disconnect()
      self.controller = controller
      stack = candidate
      installStack(candidate)
    }
    var nextItemsByID: [Item.ID: Item] = [:]
    for item in items { nextItemsByID[item.id] = item }
    itemsByID = nextItemsByID
    self.environment = environment
    self.content = content
    self.onActionAccepted = onActionAccepted
    self.onTransitionEnded = onTransitionEnded
    controller.updateItemIDs(input.ids)
    needsContentUpdate = true
    // Updates during movement are deferred by the engine; do not interrupt hosting content.
    stack?.update(input)
    stack?.updateConfiguration(configuration)
    applyContentIfIdle()
  }

  private func installStack(_ stack: CardStackView<Item.ID>) {
    loadViewIfNeeded()
    view.addSubview(stack)
    stack.frame = view.bounds
    stack.onActionAccepted = { [weak self] action in
      guard let callback = self?.onActionAccepted else { return }
      // Capture the originating presentation's callback, not a later replacement's callback.
      DispatchQueue.main.async { callback(action) }
    }
    stack.onTransitionEnded = { [weak self] end in
      guard let self = self else { return }
      self.reconcileHostedCards()
      if let callback = self.onTransitionEnded { DispatchQueue.main.async { callback(end) } }
    }
    stack.onStateChanged = { [weak self] _ in
      guard let self = self else { return }
      self.controller?.notifyChange()
      self.reconcileHostedCards()
      self.applyContentIfIdle()
    }
  }

  private static func makeCard(item: Item, content: (Item) -> Content,
                               environment: EnvironmentValues,
                               parent: CardStackHostingController?) -> SwipeCard {
    let host = UIHostingController(rootView: HostedContent(content: content(item), environment: environment))
    host.view.backgroundColor = .clear
    let card = HostedSwipeCard(host: host)
    parent?.addChild(host)
    card.content = host.view
    parent?.hostedCards[ObjectIdentifier(card)] = HostedCard(id: item.id, card: card, host: host)
    return card
  }

  private func applyContentIfIdle() {
    guard !isApplying, let stack = stack, stack.state.phase == .idle else { return }
    isApplying = true
    defer { isApplying = false }
    reconcileHostedCards()
    guard needsContentUpdate, let content = content else { return }
    needsContentUpdate = false
    // Reuse hosts instead of replacing SwipeCards. EnvironmentValues cannot be compared
    // wholesale, so refresh root values on a SwiftUI update, after movement settles.
    for hosted in hostedCards.values {
      guard let item = itemsByID[hosted.id] else { continue }
      hosted.host.rootView = HostedContent(content: content(item), environment: environment)
    }
  }

  private func reconcileHostedCards() {
    for (key, var hosted) in hostedCards {
      if hosted.card?.superview !== stack {
        hosted.host.willMove(toParent: nil)
        hosted.host.view.removeFromSuperview()
        hosted.host.removeFromParent()
        hostedCards.removeValue(forKey: key)
      } else if !hosted.containmentCompleted {
        hosted.host.didMove(toParent: self)
        hosted.containmentCompleted = true
        hostedCards[key] = hosted
      }
    }
  }

  private func removeStack() {
    guard let stack = stack else { return }
    // Removing from the window settles an accepted transition before snapshot capture.
    stack.removeFromSuperview()
    controller?.disconnect(stack)
    stack.onActionAccepted = nil
    stack.onTransitionEnded = nil
    stack.onStateChanged = nil
    self.stack = nil
    for hosted in hostedCards.values {
      hosted.host.willMove(toParent: nil)
      hosted.host.view.removeFromSuperview()
      hosted.host.removeFromParent()
    }
    hostedCards.removeAll()
  }

  func disconnect() {
    // Prevent settlement callbacks from applying a pending layout while tearing down.
    isApplying = true
    removeStack()
    controller = nil
    content = nil
    onActionAccepted = nil
    onTransitionEnded = nil
    isApplying = false
  }

}

@available(iOS 13.0, *)
private struct HostedContent<Content: View>: View {
  let content: Content
  let environment: EnvironmentValues

  var body: some View { content.environment(\.self, environment) }
}

// Retain content while attached even if the parent presentation has gone away.
@available(iOS 13.0, *)
private final class HostedSwipeCard<Content: View>: SwipeCard {
  private var retainedHost: UIHostingController<Content>?

  init(host: UIHostingController<Content>) {
    retainedHost = host
    super.init(frame: .zero)
  }

  override func willMove(toSuperview newSuperview: UIView?) {
    super.willMove(toSuperview: newSuperview)
    if newSuperview == nil { retainedHost = nil }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { return nil }
}
