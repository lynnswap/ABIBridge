import SwiftUI
import SwiftUIFixtures

@MainActor public func callText(_ value: Text) -> Text { echoText(value) }
@MainActor public func callImage(_ value: Image) -> Image { echoImage(value) }
@MainActor public func callColor(_ value: Color) -> Color { echoColor(value) }
@MainActor public func callAnyView(_ value: AnyView) -> AnyView { echoAnyView(value) }
@MainActor public func callContainer(_ value: Container<Text>) -> Container<Text> { echoContainer(value) }
@MainActor public func callWrap(_ value: Text) -> Container<Text> { wrap(value) }
@MainActor public func callOpaque(_ model: PanelModel, _ events: RenderEvents, _ increment: @escaping (Int64) -> Int64) -> AnyView {
    AnyView(makeComposedPanel(model, events, increment))
}
