import SwiftUI

/// `@State` is a macro in the macOS 27 SDK, and the macro plugin ships only
/// with Xcode. This wrapper gives the same API using `StateObject`, which
/// works with Command Line Tools while still driving SwiftUI updates.
@propertyWrapper
struct LocalState<Value>: DynamicProperty {
    @StateObject private var storage: Storage

    init(wrappedValue: Value) {
        _storage = StateObject(wrappedValue: Storage(value: wrappedValue))
    }

    init(initialValue: Value) {
        _storage = StateObject(wrappedValue: Storage(value: initialValue))
    }

    var wrappedValue: Value {
        get { storage.value }
        nonmutating set { storage.value = newValue }
    }

    var projectedValue: Binding<Value> {
        Binding(get: { storage.value }, set: { storage.value = $0 })
    }

    final class Storage: ObservableObject {
        @Published var value: Value
        init(value: Value) { self.value = value }
    }
}
