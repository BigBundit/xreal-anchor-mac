import SwiftUI
import AppKit

/// View-local state. Kept in an ObservableObject because the Command Line Tools toolchain
/// lacks the SwiftUI macro plugin that `@State` needs.
final class PanelState: ObservableObject {
    @Published var showAdvanced = false
    @Published var launchAtLogin = LaunchAtLogin.isEnabled
}

struct ControlPanel: View {
    @EnvironmentObject var engine: AnchorEngine
    @EnvironmentObject var settings: Settings
    @StateObject private var ui = PanelState()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            statusRow
            mainControls
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    screenSection
                    trackingSection
                    DisclosureGroup("ขั้นสูง", isExpanded: $ui.showAdvanced) { advancedSection.padding(.top, 6) }
                    shortcutsSection
                }
                .padding(.trailing, 6)
            }
            .frame(maxHeight: 430)
            Divider()
            HStack {
                Text("ออกด้วย ⌘Q หรือปุ่มนี้").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("ปิดแอป") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: engine.isActive ? "sunglasses.fill" : "sunglasses")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(engine.isActive ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("XREAL Anchor").font(.headline)
                Text(engine.isActive ? "จอถูกล็อคอยู่ในพื้นที่" : "ปิดอยู่ — แว่นแสดงผลแบบปกติ")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                chip(engine.glassesModel ?? "ไม่พบแว่น (USB)", ok: engine.glassesModel != nil, icon: "cable.connector")
                chip(engine.glassesScreenName.map { "จอ \($0)" } ?? "ไม่พบจอแว่น", ok: engine.glassesScreenName != nil, icon: "display")
            }
            HStack(spacing: 6) {
                chip(engine.calibrated ? "Gyro calibrated" : "กำลังปรับเทียบ gyro…", ok: engine.calibrated, icon: "gyroscope")
                chip("IMU \(engine.imuRate) Hz", ok: engine.imuRate > 500, icon: "waveform.path.ecg")
                if engine.isActive { chip("\(engine.renderFPS) fps", ok: engine.renderFPS > 55, icon: "speedometer") }
            }
            if !engine.hasScreenPermission {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("ต้องอนุญาต Screen Recording").font(.caption)
                    Spacer()
                    Button("เปิดการตั้งค่า") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }.controlSize(.small)
                }
            }
            if let error = engine.lastError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var mainControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    engine.toggle()
                } label: {
                    Label(engine.isStarting ? "กำลังเริ่ม…" : (engine.isActive ? "ปิดการล็อคจอ" : "เปิดการล็อคจอ"),
                          systemImage: engine.isActive ? "lock.open" : "lock.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .help(ShortcutAction.toggleLock.display)
                .controlSize(.large)
                .disabled(engine.isStarting)

                Button {
                    engine.recenter()
                } label: {
                    Label("Recenter", systemImage: "scope").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .help(ShortcutAction.recenter.display)
            }
            HStack {
                keycap(.toggleLock).frame(maxWidth: .infinity)
                keycap(.recenter).frame(maxWidth: .infinity)
            }
            .padding(.top, -4)
            Picker("โหมด", selection: $settings.mode) {
                Text("ล็อคกับที่").tag(TrackingMode.anchored)
                Text("ตามนุ่มนวล").tag(TrackingMode.follow)
                Text("ติดหัว").tag(TrackingMode.headLocked)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                keycap(.modeAnchored).frame(maxWidth: .infinity)
                keycap(.modeFollow).frame(maxWidth: .infinity)
                keycap(.modeHeadLocked).frame(maxWidth: .infinity)
            }
            .padding(.top, -4)
            HStack(alignment: .firstTextBaseline) {
                Text(modeDescription).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                keycap(.cycleMode, label: "สลับ")
            }
        }
    }

    private var modeDescription: String {
        switch settings.mode {
        case .anchored: return "จอลอยนิ่งอยู่ตรงตำแหน่งเดิม หันหัวไปทางอื่นจอจะไม่ตามไป"
        case .follow: return "จอนิ่งเมื่อขยับหัวเล็กน้อย แต่ถ้าหันออกไปไกล จอจะค่อยๆ เลื่อนตามมา"
        case .headLocked: return "จอติดกับแว่นเหมือนปกติ (ยังใช้ขนาดจอ/จอโค้งได้)"
        }
    }

    private var screenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("จอเสมือน", icon: "rectangle.on.rectangle")
            sliderRow("ขนาดจอ", value: $settings.screenAngle, range: 15...120, step: 1, format: "%.0f°",
                      shortcuts: [.smaller, .bigger, .resetSize])
            HStack {
                Toggle("จอโค้ง (Curved)", isOn: $settings.curved)
                Spacer()
                keycap(.curved)
            }
            Picker("ความละเอียด", selection: $settings.resolutionID) {
                ForEach(ResolutionPreset.all) { Text($0.title).tag($0.id) }
            }
            Toggle("HiDPI (ตัวหนังสือคมขึ้น)", isOn: $settings.hiDPI)
        }
    }

    private var trackingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("การติดตามหัว", icon: "gyroscope")
            HStack {
                Toggle("โหมดจูน: แสดงกริดในแว่น", isOn: $settings.tuningGrid)
                Spacer()
                keycap(.tuningGrid)
            }
            if settings.tuningGrid {
                Text("ส่ายหัวช้าๆ ซ้าย-ขวา แล้วดูกริด: ถ้ากริดวิ่งตามหัว ลด FOV  ถ้าวิ่งสวนหัว เพิ่ม FOV · ถ้ากริดหน่วงแล้วค่อยตาม เพิ่มการทำนาย  ถ้าเด้งเลยแล้วกลับ ลดการทำนาย")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            sliderRow("FOV ของแว่น", value: $settings.glassesFOV, range: 35...55, step: 0.5, format: "%.1f°",
                      shortcuts: [.fovDown, .fovUp])
            sliderRow("ทำนายการเคลื่อนไหว (เพิ่มเติม)", value: $settings.predictionMs, range: -10...30, step: 1, format: "%+.0f ms",
                      shortcuts: [.predictionDown, .predictionUp])
            HStack {
                Toggle("ลดภาพสั่นตอนหัวนิ่ง", isOn: $settings.stabilize)
                Spacer()
                keycap(.stabilize)
            }
            if settings.mode == .follow {
                sliderRow("เริ่มตามเมื่อหันเกิน", value: $settings.followThreshold, range: 5...45, step: 1, format: "%.0f°")
                sliderRow("ความเร็วการตาม", value: $settings.followSpeed, range: 0.5...10, step: 0.5, format: "%.1f")
            }
            sliderRow("ระดับความสูงจอ (ตอน Recenter)", value: $settings.verticalOffset, range: -30...30, step: 1, format: "%+.0f°")
            HStack(spacing: 4) {
                Text("เลื่อนจอทันที").font(.caption).foregroundStyle(.secondary)
                Spacer()
                keycap(.nudgeUp); keycap(.nudgeDown); keycap(.nudgeLeft); keycap(.nudgeRight)
            }
            Toggle("วางจอที่ระดับสายตาเสมอ (ไม่สนว่าก้ม/เงย)", isOn: $settings.keepLevel)
            HStack {
                Button {
                    engine.calibrate()
                } label: {
                    Label("ปรับเทียบ Gyro", systemImage: "level")
                }
                if let p = engine.calibrationProgress {
                    ProgressView(value: Double(p)).frame(width: 120)
                } else {
                    Text("วางแว่นนิ่งๆ บนโต๊ะ 3 วิ").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                keycap(.calibrate)
            }
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sliderRow("ชดเชยจุดหมุนคอ", value: $settings.lensOffset, range: 0...0.15, step: 0.01, format: "%.2f")
            Toggle("กันเมาส์ไม่ให้หลุดเข้าจอแว่นจริง", isOn: $settings.guardCursor)
            Toggle("แสดงเคอร์เซอร์ในแว่น", isOn: $settings.showCursor)
            Toggle("กดปุ่มความสว่างบนแว่น 2 ครั้งเร็วๆ = Recenter", isOn: $settings.buttonRecenter)
            Toggle("เริ่มล็อคจออัตโนมัติเมื่อเสียบแว่น", isOn: $settings.autoStart)
            Toggle("เปิดแอปเมื่อเข้าสู่ระบบ", isOn: $ui.launchAtLogin)
                .onChange(of: ui.launchAtLogin) { _, v in LaunchAtLogin.set(v) }
            HStack {
                Toggle("กลับทิศซ้าย-ขวา", isOn: $settings.invertYaw)
                Toggle("กลับทิศขึ้น-ลง", isOn: $settings.invertPitch)
            }
            Text(String(format: "มุมหัวเทียบกับจอ: yaw %.1f°  pitch %.1f°  ·  %.1f°C",
                        engine.yawPitchDegrees.0, engine.yawPitchDegrees.1, engine.temperature))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("คีย์ลัด (ใช้ได้ทุกแอป)", icon: "keyboard")
            Text("กด \(ShortcutAction.modifiers) (Control + Option + Command) ค้างไว้ แล้วกดปุ่ม")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(ShortcutAction.groups, id: \.0) { group, actions in
                VStack(alignment: .leading, spacing: 3) {
                    Text(group).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(actions) { action in
                        HStack(spacing: 8) {
                            keycap(action).frame(width: 64, alignment: .leading)
                            Image(systemName: action.icon).font(.caption).frame(width: 16)
                            Text(action.title).font(.caption)
                            if failedShortcuts.contains(action) {
                                Text("ใช้ไม่ได้ (แอปอื่นจองไว้)").font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
        }
    }

    private var failedShortcuts: Set<ShortcutAction> {
        (NSApp.delegate as? AppDelegate)?.hotkeys.failed ?? []
    }

    /// The shortcut for a control, drawn like a keycap.
    private func keycap(_ action: ShortcutAction, label: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let label { Text(label).font(.caption2) }
            Text(action.display).font(.caption2.monospaced())
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
        .foregroundStyle(.secondary)
        .help(action.title)
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, format: String,
                           shortcuts: [ShortcutAction] = []) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title).font(.callout)
                Spacer()
                ForEach(shortcuts) { keycap($0) }
                Text(String(format: format, value.wrappedValue)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func chip(_ text: String, ok: Bool, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background((ok ? Color.green : Color.orange).opacity(0.15), in: Capsule())
            .foregroundStyle(ok ? Color.primary : Color.orange)
    }
}
