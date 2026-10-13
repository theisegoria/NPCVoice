// English number words with num2words' wording (cardinal, ordinal, year, decimal), so
// EnglishG2P matches misaki without the LGPL num2words package. Only the word sequence
// matters downstream: misaki drops "and" and punctuation when it phonemises numbers.
import Foundation

enum NumberWords {
    static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
                       "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    static let scales: [(Int, String)] = [(1_000_000_000_000, "trillion"), (1_000_000_000, "billion"), (1_000_000, "million"), (1000, "thousand")]

    static func cardinal(_ n: Int) -> String {
        if n < 0 { return "minus " + cardinal(-n) }
        if n < 20 { return ones[n] }
        if n < 100 { return tens[n / 10] + (n % 10 == 0 ? "" : "-" + ones[n % 10]) }
        if n < 1000 {
            return ones[n / 100] + " hundred" + (n % 100 == 0 ? "" : " and " + cardinal(n % 100))
        }
        for (value, name) in scales where n >= value {
            let high = n / value, low = n % value
            var s = cardinal(high) + " " + name
            if low > 0 { s += (low < 100 ? " and " : ", ") + cardinal(low) }
            return s
        }
        return String(n)
    }

    static func ordinal(_ n: Int) -> String {
        let words = cardinal(n)
        // Ordinalise the last word ("twenty-one" -> "twenty-first").
        let split = words.lastIndex(where: { $0 == " " || $0 == "-" })
        let head = split.map { String(words[...$0]) } ?? ""
        let last = split.map { String(words[words.index(after: $0)...]) } ?? words
        let irregular = ["one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth",
                         "nine": "ninth", "twelve": "twelfth"]
        let ord = irregular[last] ?? (last.hasSuffix("y") ? String(last.dropLast()) + "ieth" : last + "th")
        return head + ord
    }

    /// num2words 0.5.6 to_year: "nineteen hundred and
    /// ninety-nine", "eighteen hundred and fifty"; cardinal when the century is a
    /// multiple of ten ("two thousand and ten", "one thousand and sixty-six").
    static func year(_ n: Int) -> String {
        let high = n / 100, low = n % 100
        if high == 0 || high % 10 == 0 || high >= 100 { return cardinal(n) }
        return cardinal(high) + " hundred" + (low > 0 ? " and " + cardinal(low) : "")
    }

    /// "3.14" -> "three point one four".
    static func decimal(_ s: String) -> String {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        let whole = cardinal(Int(parts[0]) ?? 0)
        guard parts.count > 1, !parts[1].isEmpty else { return whole }
        return whole + " point " + parts[1].map { cardinal(Int(String($0)) ?? 0) }.joined(separator: " ")
    }
}
