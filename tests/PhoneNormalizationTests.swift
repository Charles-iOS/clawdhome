import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct PhoneNormalizationTests {
    static func main() {
        expect(
            normalizeMainlandChinaPhone("13800138000") == "13800138000",
            "plain mainland number should normalize to local 11 digits"
        )
        expect(
            normalizeMainlandChinaPhone("138 0013 8000") == "13800138000",
            "spaces should be ignored during normalization"
        )
        expect(
            normalizeMainlandChinaPhone("138-0013-8000") == "13800138000",
            "hyphens should be ignored during normalization"
        )
        expect(
            normalizeMainlandChinaPhone("+8613800138000") == "13800138000",
            "numbers already in +86 format should normalize to local 11 digits"
        )
        expect(
            normalizeMainlandChinaPhone("8613800138000") == "13800138000",
            "numbers pasted with 86 prefix should normalize to local 11 digits"
        )
        expect(
            normalizeMainlandChinaPhone("23800138000") == nil,
            "numbers not starting with 1 should be rejected"
        )
        expect(
            normalizeMainlandChinaPhone("1380013800") == nil,
            "numbers shorter than 11 digits should be rejected"
        )
        expect(
            normalizeMainlandChinaPhone("") == nil,
            "empty input should be rejected"
        )

        print("Phone normalization tests passed.")
    }
}
