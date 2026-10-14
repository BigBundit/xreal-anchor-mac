import Carbon.HIToolbox
import Foundation

/// Every global shortcut, in the order shown in the menu. All are ⌃⌥⌘ + `key`.
enum ShortcutAction: CaseIterable, Identifiable {
    case toggleLock, recenter
    case modeAnchored, modeFollow, modeHeadLocked, cycleMode
    case bigger, smaller, resetSize, curved
    case nudgeUp, nudgeDown, nudgeLeft, nudgeRight
    case stabilize, calibrate
    case tuningGrid, fovDown, fovUp, predictionDown, predictionUp

    var id: Self { self }

    static let modifiers = "⌃⌥⌘"

    var keyCode: Int {
        switch self {
        case .toggleLock: return kVK_ANSI_A
        case .recenter: return kVK_ANSI_R
        case .modeAnchored: return kVK_ANSI_1
        case .modeFollow: return kVK_ANSI_2
        case .modeHeadLocked: return kVK_ANSI_3
        case .cycleMode: return kVK_ANSI_M
        case .bigger: return kVK_ANSI_Equal
        case .smaller: return kVK_ANSI_Minus
        case .resetSize: return kVK_ANSI_0
        case .curved: return kVK_ANSI_C
        case .nudgeUp: return kVK_UpArrow
        case .nudgeDown: return kVK_DownArrow
        case .nudgeLeft: return kVK_LeftArrow
        case .nudgeRight: return kVK_RightArrow
        case .stabilize: return kVK_ANSI_S
        case .calibrate: return kVK_ANSI_G
        case .tuningGrid: return kVK_ANSI_T
        case .fovDown: return kVK_ANSI_LeftBracket
        case .fovUp: return kVK_ANSI_RightBracket
        case .predictionDown: return kVK_ANSI_Comma
        case .predictionUp: return kVK_ANSI_Period
        }
    }

    /// The key as printed on the keyboard.
    var key: String {
        switch self {
        case .toggleLock: return "A"
        case .recenter: return "R"
        case .modeAnchored: return "1"
        case .modeFollow: return "2"
        case .modeHeadLocked: return "3"
        case .cycleMode: return "M"
        case .bigger: return "="
        case .smaller: return "−"
        case .resetSize: return "0"
        case .curved: return "C"
        case .nudgeUp: return "↑"
        case .nudgeDown: return "↓"
        case .nudgeLeft: return "←"
        case .nudgeRight: return "→"
        case .stabilize: return "S"
        case .calibrate: return "G"
        case .tuningGrid: return "T"
        case .fovDown: return "["
        case .fovUp: return "]"
        case .predictionDown: return ","
        case .predictionUp: return "."
        }
    }

    var display: String { ShortcutAction.modifiers + key }

    var title: String {
        switch self {
        case .toggleLock: return "เปิด/ปิดการล็อคจอ"
        case .recenter: return "ดึงจอมาตรงหน้า (Recenter)"
        case .modeAnchored: return "โหมดล็อคกับที่"
        case .modeFollow: return "โหมดตามนุ่มนวล"
        case .modeHeadLocked: return "โหมดติดหัว"
        case .cycleMode: return "สลับโหมดวนไป"
        case .bigger: return "ขยายจอ"
        case .smaller: return "ย่อจอ"
        case .resetSize: return "ขนาดจอเริ่มต้น"
        case .curved: return "จอโค้ง / จอแบน"
        case .nudgeUp: return "เลื่อนจอขึ้น"
        case .nudgeDown: return "เลื่อนจอลง"
        case .nudgeLeft: return "เลื่อนจอไปซ้าย"
        case .nudgeRight: return "เลื่อนจอไปขวา"
        case .stabilize: return "เปิด/ปิดลดภาพสั่น"
        case .calibrate: return "ปรับเทียบ Gyro"
        case .tuningGrid: return "โหมดจูน (แสดงกริด)"
        case .fovDown: return "ลด FOV"
        case .fovUp: return "เพิ่ม FOV"
        case .predictionDown: return "ลดการทำนาย"
        case .predictionUp: return "เพิ่มการทำนาย"
        }
    }

    var icon: String {
        switch self {
        case .toggleLock: return "lock"
        case .recenter: return "scope"
        case .modeAnchored: return "pin"
        case .modeFollow: return "figure.walk"
        case .modeHeadLocked: return "sunglasses"
        case .cycleMode: return "arrow.triangle.2.circlepath"
        case .bigger: return "plus.magnifyingglass"
        case .smaller: return "minus.magnifyingglass"
        case .resetSize: return "arrow.counterclockwise"
        case .curved: return "rectangle.portrait.arrowtriangle.2.outward"
        case .nudgeUp: return "arrow.up"
        case .nudgeDown: return "arrow.down"
        case .nudgeLeft: return "arrow.left"
        case .nudgeRight: return "arrow.right"
        case .stabilize: return "waveform.path"
        case .calibrate: return "level"
        case .tuningGrid: return "grid"
        case .fovDown: return "arrow.down.right.and.arrow.up.left"
        case .fovUp: return "arrow.up.left.and.arrow.down.right"
        case .predictionDown: return "backward"
        case .predictionUp: return "forward"
        }
    }

    /// Groups for the shortcut list in the menu.
    static let groups: [(String, [ShortcutAction])] = [
        ("หลัก", [.toggleLock, .recenter]),
        ("โหมด", [.modeAnchored, .modeFollow, .modeHeadLocked, .cycleMode]),
        ("ขนาดและรูปทรงจอ", [.bigger, .smaller, .resetSize, .curved]),
        ("ตำแหน่งจอ", [.nudgeUp, .nudgeDown, .nudgeLeft, .nudgeRight]),
        ("จูนความนิ่ง", [.tuningGrid, .fovDown, .fovUp, .predictionDown, .predictionUp]),
        ("อื่นๆ", [.stabilize, .calibrate]),
    ]
}
