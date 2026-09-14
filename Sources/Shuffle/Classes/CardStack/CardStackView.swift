import UIKit

/// Identity-based stack. All calls and callbacks run on the main actor.
/// Legacy SwipeCardStack remains available with its existing index-based API.
@MainActor
public final class CardStackView<CardID: Hashable>: UIView, SwipeCardDelegate {
  /// Value-only checkpoint. Restoring it never replays accepted actions or animations.
  public struct Snapshot {
    fileprivate let sessionIDs: [CardID]
    fileprivate let history: [(id: CardID, direction: SwipeDirection)]

    static var empty: Snapshot { Snapshot(sessionIDs: [], history: []) }

    var state: CardStackState<CardID> {
      let swiped = Set(history.map(\.id))
      let remaining = sessionIDs.filter { !swiped.contains($0) }
      return CardStackState(currentCardID: remaining.first, remainingCardIDs: remaining,
                            canUndo: !history.isEmpty, phase: .idle)
    }

    func resettingHistory() -> Snapshot { Snapshot(sessionIDs: sessionIDs, history: []) }
  }

  // AIDEV-NOTE: Each entry carries its own content factory. Deferred input cannot
  // accidentally read a newer presentation's item dictionary.
  struct Entry {
    let id: CardID
    let makeCard: () -> SwipeCard
  }

  struct Input {
    let entries: [Entry]

    init(_ entries: [Entry]) throws {
      var seen: Set<CardID> = []
      for entry in entries {
        guard seen.insert(entry.id).inserted else { throw CardStackError.duplicateIDs }
      }
      self.entries = entries
    }
  }

  /// Captures accepted actions, including the latest deferred data update.
  public var snapshot: Snapshot {
    let entries = pendingInput?.entries ?? session
    let surviving = Set(entries.map(\.id))
    let retainedHistory = history.filter { surviving.contains($0.entry.id) }
    return Snapshot(sessionIDs: entries.map(\.id),
                    history: retainedHistory.map { ($0.entry.id, $0.direction) })
  }

  public private(set) var configuration: CardStackConfiguration
  public var onActionAccepted: ((CardAction<CardID>) -> Void)?
  public var onTransitionEnded: ((CardTransitionEnd<CardID>) -> Void)?
  public var onStateChanged: ((CardStackState<CardID>) -> Void)?

  public var state: CardStackState<CardID> {
    CardStackState(currentCardID: remaining.first?.id, remainingCardIDs: remaining.map(\.id),
                   canUndo: !history.isEmpty && phase == .idle, phase: phase)
  }

  private let makeCard: ((CardID) -> SwipeCard)?
  private var session: [Entry] = []
  private var remaining: [Entry] = []
  private var history: [(entry: Entry, direction: SwipeDirection)] = []
  private var cards: [CardID: SwipeCard] = [:]
  private var phase: CardStackPhase = .idle
  private var generation: UInt64 = 0
  private var transition: (generation: UInt64, action: CardAction<CardID>)?
  private var pendingConfiguration: CardStackConfiguration?
  private var pendingInput: Input?
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
    let entries = (snapshot?.sessionIDs ?? []).map { id in Entry(id: id, makeCard: { makeCard(id) }) }
    super.init(frame: .zero)
    restore(entries, from: snapshot)
  }

  init(configuration: CardStackConfiguration, restoring snapshot: Snapshot?, input: Input) {
    self.configuration = configuration
    makeCard = nil
    super.init(frame: .zero)
    restore(input.entries, from: snapshot)
  }

  private func restore(_ entries: [Entry], from snapshot: Snapshot?) {
    session = entries
    var entriesByID: [CardID: Entry] = [:]
    for entry in entries { entriesByID[entry.id] = entry }
    history = (snapshot?.history ?? []).compactMap { previous in
      entriesByID[previous.id].map { ($0, previous.direction) }
    }
    let swiped = Set(history.map { $0.entry.id })
    remaining = entries.filter { !swiped.contains($0.id) }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { return nil }

  /// Access the currently rendered card without transferring ownership.
  public func card(for id: CardID) -> SwipeCard? { cards[id] }

  /// IDs describe the entire session, including swiped cards that remain undoable.
  /// During movement, only the latest valid update is retained.
  @discardableResult
  public func updateCards(_ ids: [CardID]) throws -> CardUpdateResult {
    guard let makeCard else { throw CardStackError.contentProviderRequired }
    return update(try Input(ids.map { id in Entry(id: id, makeCard: { makeCard(id) }) }))
  }

  @discardableResult
  func update(_ input: Input) -> CardUpdateResult {
    if phase != .idle {
      pendingInput = input
      return .deferred
    }
    reconcileSession(with: input.entries)
    render()
    notifyState()
    return .applied
  }

  /// A SwiftUI update applies its data and layout together, with no intermediate presentation.
  @discardableResult
  func update(_ input: Input, configuration: CardStackConfiguration) -> CardUpdateResult {
    pendingConfiguration = configuration
    return update(input)
  }

  /// Applies layout and gesture policy without replacing retained cards or history.
  /// During movement the latest configuration takes effect when the stack settles.
  @discardableResult
  public func updateConfiguration(_ configuration: CardStackConfiguration) -> CardUpdateResult {
    pendingConfiguration = configuration
    guard phase == .idle else { return .deferred }
    render()
    return .applied
  }

  /// Explicitly replaces a session and invalidates its pending work and undo history.
  public func resetCards(_ ids: [CardID]) throws {
    guard let makeCard else { throw CardStackError.contentProviderRequired }
    let input = try Input(ids.map { id in Entry(id: id, makeCard: { makeCard(id) }) })
    session = input.entries
    pendingInput = nil
    reset()
  }

  /// Restarts the latest valid session, including updates received during movement.
  public func reset() {
    if let pendingInput { session = pendingInput.entries }
    let previous = transition
    generation &+= 1
    transition = nil
    pendingInput = nil
    pendingReconfiguration.removeAll()
    stopAnimations()
    cards.values.forEach { $0.removeFromSuperview() }
    cards.removeAll()
    remaining = session
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
    guard let entry = remaining.first else { return .rejected(.empty) }
    guard configuration.allowedDirections.contains(direction) else { return .rejected(.disallowedDirection) }
    acceptSwipe(entry.id, direction: direction, animated: animated, forced: true)
    return .accepted(cardID: entry.id)
  }

  @discardableResult
  public func undo(animated: Bool = true) -> CardCommandResult<CardID> {
    if let rejection = rejectionForCommand() { return .rejected(rejection) }
    guard let previous = history.popLast() else { return .rejected(.nothingToUndo) }
    let previousTransforms = cards.mapValues { $0.transform }
    remaining.insert(previous.entry, at: 0)
    let token = begin(.undo(cardID: previous.entry.id))
    guard transition?.generation == token else { return .accepted(cardID: previous.entry.id) }
    render()
    for (id, transform) in previousTransforms { cards[id]?.transform = transform }
    animate(token: token, animated: animated, cardID: previous.entry.id, direction: previous.direction, undo: true)
    return .accepted(cardID: previous.entry.id)
  }

  private func rejectionForCommand() -> CardCommandRejection? {
    if phase != .idle || notificationDepth > 0 { return .busy }
    if window == nil || detaching { return .notVisible }
    return nil
  }

  private func reconcileSession(with entries: [Entry]) {
    session = entries
    var entriesByID: [CardID: Entry] = [:]
    for entry in entries { entriesByID[entry.id] = entry }
    history = history.compactMap { previous in
      entriesByID[previous.entry.id].map { ($0, previous.direction) }
    }
    let swiped = Set(history.map { $0.entry.id })
    remaining = entries.filter { !swiped.contains($0.id) }
  }

  private func render() {
    // AIDEV-NOTE: All settlement paths render at rest, including reset and cancelled
    // gestures. Apply the latest policy here without destroying retained card state.
    if phase == .idle, let configuration = pendingConfiguration {
      self.configuration = configuration
      pendingConfiguration = nil
    }
    let visible = Array(remaining.prefix(configuration.visibleCardCount))
    var retained = Set(visible.map(\.id))
    if case .swipe(let id, _)? = transition?.action { retained.insert(id) }
    for id in Array(cards.keys) where !retained.contains(id) {
      cards.removeValue(forKey: id)?.removeFromSuperview()
    }
    for entry in visible.reversed() {
      let id = entry.id
      if cards[id] == nil {
        let card = entry.makeCard()
        card.automaticallyAnimatesGestures = false
        card.delegate = self
        cards[id] = card
        addSubview(card)
      }
      if let card = cards[id] {
        card.swipeDirections = SwipeDirection.allDirections.filter { configuration.allowedDirections.contains($0) }
        bringSubviewToFront(card)
      }
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
    for (position, entry) in remaining.prefix(configuration.visibleCardCount).enumerated() {
      let id = entry.id
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
    let entry = remaining.removeFirst()
    history.append((entry, direction))
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
      for (position, entry) in self.remaining.prefix(self.configuration.visibleCardCount).enumerated() {
        let id = entry.id
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
    applyPendingChanges()
    notifyEnd(finished.action, outcome: outcome)
    notifyState()
  }

  private func applyPendingChanges() {
    // AIDEV-NOTE: Reconcile all pending data before creating views. Rendering inside
    // reconciliation would create cards that pending reconfiguration immediately discards.
    if let input = pendingInput {
      pendingInput = nil
      reconcileSession(with: input.entries)
    }
    reconfigurePendingCards()
    render()
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
      applyPendingChanges()
      notifyState()
    }
  }

  func cardDidTap(_ card: SwipeCard) {}
  func cardDidContinueSwipe(_ card: SwipeCard) {}
  func cardDidFinishSwipeAnimation(_ card: SwipeCard) {}
  func cardDidBeginSwipe(_ card: SwipeCard) {
    guard phase == .idle, let entry = remaining.first, cards[entry.id] === card else { return }
    phase = .dragging
    notifyState()
  }
  func cardDidSwipe(_ card: SwipeCard, withDirection direction: SwipeDirection) {
    guard phase == .dragging, let entry = remaining.first, cards[entry.id] === card else { return }
    acceptSwipe(entry.id, direction: direction, animated: true, forced: false)
  }
  func cardDidCancelSwipe(_ card: SwipeCard) {
    guard phase == .dragging, let entry = remaining.first, cards[entry.id] === card else { return }
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
      self.applyPendingChanges()
      self.notifyState()
    })
  }
}
