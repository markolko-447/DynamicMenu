//
//  TransfersModule.swift
//  DynamicMenu
//
//  Progress of files arriving in Downloads: AirDrop receives and browser downloads.
//
//  Apps that write a file can publish its progress to the system (it is what puts
//  the progress bar on a file's icon in Finder). This module subscribes to that for
//  the Downloads folder. Apps that do not publish progress are not seen.
//

import Foundation
import SwiftUI
import Observation

@Observable
final class TransfersModule: ActivityModule {
    let id = "transfers"
    let priority = 60

    private(set) var fileName = ""
    private(set) var fraction = 0.0
    private(set) var isReceiving = false
    private(set) var isActive = false
    private(set) var activeSince = Date.distantPast

    @ObservationIgnored private var transfers: [Progress] = []
    @ObservationIgnored private var subscriber: Any?
    @ObservationIgnored private var sampleTask: Task<Void, Never>?

    func start() {
        guard subscriber == nil,
              let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        else { return }
        ProtectedFolder.downloads.markUsed()

        subscriber = Progress.addSubscriber(forFileURL: downloads) { [weak self] progress in
            let box = ProgressBox(progress)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.began(box.progress) }
            }
            return {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.ended(box.progress) }
                }
            }
        }
    }

    private func began(_ progress: Progress) {
        transfers.append(progress)
        if !isActive { activeSince = .now }
        sample()
        isActive = true

        guard sampleTask == nil else { return }
        // Progress objects change on other threads; sampling them is simpler and
        // safer than observing each one.
        sampleTask = Task { [weak self] in
            while !Task.isCancelled, let self, !self.transfers.isEmpty {
                self.sample()
                try? await Task.sleep(for: .milliseconds(300))
            }
            self?.sampleTask = nil
        }
    }

    private func ended(_ progress: Progress) {
        transfers.removeAll { $0 === progress }
        if transfers.isEmpty {
            fraction = 1
            isActive = false
        }
    }

    /// Shows the most recent transfer.
    private func sample() {
        guard let latest = transfers.last else { return }
        fileName = latest.fileURL?.lastPathComponent ?? "File"
        fraction = latest.fractionCompleted
        isReceiving = latest.fileOperationKind == .receiving
    }

    // MARK: - Presentation

    var symbol: String { isReceiving ? "dot.radiowaves.left.and.right" : "arrow.down.circle.fill" }

    var compactLeading: AnyView {
        // Radio waves ripple while receiving; the arrow breathes while downloading.
        AnyView(Image(systemName: symbol).foregroundStyle(.blue)
            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isReceiving)
            .symbolEffect(.pulse, options: .repeating, isActive: !isReceiving))
    }

    // A ring that fills smoothly, as Apple's own AirDrop does: no digits to flicker.
    var compactTrailing: AnyView {
        AnyView(TransferRing(module: self))
    }

    var minimal: AnyView {
        AnyView(TransferRing(module: self))
    }

    var expanded: AnyView {
        AnyView(TransferExpandedView(module: self))
    }
}

/// Carries a Progress to the main actor. Progress is thread-safe but not marked so.
private nonisolated struct ProgressBox: @unchecked Sendable {
    let progress: Progress
    init(_ progress: Progress) { self.progress = progress }
}

/// Progress as a ring that glides to each new value.
private struct TransferRing: View {
    let module: TransfersModule
    @Environment(\.pillContentHeight) private var contentHeight

    var body: some View {
        let side = min(contentHeight * 0.66, 18)
        ZStack {
            Circle().stroke(.blue.opacity(0.28), lineWidth: 2.4)
            Circle()
                .trim(from: 0, to: min(max(module.fraction, 0.02), 1))
                .stroke(.blue, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: side, height: side)
        .animation(.smooth(duration: 0.9), value: module.fraction)
        .accessibilityValue(Text(module.fraction, format: .percent.precision(.fractionLength(0))))
    }
}

private struct TransferExpandedView: View {
    let module: TransfersModule

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: module.symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text(module.fileName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                LevelBar(level: module.fraction, tint: .blue)
                    .frame(height: 6)
            }
        }
    }
}
