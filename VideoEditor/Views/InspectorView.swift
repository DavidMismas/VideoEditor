import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

    private var isMovieTimelineLocked: Bool {
        viewModel.isMovieTimelinePreviewActive
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Text("Inspector")
                .font(.headline)
                .foregroundColor(Theme.textMain)
                .padding(.vertical, 10)
            
            Divider()
                .background(Theme.separator)
            
            ScrollView {
                VStack(spacing: 16) {
                    if isMovieTimelineLocked {
                        Text("Movie preview is active. Clip editing controls are locked to avoid accidental changes.")
                            .font(.caption)
                            .foregroundColor(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    LUTLibrarySection(viewModel: viewModel)
                    
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
                    ToneCurveSection(adjustments: baseAdjustments)
                    EffectsSection(adjustments: baseAdjustments)
                }
                .padding()
                .disabled(isMovieTimelineLocked)
                .opacity(isMovieTimelineLocked ? 0.42 : 1)
            }

            Divider()
                .background(Theme.separator)

            HStack {
                Spacer()
                ExportSection(viewModel: viewModel)
                    .frame(maxWidth: 320)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Theme.panelBackground)
    }
}

struct LUTLibrarySection: View {
    @Bindable var viewModel: EditorViewModel
    @State private var isExpanded: Bool = true
    @State private var importMessage: String?
    
    var body: some View {
        InspectorSection(title: "LUT Library", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: importLUTAction) {
                    Label("Import LUT", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 10)
                        .background(Theme.accentGreen.opacity(0.85))
                        .foregroundColor(.black)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                
                if viewModel.importedLUTs.isEmpty {
                    Text("No LUT imported. Add Rec.709 creative .cube LUTs and drag them onto the middle Clip Editor timeline. Log/conversion LUTs are no longer supported.")
                        .font(.caption2)
                        .foregroundColor(Theme.textSecondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(viewModel.importedLUTs) { lut in
                            HStack(spacing: 8) {
                                Image(systemName: "cube.transparent")
                                    .foregroundColor(Theme.accentGreen)
                                Text(lut.name)
                                    .font(.caption)
                                    .foregroundColor(Theme.textMain)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .background(Theme.panelBackground.opacity(0.7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Theme.separator.opacity(0.8), lineWidth: 1)
                            )
                            .cornerRadius(6)
                            .contentShape(Rectangle())
                            .draggable("lut:\(lut.id.uuidString)")
                        }
                    }
                }
                
                if let importMessage {
                    Text(importMessage)
                        .font(.caption2)
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
    }
    
    private func importLUTAction() {
        let panel = NSOpenPanel()
        panel.title = "Import LUT"
        panel.prompt = "Import"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        let cubeType = UTType(filenameExtension: "cube") ?? .data
        panel.allowedContentTypes = [cubeType]
        
        guard panel.runModal() == .OK else { return }
        
        var importedCount = 0
        var rejectedCount = 0
        for url in panel.urls {
            if viewModel.importLUT(url: url) {
                importedCount += 1
            } else {
                rejectedCount += 1
            }
        }
        
        if rejectedCount > 0 {
            importMessage = "Imported \(importedCount) LUT(s), rejected \(rejectedCount) invalid file(s)."
        } else if importedCount > 0 {
            importMessage = "Imported \(importedCount) LUT(s). Use Rec.709 creative look LUTs and drag them onto the middle Clip Editor timeline."
        } else {
            importMessage = "No new LUT imported."
        }
    }
}

struct InspectorSection<Content: View>: View {
    var title: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            }) {
                HStack {
                    Text(title)
                        .bold()
                        .foregroundColor(Theme.textMain)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.accentPink)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                content()
                    .padding(.top, 8)
            }
        }
    }
}

// Sub-components
struct BasicAdjustmentsSection: View {
    @Binding var adjustments: ColorAdjustments
    @State private var isExpanded: Bool = true
    
    var body: some View {
        InspectorSection(title: "Basic Settings", isExpanded: $isExpanded) {
            VStack(spacing: 12) {
                SliderRow(title: "Exposure", value: $adjustments.exposure, range: -5...5)
                SliderRow(title: "Contrast", value: $adjustments.contrast, range: 0.5...1.5)
                SliderRow(title: "Highlights", value: $adjustments.highlights, range: -2...2)
                SliderRow(title: "Shadows", value: $adjustments.shadows, range: -2...2)
            }
        }
    }
}

struct DetailAdjustmentsSection: View {
    @Binding var adjustments: ColorAdjustments
    @State private var isExpanded: Bool = false
    
    var body: some View {
        InspectorSection(title: "Details", isExpanded: $isExpanded) {
            VStack(spacing: 12) {
                SliderRow(title: "Clarity", value: $adjustments.clarity, range: -1...1)
                SliderRow(title: "Sharpness", value: $adjustments.sharpness, range: 0...2)
            }
        }
    }
}

struct BasicColorSection: View {
    @Binding var adjustments: ColorAdjustments
    @State private var isExpanded: Bool = false
    
    var body: some View {
        InspectorSection(title: "Basic Color", isExpanded: $isExpanded) {
            VStack(spacing: 12) {
                SliderRow(title: "Saturation", value: $adjustments.saturation, range: 0...2)
                SliderRow(title: "Vibrance", value: $adjustments.vibrance, range: -1...1)
            }
        }
    }
}

struct TrueHSLSection: View {
    @Binding var adjustments: ColorAdjustments
    @State private var isExpanded: Bool = false
    @State private var selectedColor: ColorControlMath.HSLChannel = .red
    @State private var showDebug: Bool = false
    
    var body: some View {
        InspectorSection(title: "True HSL", isExpanded: $isExpanded) {
            VStack(spacing: 12) {
                Picker("", selection: $selectedColor) {
                    ForEach(ColorControlMath.HSLChannel.allCases) { color in
                        Text(color.displayName).tag(color)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                
                HSLControlView(hsl: binding(for: selectedColor), channel: selectedColor)
                SliderRow(
                    title: "HSL Tightness",
                    value: $adjustments.hslTightness,
                    range: 0.20...1.00,
                    tint: Color.srgb(selectedColor.displayColorRGB)
                )

                Toggle("Debug Mapping", isOn: $showDebug)
                    .toggleStyle(.switch)

                if showDebug {
                    let selectedControl = adjustments.hslControl(for: selectedColor)
                    let sampledHue = ColorControlMath.previewHueUnit(for: selectedColor, hueShift: selectedControl.hue)
                    let sampledRGB = ColorControlMath.hueUnitToDisplayRGB(sampledHue)
                    let weight = ColorControlMath.hslHueChannelWeight(
                        sampleHueUnit: sampledHue,
                        channel: selectedColor,
                        tightness: adjustments.hslTightness
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Channel: \(selectedColor.displayName)")
                        Text(String(format: "Center Hue: %.4f", selectedColor.centerHueUnit))
                        Text(String(format: "Sample Hue: %.4f", sampledHue))
                        Text(String(format: "LUT Hue Weight: %.4f", weight))
                        Text(String(format: "Preview RGB(sRGB): %.3f %.3f %.3f", sampledRGB.red, sampledRGB.green, sampledRGB.blue))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
    
    private func binding(for channel: ColorControlMath.HSLChannel) -> Binding<HSLControl> {
        Binding {
            adjustments.hslControl(for: channel)
        } set: { newValue in
            adjustments.setHSLControl(newValue, for: channel)
        }
    }
}

struct HSLControlView: View {
    @Binding var hsl: HSLControl
    var channel: ColorControlMath.HSLChannel
    
    private var activeHueUnit: Double {
        ColorControlMath.previewHueUnit(for: channel, hueShift: hsl.hue)
    }
    
    private var hueShiftTint: Color {
        Color.srgb(ColorControlMath.hueUnitToDisplayRGB(activeHueUnit))
    }
    
    private var saturationTint: Color {
        let baseRGB = ColorControlMath.hueUnitToDisplayRGB(activeHueUnit)
        let normalizedSat = min(max(hsl.saturation / 2.0, 0.05), 1.0)
        let preview = ColorControlMath.RGB(
            red: 0.5 + ((baseRGB.red - 0.5) * normalizedSat),
            green: 0.5 + ((baseRGB.green - 0.5) * normalizedSat),
            blue: 0.5 + ((baseRGB.blue - 0.5) * normalizedSat)
        ).clamped()
        return Color.srgb(preview)
    }
    
    private var luminanceTint: Color {
        let baseRGB = ColorControlMath.hueUnitToDisplayRGB(activeHueUnit)
        let brightness = min(max(0.5 + (hsl.luminance * 0.35), 0.15), 1.0)
        let sat = min(max(hsl.saturation / 2.0, 0.15), 1.0)
        let saturated = ColorControlMath.RGB(
            red: 0.5 + ((baseRGB.red - 0.5) * sat),
            green: 0.5 + ((baseRGB.green - 0.5) * sat),
            blue: 0.5 + ((baseRGB.blue - 0.5) * sat)
        )
        let preview = ColorControlMath.RGB(
            red: saturated.red * brightness,
            green: saturated.green * brightness,
            blue: saturated.blue * brightness
        ).clamped()
        return Color.srgb(preview)
    }
    
    var body: some View {
        VStack(spacing: 12) {
            SliderRow(
                title: "Hue Shift",
                value: $hsl.hue,
                range: -1...1,
                tint: hueShiftTint
            )
            SliderRow(
                title: "Saturation",
                value: $hsl.saturation,
                range: 0...2,
                tint: saturationTint
            )
            SliderRow(
                title: "Luminance",
                value: $hsl.luminance,
                range: -1...1,
                tint: luminanceTint
            )
        }
    }
}

struct ColorGradingSection: View {
    @Binding var adjustments: ColorAdjustments
    @State private var isExpanded: Bool = false
    @State private var showDebug: Bool = false
    
    var body: some View {
        InspectorSection(title: "Color Grading", isExpanded: $isExpanded) {
            VStack(spacing: 16) {
                Toggle("Debug Mapping", isOn: $showDebug)
                    .toggleStyle(.switch)

                VStack(spacing: 12) {
                    ColorWheelView(
                        title: "Lift",
                        luminanceLabel: "Shadows",
                        wheel: $adjustments.liftWheel,
                        displayRotationDegrees: 0,
                        wheelSize: 170,
                        showDebug: showDebug
                    )
                    .frame(maxWidth: .infinity, alignment: .center)

                    ColorWheelView(
                        title: "Gamma",
                        luminanceLabel: "Midtones",
                        wheel: $adjustments.gammaWheel,
                        displayRotationDegrees: 0,
                        wheelSize: 170,
                        showDebug: showDebug
                    )
                    .frame(maxWidth: .infinity, alignment: .center)

                    ColorWheelView(
                        title: "Gain",
                        luminanceLabel: "Highlights",
                        wheel: $adjustments.gainWheel,
                        displayRotationDegrees: 0,
                        wheelSize: 170,
                        showDebug: showDebug
                    )
                    .frame(maxWidth: .infinity, alignment: .center)

                    ColorWheelView(
                        title: "Offset",
                        luminanceLabel: "Global",
                        wheel: $adjustments.offsetWheel,
                        displayRotationDegrees: 0,
                        wheelSize: 170,
                        showDebug: showDebug
                    )
                    .frame(maxWidth: .infinity, alignment: .center)
                }

                SliderRow(title: "Lift", value: $adjustments.lift, range: -1...1)
                SliderRow(title: "Gamma", value: $adjustments.gamma, range: 0.2...3.0)
                SliderRow(title: "Gain", value: $adjustments.gain, range: 0...4.0)
                SliderRow(title: "Offset", value: $adjustments.offset, range: -1...1)
                SliderRow(title: "Filmic Rolloff", value: $adjustments.filmicHighlightRolloff, range: 0...2.5)
            }
        }
    }
}

struct ToneCurveSection: View {
    @Binding var adjustments: ColorAdjustments
    @State private var isExpanded: Bool = false

    var body: some View {
        InspectorSection(title: "Tone Curves", isExpanded: $isExpanded) {
            VStack(spacing: 14) {
                Toggle("Enable Luma Curve", isOn: $adjustments.lumaCurveEnabled)
                    .toggleStyle(.switch)
                ToneCurveEditor(title: "Luma", curve: $adjustments.lumaCurve, tint: Theme.accentGreen)

                Toggle("Enable RGB Curves", isOn: $adjustments.rgbCurvesEnabled)
                    .toggleStyle(.switch)

                if adjustments.rgbCurvesEnabled {
                    ToneCurveEditor(title: "Red", curve: $adjustments.redCurve, tint: .red)
                    ToneCurveEditor(title: "Green", curve: $adjustments.greenCurve, tint: .green)
                    ToneCurveEditor(title: "Blue", curve: $adjustments.blueCurve, tint: .blue)
                }
            }
        }
    }
}

struct ToneCurveEditor: View {
    var title: String
    @Binding var curve: ToneCurvePoints
    var tint: Color

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .bold()
                .foregroundColor(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            SliderRow(title: "P0", value: $curve.p0, range: 0...1, tint: tint)
            SliderRow(title: "P1", value: $curve.p1, range: 0...1, tint: tint)
            SliderRow(title: "P2", value: $curve.p2, range: 0...1, tint: tint)
            SliderRow(title: "P3", value: $curve.p3, range: 0...1, tint: tint)
            SliderRow(title: "P4", value: $curve.p4, range: 0...1, tint: tint)
        }
        .padding(.vertical, 4)
    }
}

struct ColorWheelModel: Equatable {
    var hue: Double
    var intensity: Double
    var luminance: Double

    init(hue: Double = 0.0, intensity: Double = 0.0, luminance: Double = 0.0) {
        let value = ColorControlMath.WheelValue(
            angleRadians: hue,
            intensity: intensity,
            luminance: luminance
        )
        self.hue = value.angleRadians
        self.intensity = value.intensity
        self.luminance = value.luminance
    }

    init(control: ColorWheelControl) {
        self.init(hue: control.hue, intensity: control.intensity, luminance: control.luma)
    }

    var control: ColorWheelControl {
        ColorWheelControl(hue: hue, intensity: intensity, luma: luminance)
    }

    var wheelValue: ColorControlMath.WheelValue {
        ColorControlMath.WheelValue(
            angleRadians: hue,
            intensity: intensity,
            luminance: luminance
        )
    }

    var normalizedHue: Double {
        wheelValue.hueUnit
    }

    var angleDegrees: Double {
        wheelValue.angleDegrees
    }

    var previewRGB: ColorControlMath.RGB {
        ColorControlMath.wheelValueToRGBPreview(wheelValue)
    }

    var processingRGB: ColorControlMath.RGB {
        ColorControlMath.wheelValueToProcessingTint(wheelValue)
    }
}

enum ColorWheelInteractionHandler {
    static func center(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width * 0.5, y: size.height * 0.5)
    }

    static func maxRadius(in size: CGSize) -> Double {
        max(1.0, Double(min(size.width, size.height) * 0.5) - 10.0)
    }

    static func model(
        from dragLocation: CGPoint,
        in size: CGSize,
        current: ColorWheelModel,
        displayRotationRadians: Double = 0.0
    ) -> ColorWheelModel {
        let wheelCenter = center(in: size)
        let radiusLimit = maxRadius(in: size)
        let value = ColorControlMath.pointToWheelValue(
            point: dragLocation,
            center: wheelCenter,
            maxRadius: radiusLimit,
            luminance: current.luminance,
            displayRotationRadians: displayRotationRadians
        )
        return ColorWheelModel(hue: value.angleRadians, intensity: value.intensity, luminance: value.luminance)
    }

    static func knobPosition(
        for model: ColorWheelModel,
        in size: CGSize,
        displayRotationRadians: Double = 0.0
    ) -> CGPoint {
        let wheelCenter = center(in: size)
        return ColorControlMath.wheelValueToPoint(
            model.wheelValue,
            center: wheelCenter,
            maxRadius: maxRadius(in: size),
            displayRotationRadians: displayRotationRadians
        )
    }
}

struct ColorWheelView: View {
    var title: String
    var luminanceLabel: String
    @Binding var wheel: ColorWheelControl
    var displayRotationDegrees: Double = 0
    var wheelSize: CGFloat = 118
    var showDebug: Bool = false

    private var displayRotationRadians: Double {
        ColorControlMath.radians(fromDegrees: displayRotationDegrees)
    }

    private var modelBinding: Binding<ColorWheelModel> {
        Binding(
            get: { ColorWheelModel(control: wheel) },
            set: { wheel = $0.control }
        )
    }

    private var tintColor: Color {
        let model = modelBinding.wrappedValue
        return Color.srgb(model.previewRGB)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption.bold())
                    .foregroundColor(Theme.textSecondary)
                Spacer(minLength: 4)
                Button("Reset") {
                    reset()
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundColor(Theme.accentPink)
            }

            GeometryReader { proxy in
                let size = proxy.size
                let model = modelBinding.wrappedValue
                let center = ColorWheelInteractionHandler.center(in: size)
                let radiusLimit = ColorWheelInteractionHandler.maxRadius(in: size)
                let knob = ColorWheelInteractionHandler.knobPosition(
                    for: model,
                    in: size,
                    displayRotationRadians: displayRotationRadians
                )
                let wheelImage = ColorWheelImageRenderer.shared.image(
                    size: size,
                    maxRadius: radiusLimit,
                    displayRotationRadians: displayRotationRadians
                )

                ZStack {
                    Image(nsImage: wheelImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: size.width, height: size.height)
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .stroke(Theme.separator.opacity(0.85), lineWidth: 1)
                        )

                    Circle()
                        .stroke(Theme.separator.opacity(0.35), lineWidth: 1)
                        .scaleEffect(0.66)

                    Path { path in
                        path.move(to: center)
                        path.addLine(to: knob)
                    }
                    .stroke(Color.white.opacity(0.55), lineWidth: 1.2)

                    Circle()
                        .fill(tintColor)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.white.opacity(0.95), lineWidth: 2))
                        .shadow(color: Color.black.opacity(0.35), radius: 2, x: 0, y: 1)
                        .position(knob)
                }
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            modelBinding.wrappedValue = ColorWheelInteractionHandler.model(
                                from: gesture.location,
                                in: size,
                                current: modelBinding.wrappedValue,
                                displayRotationRadians: displayRotationRadians
                            )
                        }
                )
                .onTapGesture(count: 2) {
                    reset()
                }
            }
            .frame(width: wheelSize, height: wheelSize)

            SliderRow(title: luminanceLabel, value: $wheel.luma, range: -1...1, tint: tintColor)

            if showDebug {
                let model = modelBinding.wrappedValue
                let preview = model.previewRGB
                let processing = model.processingRGB
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "Angle: %.2f°", model.angleDegrees))
                    Text(String(format: "Hue: %.4f", model.normalizedHue))
                    Text(String(format: "Intensity: %.4f", model.intensity))
                    Text(String(format: "Preview RGB(sRGB): %.3f %.3f %.3f", preview.red, preview.green, preview.blue))
                    Text(String(format: "Processing RGB: %.3f %.3f %.3f", processing.red, processing.green, processing.blue))
                }
                .font(.caption2.monospacedDigit())
                .foregroundColor(Theme.textSecondary)
            }
        }
        .padding(10)
        .frame(width: wheelSize + 34)
        .background(Theme.panelBackground.opacity(0.68))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.separator.opacity(0.75), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    private func reset() {
        wheel = ColorWheelControl()
    }
}

struct EffectsSection: View {
    @Binding var adjustments: ColorAdjustments
    @State private var isExpanded: Bool = false
    
    var body: some View {
        InspectorSection(title: "Effects", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                SliderRow(title: "Vignette", value: $adjustments.vignette, range: 0...3)
                SliderRow(title: "Soft Blur", value: $adjustments.softBlur, range: 0...10)
            }
        }
    }
}

@MainActor
struct ExportSection: View {
    var viewModel: EditorViewModel
    @State private var isExporting: Bool = false
    @State private var exportProgress: Double = 0
    @State private var exportMessageTitle: String = "Export"
    @State private var exportMessageBody: String = ""
    @State private var showExportAlert: Bool = false
    @State private var showExportSettingsSheet: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export")
                .bold()
                .foregroundColor(Theme.textMain)

            if isExporting {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: exportProgress, total: 1.0)
                        .tint(Theme.accentGreen)
                    Text("Export progress: \(Int((exportProgress * 100).rounded()))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(Theme.textSecondary)
                }
            }
            
            Button(action: { showExportSettingsSheet = true }) {
                HStack(spacing: 8) {
                    if isExporting {
                        ProgressView(value: exportProgress, total: 1.0)
                            .controlSize(.small)
                            .tint(.black)
                            .frame(width: 42)
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
            .padding(.top, 6)
        }
        .padding(12)
        .background(Theme.panelBackground.opacity(0.75))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.separator.opacity(0.8), lineWidth: 1)
        )
        .cornerRadius(10)
        .sheet(isPresented: $showExportSettingsSheet) {
            ExportSettingsSheet(
                viewModel: viewModel,
                onCancel: {
                    showExportSettingsSheet = false
                },
                onExport: {
                    showExportSettingsSheet = false
                    DispatchQueue.main.async {
                        startExportFlow()
                    }
                }
            )
        }
        .alert(exportMessageTitle, isPresented: $showExportAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportMessageBody)
        }
    }
    
    private func startExportFlow() {
        guard !isExporting else { return }
        
        let selectedFormat = viewModel.exportFormat
        let selectedQuality = viewModel.exportQuality
        let selectedFrameRate = viewModel.exportFrameRate
        guard let destinationURL = presentSavePanel(for: selectedFormat) else {
            return
        }
        
        isExporting = true
        exportProgress = 0
        Task {
            do {
                try await viewModel.exportBottomTimeline(
                    to: destinationURL,
                    format: selectedFormat,
                    quality: selectedQuality,
                    frameRate: selectedFrameRate,
                    onProgress: { progress in
                        exportProgress = progress
                    }
                )
                exportProgress = 1
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

@MainActor
private struct ExportSettingsSheet: View {
    var viewModel: EditorViewModel
    let onCancel: () -> Void
    let onExport: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Settings")
                .font(.headline)
                .foregroundColor(Theme.textMain)
            
            settingBlock(
                title: "Format",
                content: {
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
                }
            )
            
            settingBlock(
                title: "Quality",
                content: {
                    Picker(
                        "",
                        selection: Binding(
                            get: { viewModel.exportQuality },
                            set: { viewModel.exportQuality = $0 }
                        )
                    ) {
                        ForEach(ExportQuality.allCases) { quality in
                            Text(quality.displayName).tag(quality)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            )
            
            settingBlock(
                title: "Frame Rate",
                content: {
                    Picker(
                        "",
                        selection: Binding(
                            get: { viewModel.exportFrameRate },
                            set: { viewModel.exportFrameRate = $0 }
                        )
                    ) {
                        ForEach(ExportFrameRate.allCases) { fps in
                            Text(fps.displayName).tag(fps)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            )

            settingBlock(
                title: "Project Canvas",
                content: {
                    Text("\(viewModel.projectCanvasDescription) • \(viewModel.projectResolutionDescription)")
                        .foregroundColor(Theme.textMain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Theme.backgroundDark.opacity(0.8))
                        .cornerRadius(10)
                }
            )
            
            Text("Target bitrate: \(viewModel.exportQuality.targetBitrate(for: viewModel.exportFormat) / 1_000_000) Mbps")
                .font(.caption2.monospacedDigit())
                .foregroundColor(Theme.textSecondary)
            
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Start Export", action: onExport)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 380)
        .background(Theme.panelBackground)
    }
    
    private func settingBlock<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .foregroundColor(Theme.textSecondary)
            content()
        }
    }
}

struct SliderRow: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var tint: Color = Theme.accentPink
    
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
        }
    }
}

private final class ColorWheelImageRenderer {
    static let shared = ColorWheelImageRenderer()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 64
    }

    func image(size: CGSize, maxRadius: Double, displayRotationRadians: Double) -> NSImage {
        let pointDiameter = max(2.0, min(size.width, size.height))
        let scale = max(1.0, NSScreen.main?.backingScaleFactor ?? 2.0)
        let pixelDiameter = max(2, Int((pointDiameter * scale).rounded(.toNearestOrAwayFromZero)))
        let radiusKey = Int((maxRadius * scale * 100.0).rounded(.toNearestOrAwayFromZero))
        let rotationKey = Int((displayRotationRadians * 10_000.0).rounded(.toNearestOrAwayFromZero))
        let key = "\(pixelDiameter)-\(radiusKey)-\(rotationKey)" as NSString

        if let cached = cache.object(forKey: key) {
            return cached
        }

        let rendered = render(
            pointDiameter: pointDiameter,
            pixelDiameter: pixelDiameter,
            maxRadiusPixels: maxRadius * scale,
            displayRotationRadians: displayRotationRadians
        )
        cache.setObject(rendered, forKey: key)
        return rendered
    }

    private func render(
        pointDiameter: CGFloat,
        pixelDiameter: Int,
        maxRadiusPixels: Double,
        displayRotationRadians: Double
    ) -> NSImage {
        let width = pixelDiameter
        let height = pixelDiameter
        let outerRadius = (Double(pixelDiameter) - 1.0) * 0.5
        let center = CGPoint(x: outerRadius, y: outerRadius)
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        for py in 0..<height {
            for px in 0..<width {
                let x = Double(px) + 0.5
                let y = Double(py) + 0.5
                let dx = x - Double(center.x)
                let dy = y - Double(center.y)
                let distance = sqrt((dx * dx) + (dy * dy))
                let offset = (py * bytesPerRow) + (px * 4)

                guard distance <= outerRadius else {
                    pixels[offset + 0] = 0
                    pixels[offset + 1] = 0
                    pixels[offset + 2] = 0
                    pixels[offset + 3] = 0
                    continue
                }

                let value = ColorControlMath.pointToWheelValue(
                    point: CGPoint(x: x, y: y),
                    center: center,
                    maxRadius: maxRadiusPixels,
                    luminance: 0.0,
                    displayRotationRadians: displayRotationRadians
                )
                let rgb = ColorControlMath.wheelValueToRGBPreview(value).clamped()

                pixels[offset + 0] = UInt8((rgb.red * 255.0).rounded(.toNearestOrAwayFromZero))
                pixels[offset + 1] = UInt8((rgb.green * 255.0).rounded(.toNearestOrAwayFromZero))
                pixels[offset + 2] = UInt8((rgb.blue * 255.0).rounded(.toNearestOrAwayFromZero))
                pixels[offset + 3] = 255
            }
        }

        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let provider = CGDataProvider(data: Data(pixels) as CFData),
            let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        else {
            return NSImage(size: NSSize(width: pointDiameter, height: pointDiameter))
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: pointDiameter, height: pointDiameter))
    }
}

private extension Color {
    static func srgb(_ rgb: ColorControlMath.RGB, opacity: Double = 1.0) -> Color {
        let clamped = rgb.clamped()
        return Color(
            .sRGB,
            red: clamped.red,
            green: clamped.green,
            blue: clamped.blue,
            opacity: opacity
        )
    }
}
