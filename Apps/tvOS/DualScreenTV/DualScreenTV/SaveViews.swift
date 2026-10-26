import SwiftUI
import Combine
import UIKit

struct SaveStateView: View {
    let gameTitle: String
    let manager: StateManager
    let save: (Int) -> Void
    let load: (Int) -> Void
    let done: () -> Void
    @State private var slots: [StateSlotInfo] = []
    @State private var selectedLoad: Int?
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Text(gameTitle).font(.title2)
                Text("Save a moment. Come back to it.").font(.body).foregroundStyle(.secondary)
                Text("Save states are tied to this emulator version. Keep using the game's own save feature too.").font(.caption).foregroundStyle(.secondary)
                ForEach(slots) { slot in
                    HStack(spacing: 24) {
                        if let data = slot.thumbnail, let image = UIImage(data: data) {
                            Image(uiImage: image).resizable().scaledToFit().frame(width: 140, height: 90).clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        VStack(alignment: .leading) {
                            Text("Slot \(slot.slot)").font(.headline)
                            Text(slot.date?.formatted(date: .abbreviated, time: .shortened) ?? "Empty slot").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Save") { save(slot.slot); refresh() }
                        Button("Load") { selectedLoad = slot.slot }.disabled(slot.date == nil)
                    }.tvStudioPanel()
                }
                Button("Back to Game Menu", action: done)
            }.padding(40).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }.background(TVStudioBackground())
        .buttonStyle(TVStudioButtonStyle())
        .task { refresh() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in refresh() }
        .alert("Load this save state?", isPresented: Binding(get: { selectedLoad != nil }, set: { if !$0 { selectedLoad = nil } })) {
            Button("Load") { if let slot = selectedLoad { load(slot) }; selectedLoad = nil }
            Button("Cancel", role: .cancel) { selectedLoad = nil }
        } message: { Text("This replaces the current running game. Your in-game save checkpoint remains protected.") }
    }
    private func refresh() { manager.slots { slots = $0 } }
}

struct GameBackupView: View {
    let game: GameEntry
    let saves: URL
    @State private var entries: [BackupChoice] = []
    @State private var selection: BackupChoice?
    @State private var busy = false
    @State private var message = ""
    private struct BackupChoice: Identifiable {
        let core: String; let history: SaveHistory; let entry: SaveHistory.Entry
        var id: String { core + entry.id }
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Text("Saved progress, with room to go back.").font(.title2)
                Text("Five dated copies are kept locally as saves change or games close. Export important saves in Add/Edit Games: local copies can still be removed by tvOS.").font(.caption).foregroundStyle(.secondary)
                if entries.isEmpty { Text("No backup history yet. Save in your game, then return to the library.") }
                ForEach(entries) { choice in
                    Button {
                        selection = choice
                    } label: {
                        VStack(alignment: .leading) {
                            Text(choice.entry.date.formatted(date: .abbreviated, time: .shortened))
                            Text(choice.core).font(.caption).foregroundStyle(.secondary)
                        }
                    }.disabled(busy)
                }
                Text(message).font(.caption)
            }.padding(50).frame(maxWidth: 1000).frame(maxWidth: .infinity)
        }.background(TVStudioBackground()).navigationTitle("Save Backups").navigationBarHidden(false)
        .task { await refresh() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in if !busy { Task { await refresh() } } }
        .alert("Restore this backup?", isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })) {
            Button("Restore") {
                guard let choice = selection else { return }
                selection = nil; busy = true
                Task {
                    let result = await Task.detached(priority: .utility) { Result { try choice.history.restore(choice.entry) } }.value
                    message = (try? result.get()) != nil ? "Backup restored. Open your game to continue." : "Could not restore this backup. Your files have been kept where possible."
                    busy = false; await refresh()
                }
            }
            Button("Cancel", role: .cancel) { selection = nil }
        } message: { Text("Current saves are backed up first. This affects only the displayed core; different DS cores have separate saves.") }
    }
    private func refresh() async {
        let id = game.id, saves = saves
        entries = await Task.detached(priority: .utility) {
            var choices: [BackupChoice] = []
            for core in ["melonDS", "DeSmuME", "Dust", "3DS", "mGBA", "PSP"] {
                let history = SaveHistory(source: core == "melonDS" ? saves : saves.appendingPathComponent(core).appendingPathComponent(id), destination: saves.deletingLastPathComponent().appendingPathComponent("SaveHistory").appendingPathComponent(id).appendingPathComponent(core), filePrefix: core == "melonDS" ? id : nil)
                choices += ((try? history.entries()) ?? []).map { BackupChoice(core: core, history: history, entry: $0) }
            }
            for core in ["melonDS", "mGBA"] {
                let source = core == "melonDS" ? saves : saves.appendingPathComponent(core).appendingPathComponent(id)
                let history = SaveHistory(source: source, destination: source.appendingPathComponent("BatteryHistory").appendingPathComponent(id), filePrefix: id + ".dstvsave")
                choices += ((try? history.entries()) ?? []).map { BackupChoice(core: core + " checkpoint", history: history, entry: $0) }
            }
            return choices.sorted { $0.entry.date > $1.entry.date }
        }.value
    }
}
