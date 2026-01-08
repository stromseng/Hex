import AVFoundation
import AppKit
import ComposableArchitecture
import Dependencies
import HexCore
import IdentifiedCollections
import Sauce
import ServiceManagement
import SwiftUI

private let settingsLogger = HexLog.settings

extension SharedReaderKey
  where Self == InMemoryKey<Bool>.Default
{
  static var isSettingHotKey: Self {
    Self[.inMemory("isSettingHotKey"), default: false]
  }
  
  static var isSettingPasteLastTranscriptHotkey: Self {
    Self[.inMemory("isSettingPasteLastTranscriptHotkey"), default: false]
  }

  static var isRemappingScratchpadFocused: Self {
    Self[.inMemory("isRemappingScratchpadFocused"), default: false]
  }
}

// MARK: - Settings Feature

@Reducer
struct SettingsFeature {
  @ObservableState
  struct State {
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isSettingHotKey) var isSettingHotKey: Bool = false
    @Shared(.isSettingPasteLastTranscriptHotkey) var isSettingPasteLastTranscriptHotkey: Bool = false
    @Shared(.isRemappingScratchpadFocused) var isRemappingScratchpadFocused: Bool = false
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
    @Shared(.hotkeyPermissionState) var hotkeyPermissionState: HotkeyPermissionState

    var languages: IdentifiedArrayOf<Language> = []
    var currentModifiers: Modifiers = .init(modifiers: [])
    var currentPasteLastModifiers: Modifiers = .init(modifiers: [])
    var remappingScratchpadText: String = ""
    
    // Available microphones
    var availableInputDevices: [AudioInputDevice] = []
    var defaultInputDeviceName: String?

    // Model Management
    var modelDownload = ModelDownloadFeature.State()
    var shouldFlashModelSection = false

    // Diagnostics
    var isExportingLogs = false
    var logExportStatus: LogExportStatus?
    
    // Agent script status
    var agentScriptExists: Bool = false
    var availableAgentScripts: [String] = []
    var scriptInstallStatus: ScriptInstallStatus?
    var isInstallingScript: Bool = false
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)

    // Existing
    case task
    case startSettingHotKey
    case startSettingPasteLastTranscriptHotkey
    case clearPasteLastTranscriptHotkey
    case keyEvent(KeyEvent)
    case toggleOpenOnLogin(Bool)
    case togglePreventSystemSleep(Bool)
    case setRecordingAudioBehavior(RecordingAudioBehavior)

    // Permission delegation (forwarded to AppFeature)
    case requestMicrophone
    case requestAccessibility
    case requestInputMonitoring

    // Microphone selection
    case loadAvailableInputDevices
    case availableInputDevicesLoaded([AudioInputDevice], String?)

    // Model Management
    case modelDownload(ModelDownloadFeature.Action)
    
    // History Management
    case toggleSaveTranscriptionHistory(Bool)

    // Modifier configuration
    case setModifierSide(Modifier.Kind, Modifier.Side)

    // Diagnostics
    case exportLogsButtonTapped
    case logExportFinished(URL)
    case logExportFailed(String)
    case logExportCancelled

    // Word remappings
    case addWordRemapping
    case removeWordRemapping(UUID)
    case setRemappingScratchpadFocused(Bool)
    
    // Agent settings
    case setAgentScriptName(String?)
    case revealAgentScriptsFolder
    case checkAgentScriptExists
    case loadAvailableAgentScripts
    case availableAgentScriptsLoaded([String])
    case installBundledScript(BundledAgentScript)
    case bundledScriptInstalled(BundledAgentScript)
    case bundledScriptInstallFailed(String)
  }

  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.continuousClock) var clock
  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.permissions) var permissions
  @Dependency(\.logExporter) var logExporter
  @Dependency(\.agentProcessing) var agentProcessing

  var body: some ReducerOf<Self> {
    BindingReducer()

    Scope(state: \.modelDownload, action: \.modelDownload) {
      ModelDownloadFeature()
    }

    Reduce { state, action in
      switch action {
      case .binding:
        return .run { _ in
          await MainActor.run {
            NotificationCenter.default.post(name: .updateAppMode, object: nil)
          }
        }

      case .task:
        if let url = Bundle.main.url(forResource: "languages", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let languages = try? JSONDecoder().decode([Language].self, from: data)
        {
          state.languages = IdentifiedArray(uniqueElements: languages)
        } else {
          settingsLogger.error("Failed to load languages JSON from bundle")
        }
        
        // Check agent script exists on load
        if let scriptName = state.hexSettings.agentScriptName, !scriptName.isEmpty {
          state.agentScriptExists = agentProcessing.scriptExists(scriptName)
        }
        
        // Load available agent scripts
        state.availableAgentScripts = agentProcessing.listAvailableScripts()

        // Listen for key events and load microphones (existing + new)
        return .run { send in
          await send(.modelDownload(.fetchModels))
          await send(.loadAvailableInputDevices)
          
          // Set up periodic refresh of available devices (every 120 seconds)
          // Using a longer interval to reduce resource usage
          let deviceRefreshTask = Task { @MainActor in
            for await _ in clock.timer(interval: .seconds(120)) {
              // Only refresh when the app is active to save resources
              if NSApplication.shared.isActive {
                send(.loadAvailableInputDevices)
              }
            }
          }
          
          // Listen for device connection/disconnection notifications
          // Using a simpler debounced approach with a single task
          var deviceUpdateTask: Task<Void, Never>?
          
          // Helper function to debounce device updates
          func debounceDeviceUpdate() {
            deviceUpdateTask?.cancel()
            deviceUpdateTask = Task {
              try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
              if !Task.isCancelled {
                await send(.loadAvailableInputDevices)
              }
            }
          }
          
          let deviceConnectionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "AVCaptureDeviceWasConnected"),
            object: nil,
            queue: .main
          ) { _ in
            debounceDeviceUpdate()
          }
          
          let deviceDisconnectionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "AVCaptureDeviceWasDisconnected"),
            object: nil,
            queue: .main
          ) { _ in
            debounceDeviceUpdate()
          }
          
          // Be sure to clean up resources when the task is finished
          defer {
            deviceUpdateTask?.cancel()
            NotificationCenter.default.removeObserver(deviceConnectionObserver)
            NotificationCenter.default.removeObserver(deviceDisconnectionObserver)
          }

          for try await keyEvent in await keyEventMonitor.listenForKeyPress() {
            await send(.keyEvent(keyEvent))
          }
          
          deviceRefreshTask.cancel()
        }

      case .startSettingHotKey:
        state.$isSettingHotKey.withLock { $0 = true }
        return .none

      case .addWordRemapping:
        state.$hexSettings.withLock {
          $0.wordRemappings.append(.init(match: "", replacement: ""))
        }
        return .none

      case let .removeWordRemapping(id):
        state.$hexSettings.withLock {
          $0.wordRemappings.removeAll { $0.id == id }
        }
        return .none

      case let .setRemappingScratchpadFocused(isFocused):
        state.$isRemappingScratchpadFocused.withLock { $0 = isFocused }
        return .none

      case .startSettingPasteLastTranscriptHotkey:
        state.$isSettingPasteLastTranscriptHotkey.withLock { $0 = true }
        state.currentPasteLastModifiers = .init(modifiers: [])
        return .none
        
      case .clearPasteLastTranscriptHotkey:
        state.$hexSettings.withLock { $0.pasteLastTranscriptHotkey = nil }
        return .none

      case let .keyEvent(keyEvent):
        // Handle paste last transcript hotkey setting
        if state.isSettingPasteLastTranscriptHotkey {
          if keyEvent.key == .escape {
            state.$isSettingPasteLastTranscriptHotkey.withLock { $0 = false }
            state.currentPasteLastModifiers = []
            return .none
          }

          state.currentPasteLastModifiers = keyEvent.modifiers.union(state.currentPasteLastModifiers)
          let currentModifiers = state.currentPasteLastModifiers
          if let key = keyEvent.key {
            guard !currentModifiers.isEmpty else {
              return .none
            }
            state.$hexSettings.withLock {
              $0.pasteLastTranscriptHotkey = HotKey(key: key, modifiers: currentModifiers.erasingSides())
            }
            state.$isSettingPasteLastTranscriptHotkey.withLock { $0 = false }
            state.currentPasteLastModifiers = []
          }
          return .none
        }
        
        // Handle main recording hotkey setting
        guard state.isSettingHotKey else { return .none }

        if keyEvent.key == .escape {
          state.$isSettingHotKey.withLock { $0 = false }
          state.currentModifiers = []
          return .none
        }

        state.currentModifiers = keyEvent.modifiers.union(state.currentModifiers)
        let currentModifiers = state.currentModifiers
        if let key = keyEvent.key {
          state.$hexSettings.withLock {
            $0.hotkey.key = key
            $0.hotkey.modifiers = currentModifiers.erasingSides()
          }
          state.$isSettingHotKey.withLock { $0 = false }
          state.currentModifiers = []
        } else if keyEvent.modifiers.isEmpty {
          state.$hexSettings.withLock {
            $0.hotkey.key = nil
            $0.hotkey.modifiers = currentModifiers.erasingSides()
          }
          state.$isSettingHotKey.withLock { $0 = false }
          state.currentModifiers = []
        }
        return .none

      case let .toggleOpenOnLogin(enabled):
        state.$hexSettings.withLock { $0.openOnLogin = enabled }
        return .run { _ in
          if enabled {
            try? SMAppService.mainApp.register()
          } else {
            try? SMAppService.mainApp.unregister()
          }
        }

      case let .togglePreventSystemSleep(enabled):
        state.$hexSettings.withLock { $0.preventSystemSleep = enabled }
        return .none

      case let .setRecordingAudioBehavior(behavior):
        state.$hexSettings.withLock { $0.recordingAudioBehavior = behavior }
        return .none

      // Permission requests
      case .requestMicrophone:
        settingsLogger.info("User requested microphone permission from settings")
        return .run { _ in
          _ = await permissions.requestMicrophone()
        }

      case .requestAccessibility:
        settingsLogger.info("User requested accessibility permission from settings")
        return .run { _ in
          await permissions.requestAccessibility()
        }

      case .requestInputMonitoring:
        settingsLogger.info("User requested input monitoring permission from settings")
        return .run { _ in
          _ = await permissions.requestInputMonitoring()
        }

      // Model Management
      case let .modelDownload(.selectModel(newModel)):
        // Also store it in hexSettings:
        state.$hexSettings.withLock {
          $0.selectedModel = newModel
        }
        // Then continue with the child's normal logic:
        return .none

      case .modelDownload:
        return .none
      
      // Microphone device selection
      case .loadAvailableInputDevices:
        return .run { send in
          let devices = await recording.getAvailableInputDevices()
          let defaultName = await recording.getDefaultInputDeviceName()
          await send(.availableInputDevicesLoaded(devices, defaultName))
        }
        
      case let .availableInputDevicesLoaded(devices, defaultName):
        state.availableInputDevices = devices
        state.defaultInputDeviceName = defaultName
        return .none
        
      case let .toggleSaveTranscriptionHistory(enabled):
        state.$hexSettings.withLock { $0.saveTranscriptionHistory = enabled }
        
        // If disabling history, delete all existing entries
        if !enabled {
          let transcripts = state.transcriptionHistory.history
          
          // Clear the history
          state.$transcriptionHistory.withLock { history in
            history.history.removeAll()
          }
          
          // Delete all audio files
          return .run { _ in
            for transcript in transcripts {
              try? FileManager.default.removeItem(at: transcript.audioPath)
            }
          }
        }
        
        return .none

      case let .setModifierSide(kind, side):
        guard state.hexSettings.hotkey.key == nil else { return .none }
        state.$hexSettings.withLock {
          $0.hotkey.modifiers = $0.hotkey.modifiers.setting(kind: kind, to: side)
        }
        return .none

      case .exportLogsButtonTapped:
        guard !state.isExportingLogs else { return .none }
        state.isExportingLogs = true
        state.logExportStatus = nil
        return .run { send in
          do {
            if let url = try await logExporter.exportLogs(30) {
              await send(.logExportFinished(url))
            } else {
              await send(.logExportCancelled)
            }
          } catch {
            await send(.logExportFailed(error.localizedDescription))
          }
        }

      case let .logExportFinished(url):
        state.isExportingLogs = false
        state.logExportStatus = .success(url.path)
        return .run { _ in
          await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting([url])
          }
        }

      case .logExportCancelled:
        state.isExportingLogs = false
        return .none

      case let .logExportFailed(message):
        state.isExportingLogs = false
        state.logExportStatus = .failure(message)
        return .none
      
      // MARK: - Agent Settings
      
      case let .setAgentScriptName(name):
        state.$hexSettings.withLock { $0.agentScriptName = name }
        // Check if script exists after setting name
        if let scriptName = name, !scriptName.isEmpty {
          state.agentScriptExists = agentProcessing.scriptExists(scriptName)
        } else {
          state.agentScriptExists = false
        }
        return .none
      
      case .revealAgentScriptsFolder:
        return .run { [agentProcessing] _ in
          await agentProcessing.revealScriptsFolder()
        }
      
      case .checkAgentScriptExists:
        if let scriptName = state.hexSettings.agentScriptName, !scriptName.isEmpty {
          state.agentScriptExists = agentProcessing.scriptExists(scriptName)
        } else {
          state.agentScriptExists = false
        }
        return .none
      
      case .loadAvailableAgentScripts:
        state.availableAgentScripts = agentProcessing.listAvailableScripts()
        return .none
      
      case let .availableAgentScriptsLoaded(scripts):
        state.availableAgentScripts = scripts
        return .none
      
      case let .installBundledScript(script):
        guard !state.isInstallingScript else { return .none }
        state.isInstallingScript = true
        state.scriptInstallStatus = nil
        return .run { send in
          do {
            try await agentProcessing.installBundledScript(script)
            await send(.bundledScriptInstalled(script))
          } catch {
            await send(.bundledScriptInstallFailed(error.localizedDescription))
          }
        }
      
      case let .bundledScriptInstalled(script):
        state.isInstallingScript = false
        state.scriptInstallStatus = .success("Installed \(script.displayName)")
        // Set the script name to the installed script and refresh script list
        state.$hexSettings.withLock { $0.agentScriptName = script.rawValue }
        state.agentScriptExists = true
        state.availableAgentScripts = agentProcessing.listAvailableScripts()
        return .none
      
      case let .bundledScriptInstallFailed(message):
        state.isInstallingScript = false
        state.scriptInstallStatus = .failure(message)
        settingsLogger.error("Failed to install bundled script: \(message)")
        return .none
      }
    }
  }
}

extension SettingsFeature.State {
  enum LogExportStatus: Equatable {
    case success(String)
    case failure(String)
  }
  
  enum ScriptInstallStatus: Equatable {
    case success(String)
    case failure(String)
  }
}
