import XCTest
@testable import DevFlow

final class WorkGraphBridgeResolverTests: XCTestCase {
    func testConnectsLiteralDartCallToUniqueSwiftHandlerThroughBridgeNode() {
        let dart = """
        func fetchBattery() {
          MethodChannel('sample.battery').invokeMethod('getBatteryLevel')
        }
        """
        let swift = """
        func configureFlutter() {
          let channel = FlutterMethodChannel(name: "sample.battery", binaryMessenger: messenger)
          channel.setMethodCallHandler { call, result in
            switch call.method {
            case "getBatteryLevel":
              result(100)
            default:
              result(nil)
            }
          }
        }
        """
        let snapshot = makeSnapshot(nodes: [
            function("dart.fetchBattery", path: "lib/battery.dart", language: .dart, start: 1, end: 3),
            function("ios.configureFlutter", path: "ios/AppDelegate.swift", language: .swift, start: 1, end: 10)
        ])

        let result = WorkGraphBridgeResolver().resolve(snapshot: snapshot, sources: [
            source(path: "lib/battery.dart", language: .dart, content: dart),
            source(path: "ios/AppDelegate.swift", language: .swift, content: swift)
        ])

        let handler = try! XCTUnwrap(result.nodes.single)
        XCTAssertEqual(handler.kind, .bridgeHandler)
        XCTAssertEqual(handler.name, "sample.battery.getBatteryLevel")
        XCTAssertEqual(handler.parentID, "ios.configureFlutter")
        XCTAssertEqual(result.edges.count, 2)
        XCTAssertEqual(result.edges.map(\.kind), [.bridgeInvokes, .bridgeInvokes])
        XCTAssertTrue(result.edges.allSatisfy { $0.provenance == .bridgeResolver && $0.confidence == 0.99 })
        XCTAssertTrue(result.edges.contains { $0.sourceID == "dart.fetchBattery" && $0.targetID == handler.id })
        XCTAssertTrue(result.edges.contains { $0.sourceID == handler.id && $0.targetID == "ios.configureFlutter" })
    }

    func testRecognizesObjectiveCKotlinAndJavaHandlersWithTheirOwnLiteralChannels() {
        let dart = """
        func objcCall() { MethodChannel('objc.channel').invokeMethod('open') }
        func kotlinCall() { MethodChannel('kotlin.channel').invokeMethod('load') }
        func javaCall() { MethodChannel('java.channel').invokeMethod('save') }
        """
        let objectiveC = """
        void configureObjc(void) {
          FlutterMethodChannel *channel = [FlutterMethodChannel methodChannelWithName:@"objc.channel" binaryMessenger:messenger];
          [channel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
            if ([call.method isEqualToString:@"open"]) { result(@YES); }
          }];
        }
        """
        let kotlin = """
        fun configureKotlin() {
          val channel = MethodChannel(messenger, "kotlin.channel")
          channel.setMethodCallHandler { call, result ->
            when (call.method) {
              "load" -> result.success(true)
              else -> result.notImplemented()
            }
          }
        }
        """
        let java = """
        void configureJava() {
          MethodChannel channel = new MethodChannel(messenger, "java.channel");
          channel.setMethodCallHandler((call, result) -> {
            switch (call.method) {
              case "save": result.success(true); break;
              default: result.notImplemented();
            }
          });
        }
        """
        let snapshot = makeSnapshot(nodes: [
            function("dart.objcCall", path: "lib/channels.dart", language: .dart, start: 1, end: 1),
            function("dart.kotlinCall", path: "lib/channels.dart", language: .dart, start: 2, end: 2),
            function("dart.javaCall", path: "lib/channels.dart", language: .dart, start: 3, end: 3),
            function("ios.configureObjc", path: "ios/Plugin.m", language: .objectiveC, start: 1, end: 6),
            function("android.configureKotlin", path: "android/Plugin.kt", language: .kotlin, start: 1, end: 9),
            function("android.configureJava", path: "android/Plugin.java", language: .java, start: 1, end: 10)
        ])

        let result = WorkGraphBridgeResolver().resolve(snapshot: snapshot, sources: [
            source(path: "lib/channels.dart", language: .dart, content: dart),
            source(path: "ios/Plugin.m", language: .objectiveC, content: objectiveC),
            source(path: "android/Plugin.kt", language: .kotlin, content: kotlin),
            source(path: "android/Plugin.java", language: .java, content: java)
        ])

        XCTAssertEqual(Set(result.nodes.map(\.name)), ["objc.channel.open", "kotlin.channel.load", "java.channel.save"])
        XCTAssertEqual(result.edges.count, 6)
        XCTAssertTrue(result.edges.contains { $0.sourceID == "dart.objcCall" && $0.metadataJSON?.contains("objc.channel") == true })
        XCTAssertTrue(result.edges.contains { $0.sourceID == "dart.kotlinCall" && $0.metadataJSON?.contains("kotlin.channel") == true })
        XCTAssertTrue(result.edges.contains { $0.sourceID == "dart.javaCall" && $0.metadataJSON?.contains("java.channel") == true })
    }

    func testRejectsAmbiguousHandlersForTheSamePlatformContract() {
        let dart = "func request() { MethodChannel('sample').invokeMethod('load') }"
        let first = """
        func firstHandler() {
          let channel = FlutterMethodChannel(name: "sample", binaryMessenger: messenger)
          channel.setMethodCallHandler { call, result in
            switch call.method { case "load": result(true); default: result(nil) }
          }
        }
        """
        let second = first.replacingOccurrences(of: "firstHandler", with: "secondHandler")
        let snapshot = makeSnapshot(nodes: [
            function("dart.request", path: "lib/app.dart", language: .dart, start: 1, end: 1),
            function("ios.first", path: "ios/First.swift", language: .swift, start: 1, end: 6),
            function("ios.second", path: "ios/Second.swift", language: .swift, start: 1, end: 6)
        ])

        let result = WorkGraphBridgeResolver().resolve(snapshot: snapshot, sources: [
            source(path: "lib/app.dart", language: .dart, content: dart),
            source(path: "ios/First.swift", language: .swift, content: first),
            source(path: "ios/Second.swift", language: .swift, content: second)
        ])

        XCTAssertTrue(result.nodes.isEmpty)
        XCTAssertTrue(result.edges.isEmpty)
    }

    func testRejectsDynamicDartChannelAndArkTSLookalike() {
        let dart = """
        func dynamicRequest() {
          let channelName = 'sample'
          MethodChannel(channelName).invokeMethod('load')
        }
        """
        let arkTS = """
        function nativeHandler() {
          const channel = MethodChannel(messenger, "sample")
          channel.setMethodCallHandler((call: MethodCall) => {
            if (call.method == "load") { return true }
          })
        }
        """
        let snapshot = makeSnapshot(nodes: [
            function("dart.dynamic", path: "lib/app.dart", language: .dart, start: 1, end: 4),
            function("ohos.handler", path: "entry/Plugin.ets", language: .arkTS, start: 1, end: 6)
        ])

        let result = WorkGraphBridgeResolver().resolve(snapshot: snapshot, sources: [
            source(path: "lib/app.dart", language: .dart, content: dart),
            source(path: "entry/Plugin.ets", language: .arkTS, content: arkTS)
        ])

        XCTAssertTrue(result.nodes.isEmpty)
        XCTAssertTrue(result.edges.isEmpty)
    }

    func testDoesNotTreatCommentedDartCodeAsABridgeContract() {
        let dart = """
        func request() {
          // MethodChannel('sample').invokeMethod('load')
        }
        """
        let swift = """
        func nativeHandler() {
          let channel = FlutterMethodChannel(name: "sample", binaryMessenger: messenger)
          channel.setMethodCallHandler { call, result in
            switch call.method { case "load": result(true); default: result(nil) }
          }
        }
        """
        let snapshot = makeSnapshot(nodes: [
            function("dart.request", path: "lib/app.dart", language: .dart, start: 1, end: 3),
            function("ios.handler", path: "ios/App.swift", language: .swift, start: 1, end: 6)
        ])

        let result = WorkGraphBridgeResolver().resolve(snapshot: snapshot, sources: [
            source(path: "lib/app.dart", language: .dart, content: dart),
            source(path: "ios/App.swift", language: .swift, content: swift)
        ])

        XCTAssertTrue(result.nodes.isEmpty)
        XCTAssertTrue(result.edges.isEmpty)
    }

    func testDoesNotTreatDartStringContentAsABridgeContract() {
        let dart = """
        func request() {
          let example = "MethodChannel('sample').invokeMethod('load')"
          print(example)
        }
        """
        let swift = """
        func nativeHandler() {
          let channel = FlutterMethodChannel(name: "sample", binaryMessenger: messenger)
          channel.setMethodCallHandler { call, result in
            switch call.method { case "load": result(true); default: result(nil) }
          }
        }
        """
        let snapshot = makeSnapshot(nodes: [
            function("dart.request", path: "lib/app.dart", language: .dart, start: 1, end: 4),
            function("ios.handler", path: "ios/App.swift", language: .swift, start: 1, end: 6)
        ])

        let result = WorkGraphBridgeResolver().resolve(snapshot: snapshot, sources: [
            source(path: "lib/app.dart", language: .dart, content: dart),
            source(path: "ios/App.swift", language: .swift, content: swift)
        ])

        XCTAssertTrue(result.nodes.isEmpty)
        XCTAssertTrue(result.edges.isEmpty)
    }

    func testDoesNotMatchTheSameMethodOnADifferentChannel() {
        let dart = "func request() { MethodChannel('first').invokeMethod('load') }"
        let swift = """
        func nativeHandler() {
          let channel = FlutterMethodChannel(name: "second", binaryMessenger: messenger)
          channel.setMethodCallHandler { call, result in
            switch call.method { case "load": result(true); default: result(nil) }
          }
        }
        """
        let snapshot = makeSnapshot(nodes: [
            function("dart.request", path: "lib/app.dart", language: .dart, start: 1, end: 1),
            function("ios.handler", path: "ios/App.swift", language: .swift, start: 1, end: 6)
        ])

        let result = WorkGraphBridgeResolver().resolve(snapshot: snapshot, sources: [
            source(path: "lib/app.dart", language: .dart, content: dart),
            source(path: "ios/App.swift", language: .swift, content: swift)
        ])

        XCTAssertTrue(result.nodes.isEmpty)
        XCTAssertTrue(result.edges.isEmpty)
    }

    private func makeSnapshot(nodes: [WorkGraphNodeDraft]) -> WorkGraphIndexSnapshot {
        WorkGraphIndexSnapshot(files: [], nodes: nodes, edges: [], references: [], documents: [])
    }

    private func function(
        _ id: String,
        path: String,
        language: WorkGraphLanguage,
        start: Int,
        end: Int
    ) -> WorkGraphNodeDraft {
        WorkGraphNodeDraft(
            id: id,
            parentID: nil,
            kind: .function,
            name: id,
            qualifiedName: id,
            filePath: path,
            language: language,
            location: WorkGraphSourceLocation(startLine: start, endLine: end, startColumn: 0, endColumn: 0),
            signature: nil,
            visibility: nil,
            isExported: false,
            isAsync: false,
            isStatic: false,
            isAbstract: false,
            returnType: nil,
            decorators: []
        )
    }

    private func source(path: String, language: WorkGraphLanguage, content: String) -> WorkGraphSourceFile {
        WorkGraphSourceFile(
            record: WorkGraphFileRecord(
                path: path,
                contentHash: "test:\(path)",
                language: language,
                byteCount: content.lengthOfBytes(using: .utf8),
                modifiedAt: nil,
                isGenerated: false,
                diagnostics: []
            ),
            source: content
        )
    }
}

private extension Array where Element == WorkGraphNodeDraft {
    var single: WorkGraphNodeDraft? {
        count == 1 ? first : nil
    }
}
