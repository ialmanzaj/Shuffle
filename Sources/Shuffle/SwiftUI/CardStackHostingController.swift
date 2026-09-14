import SwiftUI
import UIKit

@available(iOS 13.0, *)
@MainActor
internal final class CardStackHostingController<Item: Identifiable, Content: View>: UIViewController {
  private(set) var stack: CardStackView<Item.ID>?
  private var controller: CardStackController<Item.ID>?
  private var itemsByID: [Item.ID: Item] = [:]
  private var configuration = CardStackConfiguration()
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
    let ids = items.map(\.id)
    guard Set(ids).count == ids.count else {
      DispatchQueue.main.async { onError(.duplicateIDs) }
      return
    }
    guard self.controller === controller || !controller.isConnected else {
      DispatchQueue.main.async { onError(.controllerAlreadyConnected) }
      return
    }
    if self.controller !== controller { disconnect() }
    self.controller = controller
    itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    self.configuration = configuration
    self.environment = environment
    self.content = content
    self.onActionAccepted = onActionAccepted
    self.onTransitionEnded = onTransitionEnded
    controller.updateItemIDs(ids)
    needsContentUpdate = true
    if stack == nil { installStack() }
    // Updates during movement are deferred by the engine; do not interrupt hosting content.
    do { try stack?.updateCards(ids) }
    catch { preconditionFailure("Validated card IDs became invalid") }
    stack?.updateConfiguration(configuration)
    applyContentIfIdle()
  }

  private func installStack() {
    guard let controller = controller else { return }
    loadViewIfNeeded()
    let stack = CardStackView<Item.ID>(configuration: configuration, restoring: controller.checkpoint) { [weak self] id in
      guard let self = self else { return SwipeCard() }
      return self.makeCard(for: id)
    }
    guard controller.connect(stack) else { preconditionFailure("Connection must be checked before installation") }
    self.stack = stack
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

  private func makeCard(for id: Item.ID) -> SwipeCard {
    guard let item = itemsByID[id], let content = content else {
      preconditionFailure("Engine requested an ID outside the visual working set")
    }
    let card = SwipeCard()
    let host = UIHostingController(rootView: HostedContent(content: content(item), environment: environment))
    host.view.backgroundColor = .clear
    addChild(host)
    card.content = host.view
    hostedCards[ObjectIdentifier(card)] = HostedCard(id: id, card: card, host: host)
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
