//
//  TranscriptionFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import ComposableArchitecture
import CoreGraphics
import Foundation
import HexCore
import Inject
import SwiftUI
import WhisperKit

private let transcriptionFeatureLogger = HexLog.transcription

@Reducer
struct TranscriptionFeature {
  @ObservableState
  struct State {
    var isRecording: Bool = false
    var isTranscribing: Bool = false
    var isPrewarming: Bool = false
    var isProcessingWithAgent: Bool = false
    var agentModeActive: Bool = false
    var capturedSelectedText: String? = nil
    var error: String?
    var recordingStartTime: Date?
    var meter: Meter = .init(averagePower: 0, peakPower: 0)
    var sourceAppBundleID: String?
    var sourceAppName: String?
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isRemappingScratchpadFocused) var isRemappingScratchpadFocused: Bool = false
    @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
  }

  enum Action {
    case task
    case audioLevelUpdated(Meter)

    // Hotkey actions
    case hotKeyPressed(agentMode: Bool)
    case hotKeyReleased

    // Recording flow
    case startRecording(agentMode: Bool)
    case stopRecording

    // Selected text capture for agent mode
    case selectedTextCaptured(String?)

    // Cancel/discard flow
    case cancel   // Explicit cancellation with sound
    case discard  // Silent discard (too short/accidental)

    // Transcription result flow
    case transcriptionResult(String, URL)
    case transcriptionError(Error, URL?)

    // Agent processing flow
    case agentProcessingCompleted(String, URL)
    case agentProcessingFailed(Error, String, URL)

    // Model availability
    case modelMissing
  }

  enum CancelID {
    case metering
    case transcription
    case agentProcessing
  }

  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.soundEffects) var soundEffect
  @Dependency(\.sleepManagement) var sleepManagement
  @Dependency(\.date.now) var now
  @Dependency(\.transcriptPersistence) var transcriptPersistence
  @Dependency(\.agentProcessing) var agentProcessing

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      // MARK: - Lifecycle / Setup

      case .task:
        // Starts two concurrent effects:
        // 1) Observing audio meter
        // 2) Monitoring hot key events
        // 3) Priming the recorder for instant startup
        return .merge(
          startMeteringEffect(),
          startHotKeyMonitoringEffect(),
          warmUpRecorderEffect()
        )

      // MARK: - Metering

      case let .audioLevelUpdated(meter):
        state.meter = meter
        return .none

      // MARK: - HotKey Flow

      case let .hotKeyPressed(agentMode):
        // If we're transcribing, send a cancel first. Otherwise start recording immediately.
        // We'll decide later (on release) whether to keep or discard the recording.
        return handleHotKeyPressed(isTranscribing: state.isTranscribing, agentMode: agentMode)

      case .hotKeyReleased:
        // If we're currently recording, then stop. Otherwise, just cancel
        // the delayed "startRecording" effect if we never actually started.
        return handleHotKeyReleased(isRecording: state.isRecording)

      // MARK: - Recording Flow

      case let .startRecording(agentMode):
        return handleStartRecording(&state, agentMode: agentMode)

      case .stopRecording:
        return handleStopRecording(&state)

      // MARK: - Selected Text Capture

      case let .selectedTextCaptured(text):
        state.capturedSelectedText = text
        return .none

      // MARK: - Transcription Results

      case let .transcriptionResult(result, audioURL):
        return handleTranscriptionResult(&state, result: result, audioURL: audioURL)

      case let .transcriptionError(error, audioURL):
        return handleTranscriptionError(&state, error: error, audioURL: audioURL)

      // MARK: - Agent Processing Results

      case let .agentProcessingCompleted(result, audioURL):
        return handleAgentProcessingCompleted(&state, result: result, audioURL: audioURL)

      case let .agentProcessingFailed(error, originalTranscript, audioURL):
        return handleAgentProcessingFailed(&state, error: error, originalTranscript: originalTranscript, audioURL: audioURL)

      case .modelMissing:
        return .none

      // MARK: - Cancel/Discard Flow

      case .cancel:
        // Only cancel if we're in the middle of recording, transcribing, or agent processing
        guard state.isRecording || state.isTranscribing || state.isProcessingWithAgent else {
          return .none
        }
        return handleCancel(&state)

      case .discard:
        // Silent discard for quick/accidental recordings
        guard state.isRecording else {
          return .none
        }
        return handleDiscard(&state)
      }
    }
  }
}

// MARK: - Effects: Metering & HotKey

private extension TranscriptionFeature {
  /// Effect to begin observing the audio meter.
  func startMeteringEffect() -> Effect<Action> {
    .run { send in
      for await meter in await recording.observeAudioLevel() {
        await send(.audioLevelUpdated(meter))
      }
    }
    .cancellable(id: CancelID.metering, cancelInFlight: true)
  }

  /// Effect to start monitoring hotkey events through the `keyEventMonitor`.
  func startHotKeyMonitoringEffect() -> Effect<Action> {
    .run { send in
      // Wrap processors in a class to ensure mutations persist across @Sendable closure calls
      final class ProcessorState: @unchecked Sendable {
        var base: HotKeyProcessor = .init(hotkey: HotKey(key: nil, modifiers: [.option]))
        var agent: HotKeyProcessor = .init(hotkey: HotKey(key: nil, modifiers: [.option, .control]))
      }
      let processors = ProcessorState()
      @Shared(.isSettingHotKey) var isSettingHotKey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings
      
      // Helper to check if a key event matches a hotkey
      func chordMatchesHotkey(_ event: KeyEvent, hotkey: HotKey) -> Bool {
        if hotkey.key != nil {
          return event.key == hotkey.key && event.modifiers.matchesExactly(hotkey.modifiers)
        } else {
          return event.key == nil && event.modifiers.matchesExactly(hotkey.modifiers)
        }
      }

      // Handle incoming input events (keyboard and mouse)
      let token = keyEventMonitor.handleInputEvent { inputEvent in
        // Skip if the user is currently setting a hotkey
        if isSettingHotKey {
          return false
        }

        // Always keep processors in sync with current user hotkey preference
        let baseHotkey = hexSettings.hotkey
        processors.base.hotkey = baseHotkey
        processors.base.useDoubleTapOnly = hexSettings.useDoubleTapOnly
        processors.base.minimumKeyTime = hexSettings.minimumKeyTime

        // Build agent hotkey = base modifiers + agent modifier
        let agentModeEnabled = hexSettings.agentModeEnabled
        let agentModifierKind = hexSettings.agentModeModifier
        let agentModifier = Modifier(kind: agentModifierKind)
        let agentHotkey = HotKey(
          key: baseHotkey.key,
          modifiers: baseHotkey.modifiers.union([agentModifier])
        )
        processors.agent.hotkey = agentHotkey
        processors.agent.useDoubleTapOnly = hexSettings.useDoubleTapOnly
        processors.agent.minimumKeyTime = hexSettings.minimumKeyTime

        switch inputEvent {
        case .keyboard(let keyEvent):
          // If Escape is pressed with no modifiers while idle, treat as cancel
          if keyEvent.key == .escape, keyEvent.modifiers.isEmpty,
             processors.base.state == .idle, processors.agent.state == .idle
          {
            Task { await send(.cancel) }
            return false
          }

          // Check if the agent modifier is currently held
          let agentModifierHeld = keyEvent.modifiers.contains(kind: agentModifierKind)
          
          // Check if current event matches either hotkey exactly
          let matchesAgentHotkey = agentModeEnabled && chordMatchesHotkey(keyEvent, hotkey: agentHotkey)
          let matchesBaseHotkey = chordMatchesHotkey(keyEvent, hotkey: baseHotkey)
          
          // Log key details for debugging
          let eventModsStr = keyEvent.modifiers.kinds.map { $0.rawValue }.joined(separator: ",")
          let baseModsStr = baseHotkey.modifiers.kinds.map { $0.rawValue }.joined(separator: ",")
          let agentModsStr = agentHotkey.modifiers.kinds.map { $0.rawValue }.joined(separator: ",")
          print("🔑 HotKey routing: event=[\(eventModsStr)] base=[\(baseModsStr)] agent=[\(agentModsStr)] agentEnabled=\(agentModeEnabled) agentModHeld=\(agentModifierHeld) matchesAgent=\(matchesAgentHotkey) matchesBase=\(matchesBaseHotkey)")
          transcriptionFeatureLogger.notice(
            "HotKey routing: event=[\(eventModsStr)] base=[\(baseModsStr)] agent=[\(agentModsStr)] agentEnabled=\(agentModeEnabled) agentModHeld=\(agentModifierHeld) matchesAgent=\(matchesAgentHotkey) matchesBase=\(matchesBaseHotkey) baseState=\(String(describing: processors.base.state)) agentState=\(String(describing: processors.agent.state))"
          )

          // ROUTING LOGIC:
          // 1. If we're already in an active recording state (not idle), route to that processor
          // 2. If the event matches the agent hotkey exactly, route to agent processor
          // 3. If the event matches the base hotkey exactly (and agent modifier NOT held), route to base processor
          // 4. If agent modifier is held but doesn't match agent hotkey yet, route to agent processor (building up)
          // 5. Otherwise, route to base processor
          
          let shouldUseAgentProcessor: Bool
          if processors.agent.state != .idle {
            // Agent recording is active, keep routing to agent
            shouldUseAgentProcessor = true
            print("🔀 Routing to AGENT (agent not idle)")
          } else if processors.base.state != .idle {
            // Base recording is active, keep routing to base
            shouldUseAgentProcessor = false
            print("🔀 Routing to BASE (base not idle)")
          } else if matchesAgentHotkey {
            // Exact match for agent hotkey
            shouldUseAgentProcessor = true
            print("🔀 Routing to AGENT (exact match)")
          } else if matchesBaseHotkey && !agentModifierHeld {
            // Exact match for base hotkey and agent modifier not held
            shouldUseAgentProcessor = false
            print("🔀 Routing to BASE (exact match, no agent mod)")
          } else if agentModeEnabled && agentModifierHeld {
            // Agent modifier is held, route to agent processor even if not full match yet
            shouldUseAgentProcessor = true
            print("🔀 Routing to AGENT (agent mod held)")
          } else {
            // Default to base processor
            shouldUseAgentProcessor = false
            print("🔀 Routing to BASE (default)")
          }

          if shouldUseAgentProcessor {
            // Process with agent processor
            let agentResult = processors.agent.process(keyEvent: keyEvent)
            print("🤖 Agent processor result: \(String(describing: agentResult)) state=\(String(describing: processors.agent.state))")
            switch agentResult {
            case .startRecording:
              transcriptionFeatureLogger.notice("Agent hotkey triggered - starting agent mode recording")
              if processors.agent.state == .doubleTapLock {
                Task { await send(.startRecording(agentMode: true)) }
              } else {
                Task { await send(.hotKeyPressed(agentMode: true)) }
              }
              return hexSettings.useDoubleTapOnly || keyEvent.key != nil

            case .stopRecording:
              Task { await send(.hotKeyReleased) }
              return false

            case .cancel:
              Task { await send(.cancel) }
              return true

            case .discard:
              Task { await send(.discard) }
              return false

            case .none:
              if let pressedKey = keyEvent.key,
                 pressedKey == processors.agent.hotkey.key,
                 keyEvent.modifiers == processors.agent.hotkey.modifiers
              {
                return true
              }
              return false
            }
          } else {
            // Process with base processor
            switch processors.base.process(keyEvent: keyEvent) {
            case .startRecording:
              transcriptionFeatureLogger.notice("Base hotkey triggered - starting normal recording")
              if processors.base.state == .doubleTapLock {
                Task { await send(.startRecording(agentMode: false)) }
              } else {
                Task { await send(.hotKeyPressed(agentMode: false)) }
              }
              return hexSettings.useDoubleTapOnly || keyEvent.key != nil

            case .stopRecording:
              Task { await send(.hotKeyReleased) }
              return false

            case .cancel:
              Task { await send(.cancel) }
              return true

            case .discard:
              Task { await send(.discard) }
              return false

            case .none:
              if let pressedKey = keyEvent.key,
                 pressedKey == processors.base.hotkey.key,
                 keyEvent.modifiers == processors.base.hotkey.modifiers
              {
                return true
              }
              return false
            }
          }

        case .mouseClick:
          // Process mouse click - for modifier-only hotkeys, this may cancel/discard
          // Only process for the currently active processor
          if agentModeEnabled && processors.agent.state != .idle {
            switch processors.agent.processMouseClick() {
            case .cancel:
              Task { await send(.cancel) }
              return false
            case .discard:
              Task { await send(.discard) }
              return false
            case .startRecording, .stopRecording, .none:
              return false
            }
          } else {
            switch processors.base.processMouseClick() {
            case .cancel:
              Task { await send(.cancel) }
              return false
            case .discard:
              Task { await send(.discard) }
              return false
            case .startRecording, .stopRecording, .none:
              return false
            }
          }
        }
      }

      defer { token.cancel() }

      await withTaskCancellationHandler {
        do {
          try await Task.sleep(nanoseconds: .max)
        } catch {
          // Cancellation expected
        }
      } onCancel: {
        token.cancel()
      }
    }
  }

  func warmUpRecorderEffect() -> Effect<Action> {
    .run { _ in
      await recording.warmUpRecorder()
    }
  }
}

// MARK: - HotKey Press/Release Handlers

private extension TranscriptionFeature {
  func handleHotKeyPressed(isTranscribing: Bool, agentMode: Bool) -> Effect<Action> {
    // If already transcribing, cancel first. Otherwise start recording immediately.
    let maybeCancel = isTranscribing ? Effect.send(Action.cancel) : .none
    let startRecording = Effect.send(Action.startRecording(agentMode: agentMode))
    return .merge(maybeCancel, startRecording)
  }

  func handleHotKeyReleased(isRecording: Bool) -> Effect<Action> {
    // Always stop recording when hotkey is released
    return isRecording ? .send(.stopRecording) : .none
  }
}

// MARK: - Recording Handlers

private extension TranscriptionFeature {
  func handleStartRecording(_ state: inout State, agentMode: Bool) -> Effect<Action> {
    guard state.modelBootstrapState.isModelReady else {
      return .merge(
        .send(.modelMissing),
        .run { _ in soundEffect.play(.cancel) }
      )
    }
    state.isRecording = true
    state.agentModeActive = agentMode
    state.capturedSelectedText = nil
    let startTime = Date()
    state.recordingStartTime = startTime
    
    // Capture the active application
    if let activeApp = NSWorkspace.shared.frontmostApplication {
      state.sourceAppBundleID = activeApp.bundleIdentifier
      state.sourceAppName = activeApp.localizedName
    }
    transcriptionFeatureLogger.notice("Recording started at \(startTime.ISO8601Format()), agentMode=\(agentMode)")

    // Prevent system sleep during recording
    return .run { [sleepManagement, preventSleep = state.hexSettings.preventSystemSleep, pasteboard] send in
      // Play sound immediately for instant feedback
      soundEffect.play(.startRecording)

      if preventSleep {
        await sleepManagement.preventSleep(reason: "Hex Voice Recording")
      }
      
      // If agent mode is active, capture the currently selected text before recording
      if agentMode {
        let selectedText = await pasteboard.getSelectedText()
        await send(.selectedTextCaptured(selectedText))
        if let text = selectedText {
          transcriptionFeatureLogger.info("Captured selected text for agent mode: \(text.prefix(50), privacy: .private)...")
        }
      }
      
      await recording.startRecording()
    }
  }

  func handleStopRecording(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    
    let stopTime = now
    let startTime = state.recordingStartTime
    let duration = startTime.map { stopTime.timeIntervalSince($0) } ?? 0

    let decision = RecordingDecisionEngine.decide(
      .init(
        hotkey: state.hexSettings.hotkey,
        minimumKeyTime: state.hexSettings.minimumKeyTime,
        recordingStartTime: state.recordingStartTime,
        currentTime: stopTime
      )
    )

    let startStamp = startTime?.ISO8601Format() ?? "nil"
    let stopStamp = stopTime.ISO8601Format()
    let minimumKeyTime = state.hexSettings.minimumKeyTime
    let hotkeyHasKey = state.hexSettings.hotkey.key != nil
    transcriptionFeatureLogger.notice(
      "Recording stopped duration=\(String(format: "%.3f", duration))s start=\(startStamp) stop=\(stopStamp) decision=\(String(describing: decision)) minimumKeyTime=\(String(format: "%.2f", minimumKeyTime)) hotkeyHasKey=\(hotkeyHasKey)"
    )

    guard decision == .proceedToTranscription else {
      // If the user recorded for less than minimumKeyTime and the hotkey is modifier-only,
      // discard the audio to avoid accidental triggers.
      transcriptionFeatureLogger.notice("Discarding short recording per decision \(String(describing: decision))")
      return .run { _ in
        let url = await recording.stopRecording()
        try? FileManager.default.removeItem(at: url)
      }
    }

    // Otherwise, proceed to transcription
    state.isTranscribing = true
    state.error = nil
    let model = state.hexSettings.selectedModel
    let language = state.hexSettings.outputLanguage

    state.isPrewarming = true

    return .run { [sleepManagement] send in
      // Allow system to sleep again
      await sleepManagement.allowSleep()

      var audioURL: URL?
      do {
        soundEffect.play(.stopRecording)
        let capturedURL = await recording.stopRecording()
        audioURL = capturedURL

        // Create transcription options with the selected language
        // Note: cap concurrency to avoid audio I/O overloads on some Macs
        let decodeOptions = DecodingOptions(
          language: language,
          detectLanguage: language == nil, // Only auto-detect if no language specified
          chunkingStrategy: .vad,
        )
        
        let result = try await transcription.transcribe(capturedURL, model, decodeOptions) { _ in }
        
        transcriptionFeatureLogger.notice("Transcribed audio from \(capturedURL.lastPathComponent) to text length \(result.count)")
        await send(.transcriptionResult(result, capturedURL))
      } catch {
        transcriptionFeatureLogger.error("Transcription failed: \(error.localizedDescription)")
        await send(.transcriptionError(error, audioURL))
      }
    }
    .cancellable(id: CancelID.transcription)
  }
}

// MARK: - Transcription Handlers

private extension TranscriptionFeature {
  func handleTranscriptionResult(
    _ state: inout State,
    result: String,
    audioURL: URL
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false

    // Check for force quit command (emergency escape hatch)
    if ForceQuitCommandDetector.matches(result) {
      transcriptionFeatureLogger.fault("Force quit voice command recognized; terminating Hex.")
      return .run { _ in
        try? FileManager.default.removeItem(at: audioURL)
        await MainActor.run {
          NSApp.terminate(nil)
        }
      }
    }

    // If empty text, nothing else to do
    guard !result.isEmpty else {
      state.agentModeActive = false
      state.capturedSelectedText = nil
      return .none
    }

    let duration = state.recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0

    transcriptionFeatureLogger.info("Raw transcription: '\(result)'")
    let remappings = state.hexSettings.wordRemappings
    let remappedResult: String
    if state.isRemappingScratchpadFocused {
      remappedResult = result
      transcriptionFeatureLogger.info("Scratchpad focused; skipping remappings")
    } else {
      remappedResult = WordRemappingApplier.apply(result, remappings: remappings)
      if remappedResult != result {
        transcriptionFeatureLogger.info("Applied \(remappings.count) word remapping(s)")
      }
    }

    guard !remappedResult.isEmpty else {
      state.agentModeActive = false
      state.capturedSelectedText = nil
      return .none
    }

    // If agent mode is active, route to agent processing instead of direct paste
    if state.agentModeActive, let scriptName = state.hexSettings.agentScriptName {
      state.isProcessingWithAgent = true
      let selectedText = state.capturedSelectedText
      
      transcriptionFeatureLogger.info("Routing transcription to agent script: \(scriptName)")
      
      return .run { [agentProcessing] send in
        do {
          let input = AgentInput(transcript: remappedResult, selectedText: selectedText)
          let processedResult = try await agentProcessing.process(input, scriptName)
          await send(.agentProcessingCompleted(processedResult, audioURL))
        } catch {
          transcriptionFeatureLogger.error("Agent processing failed: \(error.localizedDescription)")
          await send(.agentProcessingFailed(error, remappedResult, audioURL))
        }
      }
      .cancellable(id: CancelID.agentProcessing)
    }

    // Normal flow: paste directly
    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let transcriptionHistory = state.$transcriptionHistory

    return .run { send in
      do {
        try await finalizeRecordingAndStoreTranscript(
          result: remappedResult,
          duration: duration,
          sourceAppBundleID: sourceAppBundleID,
          sourceAppName: sourceAppName,
          audioURL: audioURL,
          transcriptionHistory: transcriptionHistory
        )
      } catch {
        await send(.transcriptionError(error, audioURL))
      }
    }
    .cancellable(id: CancelID.transcription)
  }

  func handleTranscriptionError(
    _ state: inout State,
    error: Error,
    audioURL: URL?
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false
    state.isProcessingWithAgent = false
    state.agentModeActive = false
    state.capturedSelectedText = nil
    state.error = error.localizedDescription
    
    if let audioURL {
      try? FileManager.default.removeItem(at: audioURL)
    }

    return .none
  }

  func handleAgentProcessingCompleted(
    _ state: inout State,
    result: String,
    audioURL: URL
  ) -> Effect<Action> {
    state.isProcessingWithAgent = false
    state.agentModeActive = false
    state.capturedSelectedText = nil

    // If empty result from agent, nothing to paste
    guard !result.isEmpty else {
      transcriptionFeatureLogger.info("Agent returned empty result, skipping paste")
      try? FileManager.default.removeItem(at: audioURL)
      return .none
    }

    let duration = state.recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let transcriptionHistory = state.$transcriptionHistory

    transcriptionFeatureLogger.info("Agent processing completed, result length: \(result.count)")

    return .run { send in
      do {
        try await finalizeRecordingAndStoreTranscript(
          result: result,
          duration: duration,
          sourceAppBundleID: sourceAppBundleID,
          sourceAppName: sourceAppName,
          audioURL: audioURL,
          transcriptionHistory: transcriptionHistory
        )
      } catch {
        await send(.transcriptionError(error, audioURL))
      }
    }
    .cancellable(id: CancelID.agentProcessing)
  }

  func handleAgentProcessingFailed(
    _ state: inout State,
    error: Error,
    originalTranscript: String,
    audioURL: URL
  ) -> Effect<Action> {
    state.isProcessingWithAgent = false
    state.agentModeActive = false
    state.capturedSelectedText = nil
    state.error = error.localizedDescription

    transcriptionFeatureLogger.error("Agent processing failed: \(error.localizedDescription)")

    // Play cancel sound to indicate failure
    return .run { _ in
      try? FileManager.default.removeItem(at: audioURL)
      soundEffect.play(.cancel)
    }
  }

  /// Move file to permanent location, create a transcript record, paste text, and play sound.
  func finalizeRecordingAndStoreTranscript(
    result: String,
    duration: TimeInterval,
    sourceAppBundleID: String?,
    sourceAppName: String?,
    audioURL: URL,
    transcriptionHistory: Shared<TranscriptionHistory>
  ) async throws {
    @Shared(.hexSettings) var hexSettings: HexSettings

    if hexSettings.saveTranscriptionHistory {
      let transcript = try await transcriptPersistence.save(
        result,
        audioURL,
        duration,
        sourceAppBundleID,
        sourceAppName
      )

      transcriptionHistory.withLock { history in
        history.history.insert(transcript, at: 0)

        if let maxEntries = hexSettings.maxHistoryEntries, maxEntries > 0 {
          while history.history.count > maxEntries {
            if let removedTranscript = history.history.popLast() {
              Task {
                 try? await transcriptPersistence.deleteAudio(removedTranscript)
              }
            }
          }
        }
      }
    } else {
      try? FileManager.default.removeItem(at: audioURL)
    }

    await pasteboard.paste(result)
    soundEffect.play(.pasteTranscript)
  }
}

// MARK: - Cancel/Discard Handlers

private extension TranscriptionFeature {
  func handleCancel(_ state: inout State) -> Effect<Action> {
    state.isTranscribing = false
    state.isRecording = false
    state.isPrewarming = false
    state.isProcessingWithAgent = false
    state.agentModeActive = false
    state.capturedSelectedText = nil

    return .merge(
      .cancel(id: CancelID.transcription),
      .cancel(id: CancelID.agentProcessing),
      .run { [sleepManagement] _ in
        // Allow system to sleep again
        await sleepManagement.allowSleep()
        // Stop the recording to release microphone access
        let url = await recording.stopRecording()
        try? FileManager.default.removeItem(at: url)
        soundEffect.play(.cancel)
      }
    )
  }

  func handleDiscard(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    state.isPrewarming = false
    state.agentModeActive = false
    state.capturedSelectedText = nil

    // Silently discard - no sound effect
    return .run { [sleepManagement] _ in
      // Allow system to sleep again
      await sleepManagement.allowSleep()
      let url = await recording.stopRecording()
      try? FileManager.default.removeItem(at: url)
    }
  }
}

// MARK: - View

struct TranscriptionView: View {
  @Bindable var store: StoreOf<TranscriptionFeature>
  @ObserveInjection var inject

  var status: TranscriptionIndicatorView.Status {
    if store.isProcessingWithAgent {
      return .processingWithAgent
    } else if store.isTranscribing {
      return .transcribing
    } else if store.isRecording {
      return .recording
    } else if store.isPrewarming {
      return .prewarming
    } else {
      return .hidden
    }
  }

  var body: some View {
    TranscriptionIndicatorView(
      status: status,
      meter: store.meter
    )
    .task {
      await store.send(.task).finish()
    }
    .enableInjection()
  }
}

// MARK: - Force Quit Command

private enum ForceQuitCommandDetector {
  static func matches(_ text: String) -> Bool {
    let normalized = normalize(text)
    return normalized == "force quit hex now" || normalized == "force quit hex"
  }

  private static func normalize(_ text: String) -> String {
    text
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}
