import SwiftUI

/// Recoverable presentation/input errors. Invalid input leaves the previous stack intact.
@available(iOS 13.0, *)
public enum CardStackPresentationError: Error, Equatable {
  case duplicateIDs
  case controllerAlreadyConnected
}

/// SwiftUI content rendered by Shuffle's existing UIKit animation engine.
/// Items include the full visual session, including IDs that remain undoable.
@available(iOS 13.0, *)
@MainActor
public struct CardStack<Item: Identifiable, Content: View>: View {
  private let items: [Item]
  private let controller: CardStackController<Item.ID>
  private let configuration: CardStackConfiguration
  private let onActionAccepted: (CardAction<Item.ID>) -> Void
  private let onTransitionEnded: (CardTransitionEnd<Item.ID>) -> Void
  private let onError: (CardStackPresentationError) -> Void
  private let content: (Item) -> Content

  public init(items: [Item], controller: CardStackController<Item.ID>,
              configuration: CardStackConfiguration = .init(),
              onActionAccepted: @escaping (CardAction<Item.ID>) -> Void,
              onTransitionEnded: @escaping (CardTransitionEnd<Item.ID>) -> Void,
              onError: @escaping (CardStackPresentationError) -> Void,
              @ViewBuilder content: @escaping (Item) -> Content) {
    self.items = items
    self.controller = controller
    self.configuration = configuration
    self.onActionAccepted = onActionAccepted
    self.onTransitionEnded = onTransitionEnded
    self.onError = onError
    self.content = content
  }

  public var body: some View {
    CardStackRepresentable(items: items, controller: controller, configuration: configuration,
                           onActionAccepted: onActionAccepted, onTransitionEnded: onTransitionEnded,
                           onError: onError, content: content)
  }
}

@available(iOS 13.0, *)
private struct CardStackRepresentable<Item: Identifiable, Content: View>: UIViewControllerRepresentable {
  let items: [Item]
  let controller: CardStackController<Item.ID>
  let configuration: CardStackConfiguration
  let onActionAccepted: (CardAction<Item.ID>) -> Void
  let onTransitionEnded: (CardTransitionEnd<Item.ID>) -> Void
  let onError: (CardStackPresentationError) -> Void
  let content: (Item) -> Content

  func makeUIViewController(context: Context) -> CardStackHostingController<Item, Content> {
    CardStackHostingController()
  }

  func updateUIViewController(_ host: CardStackHostingController<Item, Content>, context: Context) {
    host.update(items: items, controller: controller, configuration: configuration,
                environment: context.environment, content: content,
                onActionAccepted: onActionAccepted, onTransitionEnded: onTransitionEnded, onError: onError)
  }

  static func dismantleUIViewController(_ host: CardStackHostingController<Item, Content>, coordinator: ()) {
    host.disconnect()
  }
}
