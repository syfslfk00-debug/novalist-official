import Foundation

// iOS 18 compatibility bridge. The SpeechAnalyzer / SpeechTranscriber APIs
// used by NovalistSpeech.swift are iOS 26+ and must not be strongly linked
// into an iOS 18 app: dyld aborts before the MAUI entry point can start.
// Keep the C ABI stable while the older OS uses an unavailable status.
@_cdecl("nl_speech_request")
public func speechRequest(_ id: Int64, _ input: UnsafePointer<CChar>,
                          _ reply: @escaping @convention(c) (Int64, UnsafePointer<CChar>) -> Void) {
    let status = "{\"result\":{\"engine\":\"apple\",\"available\":false,\"online\":false,\"usesSystemPanel\":false,\"languages\":[{\"language\":\"en\",\"supported\":false,\"installed\":false},{\"language\":\"de\",\"supported\":false,\"installed\":false}]}}"
    let unavailable = "{\"error\":\"systemSpeechFailed\"}"
    let request = String(cString: input)
    let response = request.contains("\"status\"") ? status : unavailable
    response.withCString { reply(id, $0) }
}

@_cdecl("nl_speech_cancel")
public func speechCancel(_ id: Int64) {}
