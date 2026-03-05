import SwiftUI
import AppKit

struct InspectorView: View {
    @Bindable var viewModel: EditorViewModel
    
    // Binding directly to the active adjustments proxy in the ViewModel
    // This allows real-time updates of the selected clip's properties.
    var baseAdjustments: Binding<ColorAdjustments> {
        Binding(
            get: { viewModel.activeAdjustments },
            set: { viewModel.activeAdjustments = $0 }
        )
    }
    
    private var hasActiveClipSelection: Bool {
        viewModel.selectedClipId != nil || viewModel.isolatedClip != nil
    }
    
    var body: some View {
        VStack {
            Text("Inspector")
                .font(.headline)
                .foregroundColor(Theme.textMain)
                .padding(.vertical, 10)
            
            Divider()
                .background(Theme.separator)
            
            ScrollView {
                VStack(spacing: 16) {
                    if !hasActiveClipSelection {
                        Text("No clip selected. Controls remain visible.")
                            .font(.caption)
                            .foregroundColor(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    BasicAdjustmentsSection(adjustments: baseAdjustments)
                    DetailAdjustmentsSection(adjustments: baseAdjustments)
                    BasicColorSection(adjustments: baseAdjustments)
                    TrueHSLSection(adjustments: baseAdjustments)
                    ColorGradingSection(adjustments: baseAdjustments)
                    EffectsSection(adjustments: baseAdjustments)
                    ExportSection(viewModel: viewModel)
                }
                .padding()
            }
        }
        .background(Theme.panelBackground)
    }
}

// Sub-components
struct BasicAdjustmentsSection: View {
    @Binding var adjustments: ColorAdjustments
    @State private var isExpanded: Bool = true
    
    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 12) {
                SliderRow(title: "Exposure", value: $adjustments.exposure, range: -5...5)
                SliderRow(title: "Contrast", value: $adjustments.contrast, range: 0.7...1.3)
                SliderRow(title: "Highlights", value: $adjustments.highlights, range: -2...2)
                SliderRow(title: "Shadows", value: $adjustments.shadows, range: -2...2)
            }
            .padding(.top, 8)
        } label: {
            Text("Basic Settings").bold().foregroundColor(Theme.textMain)
        }
        .tint(Theme.accentPink)
    }
}

struct DetailAdjustmentsSection: View {
    @Binding var adjustments: ColorAdjustments
    @State private var isExpanded: Bool = false
    
    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 12) {
                SliderRow(title: "Clarity", value: $adjustments.clarity, range: -1...1)
                SliderRow(title: "Sharpness", value: $adjustments.sharpness, range: 0...2)
            }
            .padding(.top, 8)
        } label: {
            Text("Details").bold().foregroundColor(Theme.textMain)
        }
        .tint(Theme.accentPink)
    }
}

struct BasicColorSection: View {
    @Binding var adjustments: ColorAdjustments
    @State private var isExpanded: Bool = false
    
    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 12) {
                SliderRow(title: "Saturation", value: $adjustments.saturation, range: 0...2)
                SliderRow(title: "Vibrance", value: $adjustments.vibrance, range: -1...1)
            }
            .padding(.top, 8)
        } label: {
            Text("Basic Color").bold().foregroundColor(Theme.textMain)
        }
        .tint(Theme.accentPink)
    }
}

struct TrueHSLSection: View {
    @Binding var adjustments: ColorAdjustments
    @State private var isExpanded: Bool = false
    @State private var selectedColor: HSLColorChannel = .red
    
    enum HSLColorChannel: String, CaseIterable, Identifiable {
        case red = "Red", orange = "Orange", yellow = "Yellow", green = "Green"
        case aqua = "Aqua", blue = "Blue", purple = "Purple", magenta = "Magenta"
        var id: String { self.rawValue }
        
        var baseHue: Double {
            switch self {
            case .red: return 0.0
            case .orange: return 1.0 / 12.0
            case .yellow: return 1.0 / 6.0
            case .green: return 1.0 / 3.0
            case .aqua: return 0.5
            case .blue: return 2.0 / 3.0
            case .purple: return 0.75
            case .magenta: return 5.0 / 6.0
            }
        }
        
        var accentColor: Color {
            Color(hue: baseHue, saturation: 0.95, brightness: 0.95)
        }
    }
    
    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 12) {
                Picker("", selection: $selectedColor) {
                    ForEach(HSLColorChannel.allCases) { color in
                        Text(color.rawValue).tag(color)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                
                HSLControlView(hsl: binding(for: selectedColor), channel: selectedColor)
            }
            .padding(.top, 8)
        } label: {
            Text("True HSL").bold().foregroundColor(Theme.textMain)
        }
        .tint(Theme.accentPink)
    }
    
    private func binding(for channel: HSLColorChannel) -> Binding<HSLControl> {
        Binding {
            switch channel {
            case .red: return adjustments.redHSL
            case .orange: return adjustments.orangeHSL
            case .yellow: return adjustments.yellowHSL
            case .green: return adjustments.greenHSL
            case .aqua: return adjustments.aquaHSL
            case .blue: return adjustments.blueHSL
            case .purple: return adjustments.purpleHSL
            case .magenta: return adjustments.magentaHSL
            }
        } set: { newValue in
            switch channel {
            case .red: adjustments.redHSL = newValue
            case .orange: adjustments.orangeHSL = newValue
            case .yellow: adjustments.yellowHSL = newValue
            case .green: adjustments.greenHSL = newValue
            case .aqua: adjustments.aquaHSL = newValue
            case .blue: adjustments.blueHSL = newValue
            case .purple: adjustments.purpleHSL = newValue
            case .magenta: adjustments.magentaHSL = newValue
            }
        }
    }
}

struct HSLControlView: View {
    @Binding var hsl: HSLControl
    var channel: TrueHSLSection.HSLColorChannel
    
    private var hueGradient: LinearGradient {
        let h = channel.baseHue
        return LinearGradient(
            colors: [
                colorAtHue(h - 0.18),
                colorAtHue(h - 0.09),
                colorAtHue(h),
                colorAtHue(h + 0.09),
                colorAtHue(h + 0.18)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
    
    private var saturationGradient: LinearGradient {
        let h = channel.baseHue
        return LinearGradient(
            colors: [
                Color(hue: h, saturation: 0.02, brightness: 0.55),
                Color(hue: h, saturation: 0.55, brightness: 0.75),
                Color(hue: h, saturation: 1.0, brightness: 0.95)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
    
    private var luminanceGradient: LinearGradient {
        let h = channel.baseHue
        return LinearGradient(
            colors: [
                Color(hue: h, saturation: 1.0, brightness: 0.10),
                Color(hue: h, saturation: 0.95, brightness: 0.55),
                Color(hue: h, saturation: 0.30, brightness: 1.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
    
    var body: some View {
        VStack(spacing: 12) {
            ColorizedSliderRow(
                title: "Hue Shift",
                value: $hsl.hue,
                range: -1...1,
                gradient: hueGradient,
                tint: channel.accentColor
            )
            ColorizedSliderRow(
                title: "Saturation",
                value: $hsl.saturation,
                range: 0...2,
                gradient: saturationGradient,
                tint: channel.accentColor
            )
            ColorizedSliderRow(
                title: "Luminance",
                value: $hsl.luminance,
                range: -1...1,
                gradient: luminanceGradient,
                tint: channel.accentColor
            )
        }
    }
    
    private func colorAtHue(_ hue: Double) -> Color {
        var wrapped = hue.truncatingRemainder(dividingBy: 1.0)
        if wrapped < 0 { wrapped += 1.0 }
        return Color(hue: wrapped, saturation: 0.95, brightness: 0.95)
    }
}

struct ColorGradingSection: View {
    @Binding var adjustments: ColorAdjustments
    @State private var isExpanded: Bool = false
    
    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 16) {
                ColorWheelRow(title: "Global", wheel: $adjustments.globalTint)
                ColorWheelRow(title: "Shadows", wheel: $adjustments.shadowTint)
                ColorWheelRow(title: "Highlights", wheel: $adjustments.highlightTint)
            }
            .padding(.top, 8)
        } label: {
            Text("Color Grading").bold().foregroundColor(Theme.textMain)
        }
        .tint(Theme.accentPink)
    }
}

struct ColorWheelRow: View {
    var title: String
    @Binding var wheel: ColorWheelControl
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.caption).bold().foregroundColor(Theme.textSecondary)
            HueSliderRow(title: "Tint Hue", value: $wheel.hue, range: 0...6.28)
            SliderRow(title: "Intensity", value: $wheel.intensity, range: 0...1)
        }
    }
}

struct EffectsSection: View {
    @Binding var adjustments: ColorAdjustments
    @State private var isExpanded: Bool = false
    
    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 12) {
                SliderRow(title: "Vignette", value: $adjustments.vignette, range: 0...2)
                SliderRow(title: "Soft Blur", value: $adjustments.softBlur, range: 0...10)
                SliderRow(title: "Film Grain", value: $adjustments.grain, range: 0...1)
            }
            .padding(.top, 8)
        } label: {
            Text("Effects").bold().foregroundColor(Theme.textMain)
        }
        .tint(Theme.accentPink)
    }
}

@MainActor
struct ExportSection: View {
    var viewModel: EditorViewModel
    @State private var isExpanded: Bool = false
    @State private var isExporting: Bool = false
    @State private var exportMessageTitle: String = "Export"
    @State private var exportMessageBody: String = ""
    @State private var showExportAlert: Bool = false
    
    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Format").foregroundColor(Theme.textSecondary)
                Picker(
                    "",
                    selection: Binding(
                        get: { viewModel.exportFormat },
                        set: { viewModel.exportFormat = $0 }
                    )
                ) {
                    ForEach(ExportFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                
                Button(action: startExportFlow) {
                    HStack(spacing: 8) {
                        if isExporting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.black)
                        }
                        Text(isExporting ? "Exporting..." : "Export Video")
                    }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Theme.accentGreen)
                        .foregroundColor(.black)
                        .cornerRadius(8)
                }
                .disabled(isExporting)
                .opacity(isExporting ? 0.75 : 1.0)
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
            .padding(.top, 8)
        } label: {
            Text("Export").bold().foregroundColor(Theme.textMain)
        }
        .tint(Theme.accentPink)
        .alert(exportMessageTitle, isPresented: $showExportAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportMessageBody)
        }
    }
    
    private func startExportFlow() {
        guard !isExporting else { return }
        
        let selectedFormat = viewModel.exportFormat
        guard let destinationURL = presentSavePanel(for: selectedFormat) else {
            return
        }
        
        isExporting = true
        Task {
            do {
                try await viewModel.exportBottomTimeline(to: destinationURL, format: selectedFormat)
                exportMessageTitle = "Export Complete"
                exportMessageBody = "Video saved to:\n\(destinationURL.path)"
                showExportAlert = true
            } catch {
                exportMessageTitle = "Export Failed"
                exportMessageBody = error.localizedDescription
                showExportAlert = true
            }
            isExporting = false
        }
    }
    
    private func presentSavePanel(for format: ExportFormat) -> URL? {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                presentSavePanel(for: format)
            }
        }
        
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "TimelineExport.\(format.preferredExtension)"
        panel.title = "Export Video"
        panel.prompt = "Export"
        
        guard panel.runModal() == .OK, var url = panel.url else {
            return nil
        }
        
        if url.pathExtension.isEmpty {
            url.appendPathExtension(format.preferredExtension)
        }
        return url
    }
}

struct ColorizedSliderRow: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var gradient: LinearGradient
    var tint: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .foregroundColor(Theme.textSecondary)
                    .font(.caption)
                Spacer()
                Text(String(format: "%.2f", value))
                    .foregroundColor(tint)
                    .font(.caption.monospacedDigit())
            }
            Slider(value: $value, in: range)
                .tint(tint)
                .background(gradient.opacity(0.75).cornerRadius(4))
        }
    }
}

struct SliderRow: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .foregroundColor(Theme.textSecondary)
                    .font(.caption)
                Spacer()
                Text(String(format: "%.2f", value))
                    .foregroundColor(Theme.accentPink)
                    .font(.caption.monospacedDigit())
            }
            Slider(value: $value, in: range)
                .tint(Theme.accentPink)
        }
    }
}

struct HueSliderRow: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    
    let hueGradient = LinearGradient(
        colors: [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red],
        startPoint: .leading, endPoint: .trailing
    )
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .foregroundColor(Theme.textSecondary)
                    .font(.caption)
                Spacer()
                Text(String(format: "%.2f", value))
                    .foregroundColor(Theme.accentPink)
                    .font(.caption.monospacedDigit())
            }
            // A custom background behind the slider
            Slider(value: $value, in: range)
                .background(hueGradient.opacity(0.6).cornerRadius(4))
        }
    }
}
