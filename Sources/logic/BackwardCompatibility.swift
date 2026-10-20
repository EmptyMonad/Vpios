// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Fields added after a save was written fall back to their default instead of failing the whole save.
@propertyWrapper
struct Lenient<T: Codable & DefaultProvidable>: Codable {
    var wrappedValue: T
    init(wrappedValue: T) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws { wrappedValue = (try? T(from: decoder)) ?? T.defaultValue }
    func encode(to encoder: Encoder) throws { try wrappedValue.encode(to: encoder) }
}
protocol DefaultProvidable { static var defaultValue: Self { get } }

extension Int: DefaultProvidable { static var defaultValue: Int { 0 } }

extension Double: DefaultProvidable { static var defaultValue: Double { 0 } }

extension Bool: DefaultProvidable { static var defaultValue: Bool { false } }

extension String: DefaultProvidable { static var defaultValue: String { "" } }

extension Array: DefaultProvidable where Element: Codable { static var defaultValue: [Element] { [] } }

extension Dictionary: DefaultProvidable where Key: Codable, Value: Codable { static var defaultValue: [Key: Value] { [:] } }

extension Set: DefaultProvidable where Element: Codable { static var defaultValue: Set<Element> { [] } }

extension Optional: DefaultProvidable where Wrapped: Codable { static var defaultValue: Wrapped? { nil } }

extension KeyedDecodingContainer {
    func decode<T>(_ type: Lenient<T>.Type, forKey key: Key) throws -> Lenient<T> {
        (try? decodeIfPresent(Lenient<T>.self, forKey: key)) ?? Lenient(wrappedValue: T.defaultValue)
    }
}

/// Unciv `@Transient`: a field that is never written to a save and comes back from one as its default.
@propertyWrapper
struct Transient<T: Codable & DefaultProvidable>: Codable {
    var wrappedValue: T
    init(wrappedValue: T) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws { wrappedValue = T.defaultValue }
    func encode(to encoder: Encoder) throws {}
}

extension KeyedDecodingContainer {
    func decode<T>(_ type: Transient<T>.Type, forKey key: Key) throws -> Transient<T> { Transient(wrappedValue: T.defaultValue) }
}

extension KeyedEncodingContainer {
    mutating func encode<T>(_ value: Transient<T>, forKey key: Key) throws {}
}
