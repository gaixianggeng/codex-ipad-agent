import Foundation

enum AnsiCleaner {
    static func clean(_ raw: String) -> String {
        var output = ""
        var iterator = raw.unicodeScalars.makeIterator()

        while let scalar = iterator.next() {
            if scalar.value == 0x1B {
                skipEscapeSequence(&iterator)
                continue
            }
            if scalar.value == 0x0D {
                output.append("\n")
                continue
            }
            if scalar.value == 0x09 || scalar.value == 0x0A || scalar.value >= 0x20 {
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }

    private static func skipEscapeSequence(_ iterator: inout String.UnicodeScalarView.Iterator) {
        guard let first = iterator.next() else {
            return
        }
        // OSC 序列以 ESC ] 开头，直到 BEL 或 ST 结束。
        if first == "]" {
            var previousWasEscape = false
            while let scalar = iterator.next() {
                if scalar.value == 0x07 {
                    return
                }
                if previousWasEscape && scalar == "\\" {
                    return
                }
                previousWasEscape = scalar.value == 0x1B
            }
            return
        }
        // CSI 序列以 ESC [ 开头，最终字节范围 0x40...0x7E。
        if first == "[" {
            while let scalar = iterator.next() {
                if (0x40...0x7E).contains(Int(scalar.value)) {
                    return
                }
            }
        }
    }
}
