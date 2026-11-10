import Foundation
// variants of splitIIMTime built from the public pieces
func v(_ value: String, len: Bool, digits: Bool, seventh: Bool) -> String {
    let chars = Array(value)
    if len { guard chars.count == 7 || chars.count == 11 || chars.count == 12 else { return value + "|" } }
    else { guard chars.count >= 7 else { return value + "|" } }
    if digits { guard isAllDigits(Array(chars[0..<6])) else { return value + "|" } }
    if seventh { guard chars[6] == "+" || chars[6] == "-" || chars[6] == "Z" else { return value + "|" } }
    guard let o = UTCOffset(parsing: value) else { return value + "|" }
    return String(chars[0..<6]) + "|" + o.text
}
func real(_ s: String) -> String { let p = splitIIMTime(s); return p.time + "|" + (p.offset?.text ?? "") }
var rng = SystemRandomNumberGenerator()
let alphabet = Array("0123456789012345+-Z:.,T ")
let seeds = ["184207Z","184207+0800","184207+08:00","18:42:07.5Z","184207.555Z","1842071+0800","2024-09-15T18:42:07+08:00","18:42+08:00","235960-1200"]
var diffNoDigits = 0, diffNoSeventh = 0, diffNeither = 0, n = 0, sanity = 0
var exNoSeventh: Set<String> = [], exNeither: Set<String> = []
var diffNoLen = 0, diffLenDigits = 0; var exNoLen: Set<String> = []
func probe(_ s: String) {
    n += 1
    let r = real(s)
    if r != v(s, len: true, digits: true, seventh: true) { sanity += 1 }
    if r != v(s, len: true, digits: false, seventh: true) { diffNoDigits += 1 }
    if r != v(s, len: true, digits: true, seventh: false) { diffNoSeventh += 1; if exNoSeventh.count < 6 { exNoSeventh.insert(s) } }
    if r != v(s, len: false, digits: true, seventh: true) { diffNoLen += 1; if exNoLen.count < 6 { exNoLen.insert(s) } }
    if r != v(s, len: false, digits: false, seventh: true) { diffLenDigits += 1 }
    if r != v(s, len: true, digits: false, seventh: false) { diffNeither += 1; if exNeither.count < 6 { exNeither.insert(s) } }
}
for s in seeds { probe(s) }
for _ in 0..<3_000_000 {
    // random string of length 7/11/12
    let L = Int.random(in: 7...16, using: &rng)
    var c = (0..<L).map { _ in alphabet.randomElement(using: &rng)! }
    probe(String(c))
    // mutated seed
    var s = Array(seeds.randomElement(using: &rng)!)
    for _ in 0..<Int.random(in: 0...2, using: &rng) {
        let i = Int.random(in: 0..<s.count, using: &rng)
        s[i] = alphabet.randomElement(using: &rng)!
    }
    if Bool.random(using: &rng), s.count > 7 { s.remove(at: Int.random(in: 0..<s.count, using: &rng)) }
    if Bool.random(using: &rng) { s.insert(alphabet.randomElement(using: &rng)!, at: Int.random(in: 0...s.count, using: &rng)) }
    probe(String(s))
    c = []
}
print("samples \(n); reimpl-vs-real mismatches \(sanity)")
print("drop isAllDigits(first six): \(diffNoDigits) differences")
print("drop chars[6] guard: \(diffNoSeventh) differences, e.g. \(exNoSeventh.sorted().prefix(6))")
print("relax length set {7,11,12} to >=7: \(diffNoLen) differences, e.g. \(exNoLen.sorted().prefix(6)); also dropping isAllDigits: \(diffLenDigits)")
print("184207+12+0800 with >=7:", v("184207+12+0800", len: false, digits: true, seventh: true))
print("drop both: \(diffNeither) differences, e.g. \(exNeither.sorted().prefix(6))")
for s in ["1842071+0800", "184207.555Z", "18:42:07.5Z"] {
    print(s, "real:", real(s), " no-7th:", v(s, len: true, digits: true, seventh: false), " no-digits:", v(s, len: true, digits: false, seventh: true))
}
print("carriesSameValue(\"٢٣\", \"x٢٣\") =", carriesSameValue("٢٣", "x٢٣"))
print("carriesSameValue(\"070800\", \"2024-09-15T18:42:07+08:00\") =", carriesSameValue("070800", "2024-09-15T18:42:07+08:00"))
print("carriesSameValue(\"091518\", \"2024:09:15 18:42:07\") =", carriesSameValue("091518", "2024:09:15 18:42:07"))
print("UTCOffset(18:42.5+08:00) =", UTCOffset(parsing: "18:42.5+08:00")?.text ?? "nil")
