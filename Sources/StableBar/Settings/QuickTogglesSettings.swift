import SwiftUI

/// The tiles a Quick toggles widget shows, in the panel's cards and order, then the tiles it doesn't: a button adds or
/// removes a tile, and dragging a shown tile moves it within its card.
struct QuickTogglesSettings: View {
    let editor: ConfigurationEditor
    let widget: WidgetConfiguration
    let tiles: [QuickTile]
    /// The row a tile is dragged over.
    @State private var target: QuickTile?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            heading("Shown", hint: "In the panel’s order. Drag a tile to move it within its card.")
            ForEach(cards, id: \.self) { card in
                Text(card.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary).padding(.top, 4)
                ForEach(tiles.filter { $0.group == card }, id: \.self) { shownRow($0) }
            }
        }
        .groupRow()
        VStack(alignment: .leading, spacing: 6) {
            heading("Not shown", hint: "A tile you add goes last in its card.")
            ForEach(QuickTile.allCases.filter { !tiles.contains($0) }, id: \.self) { tile in
                row(tile, symbol: "plus.circle.fill", color: .green, action: "Add") { add(tile) }
            }
        }
        .groupRow()
    }

    /// The cards the panel shows, in its order.
    private var cards: [QuickTile.Group] {
        var cards: [QuickTile.Group] = []
        for tile in tiles where !cards.contains(tile.group) { cards.append(tile.group) }
        return cards
    }

    private func heading(_ title: String, hint: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium))
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func shownRow(_ tile: QuickTile) -> some View {
        row(tile, symbol: "minus.circle.fill", color: .red, action: "Remove") { write(tiles.filter { $0 != tile }) }
            .accessibilityAction(named: Text("Move up")) { move(tile, by: -1) }
            .accessibilityAction(named: Text("Move down")) { move(tile, by: 1) }
            .overlay(alignment: .top) {
                if target == tile { Capsule().fill(Color.accentColor).frame(height: 2).offset(y: -4) }
            }
            .contentShape(Rectangle())
            .draggable(tile.rawValue) { Label(tile.title, systemImage: tile.symbol) }
            .dropDestination(for: String.self) { names, _ in
                guard let moved = names.first.flatMap(QuickTile.init(rawValue:)), moved != tile, moved.group == tile.group,
                      tiles.contains(moved) else { return false }
                var next = tiles.filter { $0 != moved }
                next.insert(moved, at: next.firstIndex(of: tile)!)
                write(next)
                return true
            } isTargeted: { targeted in
                if targeted { target = tile } else if target == tile { target = nil }
            }
    }

    private func row(_ tile: QuickTile, symbol: String, color: Color, action: String, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button(action: perform) {
                Image(systemName: symbol).symbolRenderingMode(.palette).foregroundStyle(.white, color)
            }
            .buttonStyle(.plain)
            Image(systemName: tile.symbol).frame(width: 16)
            Text(tile.title)
            if tile.help != tile.title { Text(tile.help).font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }
        // One element for VoiceOver that acts as the button, with a shown tile's moves as its other actions.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(action) \(tile.title)")
        .accessibilityHint(tile.help == tile.title ? "" : tile.help)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, perform)
    }

    /// Adds a tile last in its card.
    private func add(_ tile: QuickTile) {
        var next = tiles
        next.insert(tile, at: tiles.lastIndex { $0.group == tile.group }.map { $0 + 1 } ?? tiles.count)
        write(next)
    }

    /// Swaps a tile with the one before or after it in its card, as a drag can.
    private func move(_ tile: QuickTile, by offset: Int) {
        let card = tiles.indices.filter { tiles[$0].group == tile.group }
        let at = card.firstIndex { tiles[$0] == tile }!
        guard card.indices.contains(at + offset) else { return }
        var next = tiles
        next.swapAt(card[at], card[at + offset])
        write(next)
    }

    private func write(_ tiles: [QuickTile]) {
        editor.set(["tiles": .array(tiles.map { .string($0.rawValue) })], for: widget.id)
    }
}
