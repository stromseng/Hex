//
//  AgentSectionView.swift
//  Hex
//
//  Created for Agent Processing feature (#136)
//

import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct AgentSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		Section {
			// Enable toggle
			Label {
				Toggle("Enable Agent Processing", isOn: $store.hexSettings.agentModeEnabled)
			} icon: {
				Image(systemName: "terminal")
			}

			if store.hexSettings.agentModeEnabled {
				// Modifier picker
				Label {
					HStack {
						Text("Trigger Modifier")
						Spacer()
						Picker("", selection: $store.hexSettings.agentModeModifier) {
							ForEach(Modifier.Kind.allCases, id: \.self) { kind in
								Text("\(kind.symbol) \(kind.displayName)")
									.tag(kind)
							}
						}
						.pickerStyle(.menu)
						.fixedSize()
					}
				} icon: {
					Image(systemName: "keyboard")
				}

				Text("Hold this modifier along with your transcription hotkey to process through agent")
					.settingsCaption()

				// Script picker
				Label {
					VStack(alignment: .leading, spacing: 8) {
						HStack {
							Picker("Script", selection: Binding(
								get: { store.hexSettings.agentScriptName ?? "" },
								set: { store.send(.setAgentScriptName($0.isEmpty ? nil : $0)) }
							)) {
								Text("Select a script...")
									.tag("")
								
								ForEach(store.availableAgentScripts, id: \.self) { script in
									Text(script)
										.tag(script)
								}
							}
							.pickerStyle(.menu)
							
							Spacer()
							
							// Refresh button
							Button {
								store.send(.loadAvailableAgentScripts)
							} label: {
								Image(systemName: "arrow.clockwise")
							}
							.buttonStyle(.borderless)
							.help("Refresh script list")
						}

						HStack {
							Button("Open Scripts Folder") {
								store.send(.revealAgentScriptsFolder)
							}
							.buttonStyle(.link)
							
							Button("Add Claude Code Script") {
								store.send(.installBundledScript(.claudeCode))
							}
							.buttonStyle(.link)
							.disabled(store.isInstallingScript)

							if store.isInstallingScript {
								ProgressView()
									.controlSize(.small)
							}

							Spacer()
						}
						
						// Show installation status
						if let status = store.scriptInstallStatus {
							switch status {
							case let .success(message):
								Text(message)
									.foregroundStyle(.green)
									.font(.caption)
							case let .failure(message):
								Text(message)
									.foregroundStyle(.red)
									.font(.caption)
							}
						}
					}
				} icon: {
					Image(systemName: "doc.text")
				}

				Text("Scripts receive JSON via stdin with 'transcript' and optional 'selectedText' fields. Script output is pasted.")
					.settingsCaption()
			}
		} header: {
			Text("Agent")
		}
		.enableInjection()
	}
}
