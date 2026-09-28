import Foundation

/// Postman-compatible dynamic variables such as `{{$guid}}` and `{{$timestamp}}`.
public enum DynamicVariables {
    public static let names: [String] = [
        "$guid", "$randomUUID", "$timestamp", "$isoTimestamp", "$randomInt", "$randomBoolean",
        "$randomAlphaNumeric", "$randomHexColor", "$randomIP", "$randomEmail", "$randomUserName",
        "$randomFirstName", "$randomLastName", "$randomFullName", "$randomWord", "$randomColor",
        "$randomCity", "$randomCountry", "$randomPrice", "$randomDateFuture", "$randomDatePast",
    ]

    private static let firstNames = ["Alice", "Bob", "Carol", "David", "Emma", "Frank", "Grace", "Henry", "Linh", "Minh", "Nam", "Mai"]
    private static let lastNames = ["Smith", "Johnson", "Nguyen", "Tran", "Le", "Brown", "Garcia", "Miller", "Pham", "Wilson"]
    private static let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet"]
    private static let colors = ["red", "green", "blue", "yellow", "purple", "orange", "black", "white", "cyan", "magenta"]
    private static let cities = ["Hanoi", "Saigon", "Da Nang", "Tokyo", "Paris", "London", "Berlin", "Sydney", "Toronto", "Seoul"]
    private static let countries = ["Vietnam", "Japan", "France", "Germany", "Canada", "Australia", "Korea", "Brazil", "India", "Spain"]

    public static func value(for name: String) -> String? {
        switch name {
        case "$guid", "$randomUUID":
            return UUID().uuidString.lowercased()
        case "$timestamp":
            return String(Int(Date().timeIntervalSince1970))
        case "$isoTimestamp":
            return Date().formatted(.iso8601)
        case "$randomInt":
            return String(Int.random(in: 0...1000))
        case "$randomBoolean":
            return Bool.random() ? "true" : "false"
        case "$randomAlphaNumeric":
            return String("abcdefghijklmnopqrstuvwxyz0123456789".randomElement()!)
        case "$randomHexColor":
            return String(format: "#%06x", Int.random(in: 0...0xFFFFFF))
        case "$randomIP":
            return (0..<4).map { _ in String(Int.random(in: 1...254)) }.joined(separator: ".")
        case "$randomEmail":
            return "\(firstNames.randomElement()!.lowercased()).\(lastNames.randomElement()!.lowercased())\(Int.random(in: 1...99))@example.com"
        case "$randomUserName":
            return "\(firstNames.randomElement()!.lowercased())\(Int.random(in: 10...9999))"
        case "$randomFirstName":
            return firstNames.randomElement()
        case "$randomLastName":
            return lastNames.randomElement()
        case "$randomFullName":
            return "\(firstNames.randomElement()!) \(lastNames.randomElement()!)"
        case "$randomWord":
            return words.randomElement()
        case "$randomColor":
            return colors.randomElement()
        case "$randomCity":
            return cities.randomElement()
        case "$randomCountry":
            return countries.randomElement()
        case "$randomPrice":
            return String(format: "%.2f", Double.random(in: 1...1000))
        case "$randomDateFuture":
            return Date().addingTimeInterval(.random(in: 86_400...31_536_000)).formatted(.iso8601)
        case "$randomDatePast":
            return Date().addingTimeInterval(-.random(in: 86_400...31_536_000)).formatted(.iso8601)
        default:
            return nil
        }
    }
}
