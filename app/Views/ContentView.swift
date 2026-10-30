import SwiftUI

struct ContentView: View {
    @ObservedObject var model: ScannerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "scanner").font(.system(size: 34)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("HP Officejet 150").font(.title2.bold())
                    Text("Połącz drukarkę przez USB i włóż kartkę do skanera.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Form {
                Picker("Tryb", selection: $model.settings.mode) {
                    Text("Kolor").tag("Color")
                    Text("Odcienie szarości").tag("Gray")
                }
                Picker("Rozdzielczość", selection: $model.settings.dpi) {
                    ForEach(ScanSettings.resolutions, id: \.self) { dpi in
                        Text("\(dpi) dpi").tag(dpi)
                    }
                }
                Picker("Papier", selection: $model.settings.paper) {
                    Text("A4").tag("A4")
                    Text("Letter").tag("Letter")
                    Text("Legal").tag("Legal")
                }
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
            .disabled(model.isBusy)

            status

            HStack {
                Text("Zapis w formacie PNG").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.isScanning {
                    Button("Anuluj", action: model.cancel)
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.isCancelling)
                }
                Button("Skanuj…", action: model.chooseDestinationAndScan)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy)
            }
        }
        .padding(24)
        .frame(minWidth: 460, idealWidth: 500, maxWidth: 560)
    }

    @ViewBuilder private var status: some View {
        if model.isScanning {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.isCancelling ? "Anulowanie…" : "Skanowanie…")
                    Text("Poczekaj, aż skaner zwolni kartkę.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        } else if let failure = model.failure {
            VStack(alignment: .leading, spacing: 8) {
                Label(failure.message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                if let details = failure.details, !details.isEmpty {
                    DisclosureGroup("Szczegóły") {
                        ScrollView {
                            Text(details).font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 130)
                    }
                }
            }
        } else if let result = model.result {
            VStack(alignment: .leading, spacing: 8) {
                Label("Zapisano skan", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(URL(fileURLWithPath: result.path).lastPathComponent)
                    .lineLimit(1).truncationMode(.middle).help(result.path)
                Text("\(result.width) × \(result.height) pikseli · \(result.dpi) dpi")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Otwórz", action: model.openResult)
                    Button("Pokaż w Finderze", action: model.revealResult)
                }
            }
        } else if let notice = model.notice {
            Text(notice).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
