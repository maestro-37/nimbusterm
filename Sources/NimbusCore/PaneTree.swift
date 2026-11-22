import Foundation

public indirect enum PaneTree: Codable, Equatable, Sendable {
    case leaf(UUID)
    case split(axis: SplitAxis, first: PaneTree, second: PaneTree)
}

public enum PaneTreeOps {
    public static func leaves(_ tree: PaneTree) -> [UUID] {
        switch tree {
        case .leaf(let id): return [id]
        case .split(_, let first, let second): return leaves(first) + leaves(second)
        }
    }

    public static func split(_ tree: PaneTree, at leaf: UUID, axis: SplitAxis, newLeaf: UUID) -> PaneTree {
        switch tree {
        case .leaf(let id):
            guard id == leaf else { return tree }
            return .split(axis: axis, first: .leaf(id), second: .leaf(newLeaf))
        case .split(let currentAxis, let first, let second):
            return .split(
                axis: currentAxis,
                first: split(first, at: leaf, axis: axis, newLeaf: newLeaf),
                second: split(second, at: leaf, axis: axis, newLeaf: newLeaf)
            )
        }
    }

    public static func removing(_ tree: PaneTree, leaf: UUID) -> PaneTree? {
        switch tree {
        case .leaf(let id):
            return id == leaf ? nil : tree
        case .split(let axis, let first, let second):
            let newFirst = removing(first, leaf: leaf)
            let newSecond = removing(second, leaf: leaf)
            switch (newFirst, newSecond) {
            case (nil, nil): return nil
            case (let f?, nil): return f
            case (nil, let s?): return s
            case (let f?, let s?): return .split(axis: axis, first: f, second: s)
            }
        }
    }

    public static func fromSaved(_ pane: SavedPane) -> PaneTree {
        switch pane {
        case .leaf(let sessionID):
            return .leaf(sessionID ?? UUID())
        case .split(let axis, let first, let second):
            return .split(axis: axis, first: fromSaved(first), second: fromSaved(second))
        }
    }
}
