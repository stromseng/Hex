//
//  AgentProcessingClient.swift
//  Hex
//
//  Created for Agent Processing feature (#136)
//

import AppKit
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import UniformTypeIdentifiers

private let agentLogger = HexLog.transcription

/// Input passed to the agent script via stdin as JSON
public struct AgentInput: Codable, Sendable {
	/// The transcribed text from voice recording
	public let transcript: String
	/// The selected text from the active application, if any was captured
	public let selectedText: String?

	public init(transcript: String, selectedText: String?) {
		self.transcript = transcript
		self.selectedText = selectedText
	}
}

/// Errors that can occur during agent processing
public enum AgentProcessingError: Error, LocalizedError {
	case scriptNotConfigured
	case scriptNotFound(String)
	case executionFailed(String)
	case timeout
	case invalidOutput

	public var errorDescription: String? {
		switch self {
		case .scriptNotConfigured:
			return "No agent script configured"
		case let .scriptNotFound(name):
			return "Agent script '\(name)' not found in Application Scripts folder"
		case let .executionFailed(message):
			return "Agent script failed: \(message)"
		case .timeout:
			return "Agent script timed out"
		case .invalidOutput:
			return "Agent script produced invalid output"
		}
	}
}

/// Bundled agent scripts that can be installed
enum BundledAgentScript: String, CaseIterable {
	case claudeCode = "claude-agent.sh"
	
	var displayName: String {
		switch self {
		case .claudeCode: return "Claude Code"
		}
	}
	
	var description: String {
		switch self {
		case .claudeCode: return "Send transcription to Claude Code CLI"
		}
	}
}

/// Client for executing user-configured agent scripts
@DependencyClient
struct AgentProcessingClient: Sendable {
	/// Process text through the user's configured agent script
	var process: @Sendable (_ input: AgentInput, _ scriptName: String) async throws -> String

	/// Get the Application Scripts directory URL
	var scriptsDirectoryURL: @Sendable () -> URL = { URL(fileURLWithPath: "/") }

	/// Check if a script exists in the Application Scripts directory
	var scriptExists: @Sendable (_ scriptName: String) -> Bool = { _ in false }
	
	/// List all scripts in the Application Scripts directory
	var listAvailableScripts: @Sendable () -> [String] = { [] }

	/// Reveal the Application Scripts folder in Finder, creating it if needed
	var revealScriptsFolder: @Sendable () async -> Void
	
	/// Install a bundled script to the Application Scripts directory
	var installBundledScript: @Sendable (_ script: BundledAgentScript) async throws -> Void
	
	/// List available bundled scripts
	var bundledScripts: @Sendable () -> [BundledAgentScript] = { BundledAgentScript.allCases }
}

extension AgentProcessingClient: DependencyKey {
	static let liveValue: AgentProcessingClient = {
		// Get the Application Scripts directory
		// This is the sandboxed location where NSUserUnixTask can execute scripts
		let scriptsDirectory: URL = {
			guard let url = FileManager.default.urls(
				for: .applicationScriptsDirectory,
				in: .userDomainMask
			).first else {
				// Fallback - should never happen
				return URL(fileURLWithPath: NSHomeDirectory())
					.appendingPathComponent("Library/Application Scripts/com.kitlangton.Hex")
			}
			return url
		}()

		return AgentProcessingClient(
			process: { input, scriptName in
				let scriptURL = scriptsDirectory.appendingPathComponent(scriptName)

				// Check if script exists
				guard FileManager.default.fileExists(atPath: scriptURL.path) else {
					agentLogger.error("Agent script not found: \(scriptURL.path, privacy: .private)")
					throw AgentProcessingError.scriptNotFound(scriptName)
				}

				agentLogger.info("Executing agent script: \(scriptName)")

				// Encode input as JSON
				let encoder = JSONEncoder()
				encoder.outputFormatting = [.sortedKeys]
				let inputData = try encoder.encode(input)

				// Create pipes for stdin/stdout/stderr
				let stdinPipe = Pipe()
				let stdoutPipe = Pipe()
				let stderrPipe = Pipe()

				// Use NSUserUnixTask for sandboxed execution
				let task: NSUserUnixTask
				do {
					task = try NSUserUnixTask(url: scriptURL)
				} catch {
					agentLogger.error("Failed to create NSUserUnixTask: \(error.localizedDescription)")
					throw AgentProcessingError.executionFailed("Failed to load script: \(error.localizedDescription)")
				}

				task.standardInput = stdinPipe.fileHandleForReading
				task.standardOutput = stdoutPipe.fileHandleForWriting
				task.standardError = stderrPipe.fileHandleForWriting

				// Write input to stdin
				stdinPipe.fileHandleForWriting.write(inputData)
				try stdinPipe.fileHandleForWriting.close()

				// Execute with timeout
				let timeoutSeconds: UInt64 = 60
				
				return try await withThrowingTaskGroup(of: String.self) { group in
					// Task to execute the script
					group.addTask {
						try await withCheckedThrowingContinuation { continuation in
							task.execute(withArguments: nil) { error in
								// Close write ends of pipes
								try? stdoutPipe.fileHandleForWriting.close()
								try? stderrPipe.fileHandleForWriting.close()

								if let error = error {
									// Read stderr for more info
									let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
									let stderrString = String(data: stderrData, encoding: .utf8) ?? ""
									agentLogger.error("Agent script failed: \(error.localizedDescription), stderr: \(stderrString, privacy: .private)")
									continuation.resume(throwing: AgentProcessingError.executionFailed(
										stderrString.isEmpty ? error.localizedDescription : stderrString
									))
									return
								}

								// Read stdout
								let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
								guard let output = String(data: stdoutData, encoding: .utf8) else {
									agentLogger.error("Agent script produced non-UTF8 output")
									continuation.resume(throwing: AgentProcessingError.invalidOutput)
									return
								}

								let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
								agentLogger.info("Agent script completed, output length: \(trimmedOutput.count)")
								continuation.resume(returning: trimmedOutput)
							}
						}
					}

					// Task for timeout
					group.addTask {
						try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
						throw AgentProcessingError.timeout
					}

					// Return first result (either success or timeout)
					guard let result = try await group.next() else {
						throw AgentProcessingError.executionFailed("Unexpected task group state")
					}
					
					// Cancel remaining tasks
					group.cancelAll()
					
					return result
				}
			},
			scriptsDirectoryURL: {
				scriptsDirectory
			},
			scriptExists: { scriptName in
				let scriptURL = scriptsDirectory.appendingPathComponent(scriptName)
				return FileManager.default.fileExists(atPath: scriptURL.path)
			},
			listAvailableScripts: {
				agentLogger.info("Listing scripts in: \(scriptsDirectory.path, privacy: .private)")
				guard FileManager.default.fileExists(atPath: scriptsDirectory.path) else {
					agentLogger.info("Scripts directory does not exist")
					return []
				}
				do {
					let contents = try FileManager.default.contentsOfDirectory(
						at: scriptsDirectory,
						includingPropertiesForKeys: [.isRegularFileKey],
						options: [.skipsHiddenFiles]
					)
					agentLogger.info("Found \(contents.count) items in scripts directory")
					let scripts = contents
						.filter { url in
							// Include shell scripts and any executable files
							let ext = url.pathExtension.lowercased()
							let isScript = ext == "sh" || ext == "bash" || ext == "zsh" || ext == "py" || ext == ""
							// Also check if it's a regular file
							let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey])
							let isFile = resourceValues?.isRegularFile == true
							return isFile && (isScript || ext.isEmpty)
						}
						.map { $0.lastPathComponent }
						.sorted()
					agentLogger.info("Filtered to \(scripts.count) scripts: \(scripts)")
					return scripts
				} catch {
					agentLogger.error("Failed to list scripts: \(error.localizedDescription)")
					return []
				}
			},
			revealScriptsFolder: {
				// Create directory if it doesn't exist
				if !FileManager.default.fileExists(atPath: scriptsDirectory.path) {
					try? FileManager.default.createDirectory(
						at: scriptsDirectory,
						withIntermediateDirectories: true
					)
				}
				
				await MainActor.run {
					NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: scriptsDirectory.path)
				}
			},
			installBundledScript: { script in
				// Find the bundled script in the app bundle
				// Try multiple locations since Xcode may place resources differently
				let resourceName = script.rawValue.replacingOccurrences(of: ".sh", with: "")
				var bundledURL: URL?
				
				// Try with subdirectory first
				bundledURL = Bundle.main.url(
					forResource: resourceName,
					withExtension: "sh",
					subdirectory: "Scripts"
				)
				
				// Try without subdirectory
				if bundledURL == nil {
					bundledURL = Bundle.main.url(
						forResource: resourceName,
						withExtension: "sh"
					)
				}
				
				// Try looking in Resources/Scripts
				if bundledURL == nil {
					bundledURL = Bundle.main.url(
						forResource: resourceName,
						withExtension: "sh",
						subdirectory: "Resources/Scripts"
					)
				}
				
				guard let sourceURL = bundledURL else {
					agentLogger.error("Bundled script not found in app bundle: \(script.rawValue). Bundle path: \(Bundle.main.bundlePath)")
					// Log what's in the bundle for debugging
					if let resourcePath = Bundle.main.resourcePath {
						let contents = try? FileManager.default.contentsOfDirectory(atPath: resourcePath)
						agentLogger.error("Bundle resources: \(contents ?? [])")
					}
					throw AgentProcessingError.scriptNotFound(script.rawValue)
				}
				
				agentLogger.info("Found bundled script at: \(sourceURL.path, privacy: .private)")
				
				// For sandboxed apps, we need user permission to write to Application Scripts.
				// Use NSSavePanel to get write access to the destination.
				let destinationURL: URL? = await MainActor.run {
					let savePanel = NSSavePanel()
					savePanel.title = "Install Agent Script"
					savePanel.message = "Choose where to save the agent script. The default location is required for Hex to run it."
					savePanel.nameFieldStringValue = script.rawValue
					savePanel.directoryURL = scriptsDirectory
					savePanel.canCreateDirectories = true
					savePanel.allowedContentTypes = [.shellScript, .unixExecutable]
					
					// Pre-create the directory structure if possible
					try? FileManager.default.createDirectory(
						at: scriptsDirectory,
						withIntermediateDirectories: true
					)
					
					let response = savePanel.runModal()
					if response == .OK {
						return savePanel.url
					}
					return nil
				}
				
				guard let destURL = destinationURL else {
					throw AgentProcessingError.executionFailed("Installation cancelled by user")
				}
				
				// Remove existing script if present
				if FileManager.default.fileExists(atPath: destURL.path) {
					try FileManager.default.removeItem(at: destURL)
				}
				
				// Copy the script
				try FileManager.default.copyItem(at: sourceURL, to: destURL)
				
				// Make it executable
				try FileManager.default.setAttributes(
					[.posixPermissions: 0o755],
					ofItemAtPath: destURL.path
				)
				
				agentLogger.info("Installed bundled script to: \(destURL.path, privacy: .private)")
			},
			bundledScripts: {
				BundledAgentScript.allCases
			}
		)
	}()

	static let testValue = AgentProcessingClient()
}

extension DependencyValues {
	var agentProcessing: AgentProcessingClient {
		get { self[AgentProcessingClient.self] }
		set { self[AgentProcessingClient.self] = newValue }
	}
}
