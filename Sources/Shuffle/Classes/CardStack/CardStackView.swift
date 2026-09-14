import UIKit

/// Identity-based stack. All calls and callbacks run on the main actor.
/// Legacy SwipeCardStack remains available with its existing index-based API.
@MainActor
public final class CardStackView<CardID: Hashable>: UIView, SwipeCardDelegate {
  /// Value-only checkpoint. Restoring it never replays accepted actions or animations.
  public struct Snapshot {
    fileprivate let remaining: [CardID]
    fileprivate let history: [(id: CardID, direction: SwipeDirection)]
  }

  /// Captures accepted actions, including the latest deferred data update.
  public var snapshot: Snapshot {
    guard let ids = pendingIDs else { return Snapshot(remaining: remaining, history: history) }
    let surviving = Set(ids)
    let retainedHistory = history.filter { surviving.contains($0.id) }
    let swiped = Set(retainedHistory.map { $0.id })
    return Snapshot(remaining: ids.filter { !swiped.contains($0) }, history: retainedHistory)
  }

  public let configuration: CardStackConfiguration
  public var onActionAccepted: ((CardAction<CardID>) -> Void)?
  public var onTransitionEnded: ((CardTransitionEnd<CardID>) -> Void)?
  public var onStateChanged: ((CardStackState<CardID>) -> Void)?

  public var state: CardStackState<CardID> {
    CardStackState(currentCardID: remaining.first, remainingCardIDs: remaining,
                   canUndo: !history.isEmpty && phase == .idle, phase: phase)
  }

  private let makeCard: (CardID) -> SwipeCard
  private var remaining: [CardID] = []
  private var history: [(id: CardID, direction: SwipeDirection)] = []
  private var cards: [CardID: SwipeCard] = [:]
  private var phase: CardStackPhase = .idle
  private var generation: UInt64 = 0
  private var transition: (generation: UInt64, action: CardAction<CardID>)?
  private var pendingIDs: [CardID]?
  private var pendingReconfiguration: Set<CardID> = []
  private var pendingParts = 0
  private var lastNotifiedState: CardStackState<CardID>?
  private var notificationDepth = 0
  private var detaching = false

  public init(configuration: CardStackConfiguration = .init(),
              restoring snapshot: Snapshot? = nil,
              makeCard: @escaping (CardID) -> SwipeCard) {
    self.configuration = configuration
    self.makeCard = makeCard
    remaining = snapshot?.remaining ?? []
    history = snapshot?.history ?? []
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Use init(configuration:makeCard:)") }

  /// Access the currently rendered card without transferring ownership.
  public func card(for id: CardID) -> SwipeCard? { cards[id] }

  /// IDs describe the entire session, including swiped cards that remain undoable.
  /// During movement, only the latest valid update is retained.
  @discardableResult
  public func updateCards(_ ids: [CardID]) throws -> CardUpdateResult {
    try validate(ids)
    if phase != .idle {
      pendingIDs = ids
      return .deferred
    }
    apply(ids)
    notifyState()
    return .applied
  }

  /// Explicitly replaces a session and invalidates its pending work and undo history.
  public func resetCards(_ ids: [CardID]) throws {
    try validate(ids)
    let previous = transition
    generation &+= 1
    transition = nil
    pendingIDs = nil
    pendingReconfiguration.removeAll()
    stopAnimations()
    cards.values.forEach { $0.removeFromSuperview() }
    cards.removeAll()
    remaining = ids
    history.removeAll()
    phase = .idle
    render()
    notifyState()
    if let previous { notifyEnd(previous.action, outcome: .superseded) }
  }

  /// Rebuilds only requested visible content, preserving IDs, order and history.
  /// Reconfiguration of an offscreen card is naturally picked up when it is created.
  public func reconfigureCards(_ ids: Set<CardID>) {
    pendingReconfiguration.formUnion(ids)
    guard phase == .idle else { return }
    reconfigurePendingCards()
    render()
  }

  @discardableResult
  public func swipe(_ direction: SwipeDirection, animated: Bool = true) -> CardCommandResult<CardID> {
    if let rejection = rejectionForCommand() { return .rejected(rejection) }
    guard let id = remaining.first else { return .rejected(.empty) }
    guard configuration.allowedDirections.contains(direction) else { return .rejected(.disallowedDirection) }
    acceptSwipe(id, direction: direction, animated: animated, forced: true)
    return .accepted(cardID: id)
  }

  @discardableResult
  public func undo(animated: Bool = true) -> CardCommandResult<CardID> {
    if let rejection = rejectionForCommand() { return .rejected(rejection) }
    guard let previous = history.popLast() else { return .rejected(.nothingToUndo) }
    let previousTransforms = cards.mapValues { $0.transform }
    remaining.insert(previous.id, at: 0)
    let token = begin(.undo(cardID: previous.id))
    guard transition?.generation == token else { return .accepted(cardID: previous.id) }
    render()
    for (id, transform) in previousTransforms { cards[id]?.transform = transform }
    animate(token: token, animated: animated, cardID: previous.id, direction: previous.direction, undo: true)
    return .accepted(cardID: previous.id)
  }

  private func rejectionForCommand() -> CardCommandRejection? {
    if phase != .idle || notificationDepth > 0 { return .busy }
    if window == nil || detaching { return .notVisible }
    return nil
  }

  private func validate(_ ids: [CardID]) throws {
    guard Set(ids).count == ids.count else { throw CardStackError.duplicateIDs }
  }

  private func apply(_ ids: [CardID]) {
    let surviving = Set(ids)
    history.removeAll { !surviving.contains($0.id) }
    let swiped = Set(history.map { $0.id })
    remaining = ids.filter { !swiped.contains($0) }
    render()
  }

  private func render() {
    let visible = Array(remaining.prefix(configuration.visibleCardCount))
    var retained = Set(visible)
    if case .swipe(let id, _)? = transition?.action { retained.insert(id) }
    for id in Array(cards.keys) where !retained.contains(id) {
      cards.removeValue(forKey: id)?.removeFromSuperview()
    }
    for id in visible.reversed() {
      if cards[id] == nil {
        let card = makeCard(id)
        card.automaticallyAnimatesGestures = false
        card.delegate = self
        card.swipeDirections = SwipeDirection.allDirections.filter { configuration.allowedDirections.contains($0) }
        cards[id] = card
        addSubview(card)
      }
      if let card = cards[id] { bringSubviewToFront(card) }
    }
    if case .swipe(let id, _)? = transition?.action, let card = cards[id] { bringSubviewToFront(card) }
    layoutCards()
  }

  override public func layoutSubviews() {
    super.layoutSubviews()
    // Do not overwrite a drag or an animation when a parent lays out again.
    guard phase == .idle else { return }
    layoutCards()
  }

  private func layoutCards() {
    for (position, id) in remaining.prefix(configuration.visibleCardCount).enumerated() {
      guard let card = cards[id] else { continue }
      card.transform = .identity
      card.frame = bounds
      card.transform = cardTransform(at: position)
      card.isUserInteractionEnabled = position == 0 && phase == .idle
    }
  }

  private func cardTransform(at position: Int) -> CGAffineTransform {
    let scale = max(0.01, 1 - CGFloat(position) * configuration.scaleStep)
    return CGAffineTransform(scaleX: scale, y: scale)
      .translatedBy(x: 0, y: CGFloat(position) * configuration.verticalSpacing)
  }

  private func begin(_ action: CardAction<CardID>) -> UInt64 {
    generation &+= 1
    let token = generation
    transition = (token, action)
    phase = .animating
    cards.values.forEach { $0.isUserInteractionEnabled = false }
    notificationDepth += 1
    onActionAccepted?(action)
    if transition?.generation == token { notifyState() }
    notificationDepth -= 1
    return token
  }

  private func acceptSwipe(_ id: CardID, direction: SwipeDirection, animated: Bool, forced: Bool) {
    remaining.removeFirst()
    history.append((id, direction))
    let token = begin(.swipe(cardID: id, direction: direction))
    guard transition?.generation == token else { return }
    let previousTransforms = cards.mapValues { $0.transform }
    render()
    for (id, transform) in previousTransforms { cards[id]?.transform = transform }
    animate(token: token, animated: animated, cardID: id, direction: direction, undo: false, forced: forced)
  }

  private func animate(token: UInt64, animated: Bool, cardID: CardID,
                       direction: SwipeDirection, undo: Bool, forced: Bool = true) {
    guard let card = cards[cardID] else { finish(token, outcome: .completed); return }
    guard animated else { finish(token, outcome: .completed); return }
    // AIDEV-NOTE: Both visual tracks must complete before the stack accepts another command.
    // Generation checks make delayed callbacks harmless after reset or window detachment.
    pendingParts = 2
    let completed: (Bool) -> Void = { [weak self] finished in
      guard let self = self, self.transition?.generation == token else { return }
      if !finished { self.finish(token, outcome: .superseded); return }
      self.pendingParts -= 1
      if self.pendingParts == 0 { self.finish(token, outcome: .completed) }
    }
    if undo {
      CardAnimator.shared.animateReverseSwipe(on: card, from: direction, completion: completed)
    } else {
      CardAnimator.shared.animateSwipe(on: card, direction: direction, forced: forced, completion: completed)
    }
    let duration = undo ? card.animationOptions.totalReverseSwipeDuration / 2
      : card.animationOptions.totalSwipeDuration / 2
    UIView.animate(withDuration: duration, animations: {
      for (position, id) in self.remaining.prefix(self.configuration.visibleCardCount).enumerated() {
        if id != cardID { self.cards[id]?.transform = self.cardTransform(at: position) }
      }
    }, completion: completed)
  }

  private func finish(_ token: UInt64, outcome: CardTransitionOutcome) {
    guard let finished = transition, finished.generation == token else { return }
    transition = nil
    generation &+= 1
    stopAnimations()
    phase = .idle
    if let ids = pendingIDs { pendingIDs = nil; apply(ids) }
    reconfigurePendingCards()
    render()
    notifyEnd(finished.action, outcome: outcome)
    notifyState()
  }

  private func reconfigurePendingCards() {
    for id in pendingReconfiguration { cards.removeValue(forKey: id)?.removeFromSuperview() }
    pendingReconfiguration.removeAll()
  }

  private func stopAnimations() { cards.values.forEach { $0.removeAllAnimations() } }

  private func notifyState() {
    let snapshot = state
    guard snapshot != lastNotifiedState else { return }
    lastNotifiedState = snapshot
    notificationDepth += 1
    onStateChanged?(snapshot)
    notificationDepth -= 1
  }

  private func notifyEnd(_ action: CardAction<CardID>, outcome: CardTransitionOutcome) {
    notificationDepth += 1
    onTransitionEnded?(CardTransitionEnd(action: action, outcome: outcome))
    notificationDepth -= 1
  }

  override public func willMove(toWindow newWindow: UIWindow?) {
    super.willMove(toWindow: newWindow)
    guard window != nil, newWindow == nil else { return }
    detaching = true
    defer { detaching = false }
    if let transition = transition { finish(transition.generation, outcome: .settledOffscreen) }
    else if phase != .idle {
      generation &+= 1
      phase = .idle
      stopAnimations()
      if let ids = pendingIDs { pendingIDs = nil; apply(ids) }
      reconfigurePendingCards()
      render()
      notifyState()
    }
  }

  func cardDidTap(_ card: SwipeCard) {}
  func cardDidContinueSwipe(_ card: SwipeCard) {}
  func cardDidFinishSwipeAnimation(_ card: SwipeCard) {}
  func cardDidBeginSwipe(_ card: SwipeCard) {
    guard phase == .idle, let id = remaining.first, cards[id] === card else { return }
    phase = .dragging
    notifyState()
  }
  func cardDidSwipe(_ card: SwipeCard, withDirection direction: SwipeDirection) {
    guard phase == .dragging, let id = remaining.first, cards[id] === card else { return }
    acceptSwipe(id, direction: direction, animated: true, forced: false)
  }
  func cardDidCancelSwipe(_ card: SwipeCard) {
    guard phase == .dragging, let id = remaining.first, cards[id] === card else { return }
    // No accepted action and no history change for a cancelled gesture. Keep the
    // reset spring, but wait for it before applying data updates or accepting commands.
    generation &+= 1
    let token = generation
    phase = .animating
    card.isUserInteractionEnabled = false
    notifyState()
    guard generation == token, phase == .animating else { return }
    UIView.animate(withDuration: card.animationOptions.totalResetDuration,
                   delay: 0, usingSpringWithDamping: card.animationOptions.resetSpringDamping,
                   initialSpringVelocity: 0, options: [.curveLinear, .allowUserInteraction], animations: {
      card.transform = self.cardTransform(at: 0)
      card.swipeDirections.forEach { card.overlay(forDirection: $0)?.alpha = 0 }
    }, completion: { [weak self] _ in
      guard let self = self, self.generation == token, self.phase == .animating else { return }
      self.generation &+= 1
      self.phase = .idle
      if let ids = self.pendingIDs { self.pendingIDs = nil; self.apply(ids) }
      self.reconfigurePendingCards()
      self.render()
      self.notifyState()
    })
  }
}
