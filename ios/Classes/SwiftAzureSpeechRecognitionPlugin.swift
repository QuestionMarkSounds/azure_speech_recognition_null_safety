import Flutter
import UIKit
import MicrosoftCognitiveServicesSpeech
import AVFoundation

@available(iOS 13.0, *)
struct SimpleRecognitionTask {
    var task: Task<Void, Never>
    var isCanceled: Bool
}

@available(iOS 13.0, *)
public class SwiftAzureSpeechRecognitionPlugin: NSObject, FlutterPlugin {
    var azureChannel: FlutterMethodChannel
    var continousListeningStarted: Bool = false
    var continousSpeechRecognizer: SPXSpeechRecognizer? = nil
    var simpleRecognitionTasks: Dictionary<String, SimpleRecognitionTask> = [:]

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "azure_speech_recognition", binaryMessenger: registrar.messenger())
        let instance: SwiftAzureSpeechRecognitionPlugin = SwiftAzureSpeechRecognitionPlugin(azureChannel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    init(azureChannel: FlutterMethodChannel) {
        self.azureChannel = azureChannel
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? Dictionary<String, Any>
        let speechSubscriptionKey = args?["subscriptionKey"] as? String ?? ""
        let serviceRegion = args?["region"] as? String ?? ""
        let lang = args?["language"] as? String ?? ""
        let langs = args?["languages"] as? [String] ?? ["en-US"]
        let timeoutMs = args?["timeout"] as? String ?? ""
        let referenceText = args?["referenceText"] as? String ?? ""
        let phonemeAlphabet = args?["phonemeAlphabet"] as? String ?? "IPA"
        let granularityString = args?["granularity"] as? String ?? "phoneme"
        let enableMiscue = args?["enableMiscue"] as? Bool ?? false
        let nBestPhonemeCount = args?["nBestPhonemeCount"] as? Int
        var granularity: SPXPronunciationAssessmentGranularity
        if (granularityString == "text") {
            granularity = SPXPronunciationAssessmentGranularity.fullText
        }
        else if (granularityString == "word") {
            granularity = SPXPronunciationAssessmentGranularity.word
        }
        else {
            granularity = SPXPronunciationAssessmentGranularity.phoneme
        }
        if (call.method == "simpleVoice") {
            print("Called simpleVoice")
            simpleSpeechRecognition(speechSubscriptionKey: speechSubscriptionKey, serviceRegion: serviceRegion, lang: lang, langs: langs, timeoutMs: timeoutMs)
            result(true)
        }
        else if (call.method == "simpleVoiceWithAssessment") {
            print("Called simpleVoiceWithAssessment")
            simpleSpeechRecognitionWithAssessment(referenceText: referenceText, phonemeAlphabet: phonemeAlphabet,  granularity: granularity, enableMiscue: enableMiscue, speechSubscriptionKey: speechSubscriptionKey, serviceRegion: serviceRegion, lang: lang, langs: langs, timeoutMs: timeoutMs, nBestPhonemeCount: nBestPhonemeCount)
            result(true)
        }
        else if (call.method == "isContinuousRecognitionOn") {
            print("Called isContinuousRecognitionOn: \(continousListeningStarted)")
            result(continousListeningStarted)
        }
        else if (call.method == "continuousStream") {
            print("Called continuousStream")
            continuousStream(speechSubscriptionKey: speechSubscriptionKey, serviceRegion: serviceRegion, lang: lang, langs: langs)
            result(true)
        }
        else if (call.method == "continuousStreamWithAssessment") {
            print("Called continuousStreamWithAssessment")
            continuousStreamWithAssessment(referenceText: referenceText, phonemeAlphabet: phonemeAlphabet,  granularity: granularity, enableMiscue: enableMiscue, speechSubscriptionKey: speechSubscriptionKey, serviceRegion: serviceRegion, lang: lang, langs: langs, nBestPhonemeCount: nBestPhonemeCount)
            result(true)
        }
        else if (call.method == "cancelSimpleVoice") {
            print("Called cancelSimpleVoice")
            cancelActiveSimpleRecognitionTasks()
            result(true)
        }
        else if (call.method == "stopContinuousStream") {
            stopContinuousStream(flutterResult: result)
        }
        else {
            result(FlutterMethodNotImplemented)
        }
    }



    private func cancelActiveSimpleRecognitionTasks() {
        print("Cancelling any active tasks")
        for taskId in simpleRecognitionTasks.keys {
            print("Cancelling task \(taskId)")
            simpleRecognitionTasks[taskId]?.task.cancel()
            simpleRecognitionTasks[taskId]?.isCanceled = true
        }
    }

    private func simpleSpeechRecognition(speechSubscriptionKey: String, serviceRegion: String, lang: String, langs: [String], timeoutMs: String) {
        print("Created new recognition task")
        cancelActiveSimpleRecognitionTasks()
        let taskId = UUID().uuidString

        let task = Task<Void, Never> { // Указываем явный тип Task
            print("Started recognition with task ID \(taskId)")
            var speechConfig: SPXSpeechConfiguration?

            do {
                let audioSession = AVAudioSession.sharedInstance()
                // Request access to the microphone
                try audioSession.setCategory(AVAudioSession.Category.record, mode: AVAudioSession.Mode.default, options: AVAudioSession.CategoryOptions.allowBluetooth)
                try audioSession.setActive(true)
                print("Setting custom audio session")
                // Initialize speech recognizer and specify correct subscription key and service region
                try speechConfig = SPXSpeechConfiguration(subscription: speechSubscriptionKey, region: serviceRegion)
            } catch {
                print("Error occurred during audio session configuration: \(error.localizedDescription)")
                speechConfig = nil
            }

            guard let config = speechConfig else {
                print("Speech configuration failed to initialize")
                return
            }

            config.speechRecognitionLanguage = lang
            config.setPropertyTo(timeoutMs, by: SPXPropertyId.speechSegmentationSilenceTimeoutMs)

            do {
                let audioConfig = SPXAudioConfiguration()
                let autoDetectLanguageConfig = try SPXAutoDetectSourceLanguageConfiguration(langs)
                let reco = try SPXSpeechRecognizer(speechConfiguration: config, autoDetectSourceLanguageConfiguration: autoDetectLanguageConfig, audioConfiguration: audioConfig)

                self.azureChannel.invokeMethod("speech.onRecognitionStarted", arguments: nil)

                reco.addRecognizingEventHandler { reco, evt in
                    if self.simpleRecognitionTasks[taskId]?.isCanceled ?? false { // Discard intermediate results if the task was cancelled
                        print("Ignoring partial result. TaskID: \(taskId)")
                    } else {
                        print("Intermediate result: \(evt.result.text ?? "(no result)")\nTaskID: \(taskId)")
                        self.azureChannel.invokeMethod("speech.onSpeech", arguments: evt.result.text)
                    }
                }

                let result = try await reco.recognizeOnce() // Используем await для асинхронной функции
                if Task.isCancelled {
                    print("Ignoring final result. TaskID: \(taskId)")
                } else {
                    print("Final result: \(result.text ?? "(no result)")\nReason: \(result.reason.rawValue)\nTaskID: \(taskId)")
                    if result.reason != SPXResultReason.recognizedSpeech {
                        let cancellationDetails = try SPXCancellationDetails(fromCanceledRecognitionResult: result)
                        print("Cancelled: \(cancellationDetails.description), \(cancellationDetails.errorDetails)\nTaskID: \(taskId)")
                        print("Did you set the speech resource key and region values?")
                        self.azureChannel.invokeMethod("speech.onFinalResponse", arguments: "")
                    } else {
                        self.azureChannel.invokeMethod("speech.onFinalResponse", arguments: result.text)
                    }
                }
            } catch {
                print("Error occurred during speech recognition: \(error.localizedDescription)")
                self.azureChannel.invokeMethod("speech.onFinalResponse", arguments: "")
            }

            self.simpleRecognitionTasks.removeValue(forKey: taskId)
        }

        simpleRecognitionTasks[taskId] = SimpleRecognitionTask(task: task, isCanceled: false)
    }

    private func simpleSpeechRecognitionWithAssessment(referenceText: String, phonemeAlphabet: String, granularity: SPXPronunciationAssessmentGranularity, enableMiscue: Bool, speechSubscriptionKey: String, serviceRegion: String, lang: String, langs: [String], timeoutMs: String, nBestPhonemeCount: Int?) {
        print("Created new recognition task")
        cancelActiveSimpleRecognitionTasks()
        let taskId = UUID().uuidString

        let task = Task<Void, Never> {
            print("Started recognition with task ID \(taskId)")
            var speechConfig: SPXSpeechConfiguration?
            var pronunciationAssessmentConfig: SPXPronunciationAssessmentConfiguration?

            do {
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(.record, mode: .default, options: .allowBluetooth)
                try audioSession.setActive(true)
                print("Setting custom audio session")

                speechConfig = try SPXSpeechConfiguration(subscription: speechSubscriptionKey, region: serviceRegion)
                pronunciationAssessmentConfig = try SPXPronunciationAssessmentConfiguration(
                    referenceText,
                    gradingSystem: .hundredMark,
                    granularity: granularity,
                    enableMiscue: enableMiscue
                )
            } catch {
                print("Error occurred during setup: \(error)")
                return
            }

            pronunciationAssessmentConfig?.phonemeAlphabet = phonemeAlphabet
            if let count = nBestPhonemeCount {
                pronunciationAssessmentConfig?.nbestPhonemeCount = count
            }

            speechConfig?.speechRecognitionLanguage = lang
            speechConfig?.setPropertyTo(timeoutMs, by: SPXPropertyId.speechSegmentationSilenceTimeoutMs)

            do {
                let audioConfig = SPXAudioConfiguration()
                let autoDetectLanguageConfig = try SPXAutoDetectSourceLanguageConfiguration(langs)
                let reco = try SPXSpeechRecognizer(
                    speechConfiguration: speechConfig!,
                    autoDetectSourceLanguageConfiguration: autoDetectLanguageConfig,
                    audioConfiguration: audioConfig
                )
                try pronunciationAssessmentConfig?.apply(to: reco)

                reco.addRecognizingEventHandler { reco, evt in
                    if self.simpleRecognitionTasks[taskId]?.isCanceled ?? false {
                        print("Ignoring partial result. TaskID: \(taskId)")
                    } else {
                        print("Intermediate result: \(evt.result.text ?? "(no result)")\nTaskID: \(taskId)")
                        self.azureChannel.invokeMethod("speech.onSpeech", arguments: evt.result.text)
                    }
                }

                let result = try reco.recognizeOnce()
                if Task.isCancelled {
                    print("Ignoring final result. TaskID: \(taskId)")
                } else {
                    print("Final result: \(result.text ?? "(no result)")\nReason: \(result.reason.rawValue)\nTaskID: \(taskId)")
                    let assessmentResultJson = result.properties?.getPropertyBy(SPXPropertyId.speechServiceResponseJsonResult)

                    if result.reason != .recognizedSpeech {
                        let cancellationDetails = try SPXCancellationDetails(fromCanceledRecognitionResult: result)
                        print("Cancelled: \(cancellationDetails.description), \(cancellationDetails.errorDetails)\nTaskID: \(taskId)")
                        self.azureChannel.invokeMethod("speech.onFinalResponse", arguments: "")
                        self.azureChannel.invokeMethod("speech.onAssessmentResult", arguments: "")
                    } else {
                        self.azureChannel.invokeMethod("speech.onFinalResponse", arguments: result.text)
                        self.azureChannel.invokeMethod("speech.onAssessmentResult", arguments: assessmentResultJson)
                    }
                }
            } catch {
                print("Error during recognition: \(error)")
            }

            self.simpleRecognitionTasks.removeValue(forKey: taskId)
        }

        simpleRecognitionTasks[taskId] = SimpleRecognitionTask(task: task, isCanceled: false)
    }

    private func stopContinuousStream(flutterResult: @escaping FlutterResult) {
        if (continousListeningStarted) {
            let resultHandler = flutterResult
            DispatchQueue.global(qos: .background).async {
                print("Stopping continous recognition")
                do {
                    try self.continousSpeechRecognizer?.stopContinuousRecognition()
                    DispatchQueue.main.async {
                        self.onContinuousRecognitionStopped()
                        resultHandler(true)
                    }
                } catch {
                    print("Error occurred stopping continous recognition")
                }
            }
        }
    }

    private func onContinuousRecognitionStopped() {
        self.azureChannel.invokeMethod("speech.onRecognitionStopped", arguments: nil)
        self.continousSpeechRecognizer = nil
        self.continousListeningStarted = false
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default)
            try audioSession.setActive(true)
            print("Audio session switched to playback")
        } catch {
            print("Failed to switch to playback mode: \(error.localizedDescription)")
        }
    }

    private func continuousStream(speechSubscriptionKey: String, serviceRegion: String, lang: String, langs: [String]) {
        if continousListeningStarted {
            print("Stopping continuous recognition")
            do {
                try continousSpeechRecognizer?.stopContinuousRecognition()
                self.onContinuousRecognitionStopped()
            } catch {
                print("Error occurred stopping continuous recognition: \(error.localizedDescription)")
            }
        } else {
            print("Starting continuous recognition")
            do {
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP, .mixWithOthers])
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
                print("Audio session successfully activated")
            } catch {
                print("An unexpected error occurred while setting up audio session: \(error.localizedDescription)")
                return
            }

            do {
                let speechConfig = try SPXSpeechConfiguration(subscription: speechSubscriptionKey, region: serviceRegion)
                speechConfig.speechRecognitionLanguage = lang

                // Set timeouts to ensure the recognizer doesn't stop prematurely
                // speechConfig.setPropertyTo("1000", by: .speechSegmentationSilenceTimeoutMs)
                speechConfig.setPropertyTo("15000", by: .speechServiceConnectionInitialSilenceTimeoutMs)

                let audioConfig = SPXAudioConfiguration()
                let autoDetectLanguageConfig = try SPXAutoDetectSourceLanguageConfiguration(langs)

                continousSpeechRecognizer = try SPXSpeechRecognizer(
                    speechConfiguration: speechConfig,
                    autoDetectSourceLanguageConfiguration: autoDetectLanguageConfig,
                    audioConfiguration: audioConfig
                )

                continousSpeechRecognizer?.addRecognizingEventHandler { reco, evt in
                    print("Intermediate recognition result: \(evt.result.text ?? "(no result)")")
                    self.azureChannel.invokeMethod("speech.onSpeech", arguments: evt.result.text)
                }

                continousSpeechRecognizer?.addRecognizedEventHandler { reco, evt in
                    if let res = evt.result.text {
                        print("Final result: \(res)")
                        self.azureChannel.invokeMethod("speech.onFinalResponse", arguments: res)
                    } else {
                        print("No text recognized.")
                    }
                }

                print("Listening...")
                try continousSpeechRecognizer?.startContinuousRecognition()
                self.azureChannel.invokeMethod("speech.onRecognitionStarted", arguments: nil)
                continousListeningStarted = true

            } catch {
                print("Error occurred while starting continuous recognition: \(error.localizedDescription)")
            }
        }
    }

    private func continuousStreamWithAssessment(referenceText: String, phonemeAlphabet: String, granularity: SPXPronunciationAssessmentGranularity, enableMiscue: Bool, speechSubscriptionKey : String, serviceRegion : String, lang: String, langs: [String], nBestPhonemeCount: Int?) {
        print("Continuous recognition started: \(continousListeningStarted)")
        if (continousListeningStarted) {
            print("Stopping continous recognition")
            do {
                try continousSpeechRecognizer!.stopContinuousRecognition()
                self.azureChannel.invokeMethod("speech.onRecognitionStopped", arguments: nil)
                continousSpeechRecognizer = nil
                continousListeningStarted = false
            }
            catch {
                print("Error occurred stopping continous recognition")
            }
        }
        else {
            print("Starting continous recognition")
            do {
                let audioSession = AVAudioSession.sharedInstance()
                // Request access to the microphone
                try audioSession.setCategory(AVAudioSession.Category.record, mode: AVAudioSession.Mode.default, options: AVAudioSession.CategoryOptions.allowBluetooth)
                try audioSession.setActive(true)
                print("Setting custom audio session")

                let speechConfig = try SPXSpeechConfiguration(subscription: speechSubscriptionKey, region: serviceRegion)
                speechConfig.speechRecognitionLanguage = lang

                let autoDetectLanguageConfig = try SPXAutoDetectSourceLanguageConfiguration.init(langs)

                let pronunciationAssessmentConfig = try SPXPronunciationAssessmentConfiguration.init(
                    referenceText,
                    gradingSystem: SPXPronunciationAssessmentGradingSystem.hundredMark,
                    granularity: granularity,
                    enableMiscue: enableMiscue)
                pronunciationAssessmentConfig.phonemeAlphabet = phonemeAlphabet

                if nBestPhonemeCount != nil {
                    pronunciationAssessmentConfig.nbestPhonemeCount = nBestPhonemeCount!
                }


                let audioConfig = SPXAudioConfiguration()

                continousSpeechRecognizer = try SPXSpeechRecognizer(speechConfiguration: speechConfig, autoDetectSourceLanguageConfiguration: autoDetectLanguageConfig, audioConfiguration: audioConfig)
                try pronunciationAssessmentConfig.apply(to: continousSpeechRecognizer!)

                continousSpeechRecognizer!.addRecognizingEventHandler() {reco, evt in
                    print("intermediate recognition result: \(evt.result.text ?? "(no result)")")
                    self.azureChannel.invokeMethod("speech.onSpeech", arguments: evt.result.text)
                }
                continousSpeechRecognizer!.addRecognizedEventHandler({reco, evt in
                    let result = evt.result
                    print("Final result: \(result.text ?? "(no result)")\nReason: \(result.reason.rawValue)")
                    let pronunciationAssessmentResultJson = result.properties?.getPropertyBy(SPXPropertyId.speechServiceResponseJsonResult)
                    print("pronunciationAssessmentResultJson: \(pronunciationAssessmentResultJson ?? "(no result)")")
                    self.azureChannel.invokeMethod("speech.onFinalResponse", arguments: result.text)
                    self.azureChannel.invokeMethod("speech.onAssessmentResult", arguments: pronunciationAssessmentResultJson)
                })
                print("Listening...")
                try continousSpeechRecognizer!.startContinuousRecognition()
                self.azureChannel.invokeMethod("speech.onRecognitionStarted", arguments: nil)
                continousListeningStarted = true
            }
            catch {
                print("An unexpected error occurred: \(error)")
            }
        }
    }
}
