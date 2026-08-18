import Foundation

enum WorkGraphLanguage: String, Codable, CaseIterable {
    case dart
    case swift
    case objectiveC = "objective-c"
    case kotlin
    case java
    case c
    case cpp
    case arkTS = "arkts"
    case unknown

    init(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "dart": self = .dart
        case "swift": self = .swift
        case "m", "mm": self = .objectiveC
        case "kt", "kts": self = .kotlin
        case "java": self = .java
        case "c", "h": self = .c
        case "cc", "cpp", "cxx", "hpp", "hh": self = .cpp
        case "ets": self = .arkTS
        default: self = .unknown
        }
    }

    var supportsSemanticExtraction: Bool {
        self != .unknown
    }
}

enum WorkGraphNodeKind: String, Codable {
    case file
    case module
    case `class`
    case `struct`
    case `interface`
    case `protocol`
    case function
    case method
    case property
    case field
    case variable
    case constant
    case enumeration = "enum"
    case enumMember = "enum_member"
    case typeAlias = "type_alias"
    case namespace
    case parameter
    case route
    case component
    case bridgeHandler = "bridge_handler"
    case unknown
}

enum WorkGraphEdgeKind: String, Codable {
    case contains
    case calls
    case imports
    case exports
    case extends
    case implements
    case references
    case typeOf = "type_of"
    case returns
    case instantiates
    case overrides
    case decorates
    case bridgeInvokes = "bridge_invokes"
}

enum WorkGraphReferenceStatus: String, Codable {
    case pending
    case resolved
    case ambiguous
    case failed
}

enum WorkGraphEdgeProvenance: String, Codable {
    case ast
    case resolver
    case bridgeResolver = "bridge_resolver"
}

struct WorkGraphSourceLocation: Codable, Hashable {
    var startLine: Int
    var endLine: Int
    var startColumn: Int
    var endColumn: Int

    static let unknown = WorkGraphSourceLocation(startLine: 1, endLine: 1, startColumn: 0, endColumn: 0)
}

struct WorkGraphFileRecord: Codable, Hashable {
    var path: String
    var contentHash: String
    var language: WorkGraphLanguage
    var byteCount: Int
    var modifiedAt: Date?
    var isGenerated: Bool
    var diagnostics: [String]
}

struct WorkGraphNodeDraft: Codable, Hashable {
    var id: String
    var parentID: String?
    var kind: WorkGraphNodeKind
    var name: String
    var qualifiedName: String
    var filePath: String
    var language: WorkGraphLanguage
    var location: WorkGraphSourceLocation
    var signature: String?
    var visibility: String?
    var isExported: Bool
    var isAsync: Bool
    var isStatic: Bool
    var isAbstract: Bool
    var returnType: String?
    var decorators: [String]
}

struct WorkGraphEdgeDraft: Codable, Hashable {
    var sourceID: String
    var targetID: String
    var kind: WorkGraphEdgeKind
    var location: WorkGraphSourceLocation?
    var metadataJSON: String?
    var confidence: Double
    var provenance: WorkGraphEdgeProvenance
}

struct WorkGraphReferenceDraft: Codable, Hashable {
    var fromNodeID: String
    var rawName: String
    var kind: WorkGraphEdgeKind
    var location: WorkGraphSourceLocation
    var candidateNames: [String]
    var filePath: String
    var language: WorkGraphLanguage
    var fingerprint: String
}

struct WorkGraphDocumentRecord: Codable, Hashable {
    var path: String
    var terms: [String]
}

struct WorkGraphExtraction: Codable, Hashable {
    var file: WorkGraphFileRecord
    var nodes: [WorkGraphNodeDraft]
    var edges: [WorkGraphEdgeDraft]
    var references: [WorkGraphReferenceDraft]
    var documents: [WorkGraphDocumentRecord]
}

struct WorkGraphIndexSnapshot: Codable, Hashable {
    var files: [WorkGraphFileRecord]
    var nodes: [WorkGraphNodeDraft]
    var edges: [WorkGraphEdgeDraft]
    var references: [WorkGraphReferenceDraft]
    var documents: [WorkGraphDocumentRecord]
}

/// Outcome for one extracted reference after conservative symbol resolution.
///
/// `ambiguous` and `failed` records deliberately have no target or edge. They
/// remain useful for diagnostics, but cannot influence graph traversal.
struct WorkGraphReferenceResolution: Codable, Hashable {
    var fingerprint: String
    var status: WorkGraphReferenceStatus
    var targetID: String?
    var confidence: Double?
    var resolver: String?
}

/// In-memory output of cross-file resolution. The caller can append `edges`
/// to the indexed snapshot and persist `references` separately.
struct WorkGraphResolutionResult: Codable, Hashable {
    var edges: [WorkGraphEdgeDraft]
    var references: [WorkGraphReferenceResolution]
}

struct WorkGraphSymbolMatch: Equatable {
    var id: String
    var name: String
    var qualifiedName: String
    var kind: WorkGraphNodeKind
    var path: String
    var location: WorkGraphSourceLocation
    var language: WorkGraphLanguage
}

/// A persisted symbol or file node returned by an exact WorkGraph query.
///
/// Query APIs intentionally expose node IDs so follow-up traversal does not need
/// to infer relationships from names.
struct WorkGraphNode: Codable, Hashable {
    var id: String
    var kind: WorkGraphNodeKind
    var name: String
    var qualifiedName: String
    var path: String
    var language: WorkGraphLanguage
    var location: WorkGraphSourceLocation
    var signature: String?
    var visibility: String?
    var isExported: Bool
    var isAsync: Bool
    var isStatic: Bool
    var isAbstract: Bool
    var returnType: String?
    var decorators: [String]
}

/// A persisted, resolved relationship. Unresolved references are deliberately
/// excluded because they must not steer graph traversal.
struct WorkGraphEdge: Codable, Hashable {
    var sourceID: String
    var targetID: String
    var kind: WorkGraphEdgeKind
    var location: WorkGraphSourceLocation?
    var confidence: Double
    var provenance: WorkGraphEdgeProvenance
    var metadataJSON: String?
}

/// Bounded callers, callees, or impact results. `nodes` excludes the queried
/// root node and is ordered by breadth-first discovery.
struct WorkGraphTraversal: Equatable {
    var nodes: [WorkGraphNode]
    var edges: [WorkGraphEdge]
}

/// One bounded, exact-ID route through the resolved graph.
struct WorkGraphPath: Equatable {
    var nodes: [WorkGraphNode]
    var edges: [WorkGraphEdge]
}

protocol WorkGraphLanguageExtractor {
    var supportedLanguages: Set<WorkGraphLanguage> { get }
    func extract(file: WorkGraphSourceFile) throws -> WorkGraphExtraction
}

struct WorkGraphSourceFile {
    var record: WorkGraphFileRecord
    var source: String
}
