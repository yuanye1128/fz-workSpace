"use strict";

// WorkGraph's parser helper owns no repository access. Swift supplies one
// relative path and its already-read source in each NDJSON request.
const fs = require("fs");
const path = require("path");
const readline = require("readline");
const { Parser, Language } = require(path.join(__dirname, "web-tree-sitter.cjs"));

const PROTOCOL_VERSION = 1;
const MAX_TERMS = 160;

const GRAMMARS = {
  dart: "tree-sitter-dart.wasm",
  swift: "tree-sitter-swift.wasm",
  "objective-c": "tree-sitter-objc.wasm",
  kotlin: "tree-sitter-kotlin.wasm",
  java: "tree-sitter-java.wasm",
  c: "tree-sitter-c.wasm",
  cpp: "tree-sitter-cpp.wasm",
  arkts: "tree-sitter-arkts.wasm",
};

const TYPE_KINDS = {
  dart: {
    class_definition: "class", mixin_declaration: "class", extension_declaration: "class",
    enum_declaration: "enum", type_alias: "type_alias", method_signature: "method",
    constructor_signature: "method", function_signature: "function",
  },
  swift: {
    class_declaration: "class", struct_declaration: "struct", protocol_declaration: "protocol",
    enum_declaration: "enum", typealias_declaration: "type_alias", function_declaration: "function",
    protocol_function_declaration: "method",
  },
  "objective-c": {
    class_interface: "class", class_implementation: "class", protocol_declaration: "protocol",
    function_definition: "function", method_definition: "method", method_declaration: "method", struct_specifier: "struct",
    enum_specifier: "enum",
  },
  kotlin: {
    class_declaration: "class", object_declaration: "class", interface_declaration: "interface",
    enum_class_body: "enum", type_alias: "type_alias", function_declaration: "function",
    secondary_constructor: "method",
  },
  java: {
    class_declaration: "class", interface_declaration: "interface", enum_declaration: "enum",
    annotation_type_declaration: "interface", method_declaration: "method",
    constructor_declaration: "method",
  },
  c: {
    function_definition: "function", struct_specifier: "struct", enum_specifier: "enum",
    type_definition: "type_alias",
  },
  cpp: {
    class_specifier: "class", struct_specifier: "struct", enum_specifier: "enum",
    namespace_definition: "namespace", function_definition: "function", type_definition: "type_alias",
  },
  arkts: {
    class_declaration: "class", struct_declaration: "struct", interface_declaration: "interface",
    enum_declaration: "enum", type_alias_declaration: "type_alias", function_declaration: "function",
    method_definition: "method", method_signature: "method",
  },
};

const IMPORT_TYPES = new Set([
  "import_or_export", "import_declaration", "import_header", "preproc_include",
]);

const CALL_TYPES = new Set([
  "call_expression", "method_invocation", "message_expression", "argument_part",
  "arkui_component_expression",
]);

const TYPE_NAME_TYPES = new Set([
  "identifier", "type_identifier", "simple_identifier", "property_identifier",
]);

const TYPE_TARGET_KINDS = new Set([
  "class", "struct", "interface", "protocol", "enum", "type_alias",
]);

const CALLABLE_TARGET_KINDS = new Set(["function", "method"]);

let parser = null;
let activeLanguage = null;

function safeText(value, limit = 512) {
  return String(value || "").replace(/[\u0000-\u001f\u007f]/g, " ").trim().slice(0, limit);
}

function stableID(parts) {
  return parts.map((part) => encodeURIComponent(String(part))).join(":");
}

function location(node) {
  return {
    startLine: node.startPosition.row + 1,
    endLine: node.endPosition.row + 1,
    startColumn: node.startPosition.column,
    endColumn: node.endPosition.column,
  };
}

function textOf(node, source) {
  return node ? source.slice(node.startIndex, node.endIndex) : "";
}

function descendants(node, predicate, output = []) {
  if (predicate(node)) output.push(node);
  for (const child of node.namedChildren || []) descendants(child, predicate, output);
  return output;
}

function firstIdentifier(node, source) {
  const direct = ["name", "declarator", "type", "selector"]
    .map((field) => node.childForFieldName(field))
    .find(Boolean);
  const candidates = direct
    ? descendants(direct, (child) => /identifier|selector/.test(child.type))
    : descendants(node, (child) => /identifier|selector/.test(child.type));
  const named = candidates
    .map((candidate) => safeText(textOf(candidate, source)))
    .find((candidate) => /^[A-Za-z_$][\w$]*(?::[A-Za-z_$][\w$]*)?$/.test(candidate));
  return named || "";
}

function nameFor(node, language, source) {
  if (language === "dart" && node.type === "method_signature") {
    const signature = descendants(node, (child) => child.type === "function_signature")[0];
    return firstIdentifier(signature || node, source);
  }
  if (language === "dart" && node.type === "constructor_signature") {
    const ids = descendants(node, (child) => child.type === "identifier")
      .map((child) => safeText(textOf(child, source)));
    return ids.at(-1) || ids[0] || "";
  }
  if ((language === "c" || language === "cpp") && node.type === "function_definition") {
    const declarator = node.childForFieldName("declarator");
    const ids = descendants(declarator || node, (child) => /identifier/.test(child.type));
    return safeText(textOf(ids.at(-1), source));
  }
  return firstIdentifier(node, source);
}

function signatureFor(node, source) {
  const text = textOf(node, source).replace(/\s+/g, " ").trim();
  const bodyIndex = text.indexOf("{");
  return safeText(bodyIndex >= 0 ? text.slice(0, bodyIndex) : text, 480) || null;
}

function decoratorsFor(node, source) {
  return descendants(node, (child) => child.type === "decorator")
    .map((child) => safeText(textOf(child, source), 120))
    .filter(Boolean)
    .slice(0, 16);
}

function visibilityFor(node, source) {
  const prefix = textOf(node, source).slice(0, 160);
  const matched = prefix.match(/\b(public|private|protected|internal|open|fileprivate)\b/);
  return matched ? matched[1] : null;
}

function importedName(node, source) {
  const text = textOf(node, source);
  const quoted = text.match(/(?:import|include)\s*(?:[^"']*?\s+from\s+)?["']([^"']+)["']/);
  if (quoted) return quoted[1];
  const bare = text.match(/\bimport\s+([A-Za-z_$][\w$]*(?:[.:][\w$]+)*)/);
  return bare ? bare[1] : "";
}

function callName(node, language, source) {
  if (node.type === "argument_part" && language === "dart") {
    const selector = node.parent;
    const previous = selector && selector.previousNamedSibling;
    if (!previous) return "";
    const ids = descendants(previous, (child) => child.type === "identifier")
      .map((child) => safeText(textOf(child, source)));
    return ids.at(-1) || safeText(textOf(previous, source));
  }
  if (node.type === "message_expression") {
    const selector = node.childForFieldName("selector") || descendants(node, (child) => /selector/.test(child.type))[0];
    return safeText(textOf(selector, source));
  }
  const target = node.childForFieldName("function") || node.childForFieldName("name") ||
    node.childForFieldName("target") || node.namedChildren?.[0];
  if (!target) return "";
  const ids = descendants(target, (child) => /identifier/.test(child.type))
    .map((child) => safeText(textOf(child, source)));
  return ids.at(-1) || safeText(textOf(target, source));
}

function namedChildrenOfType(node, types) {
  return (node?.namedChildren || []).filter((child) => types.has(child.type));
}

function identifierName(node, source) {
  if (!node) return "";
  const direct = TYPE_NAME_TYPES.has(node.type) ? safeText(textOf(node, source)) : "";
  if (/^[A-Za-z_$][\w$]*$/.test(direct)) return direct;
  const candidate = descendants(node, (child) => TYPE_NAME_TYPES.has(child.type))
    .map((child) => safeText(textOf(child, source)))
    .find((value) => /^[A-Za-z_$][\w$]*$/.test(value));
  return candidate || "";
}

function firstTypeName(node, source) {
  return identifierName(node, source);
}

function typeNamesInContainer(node, source) {
  const names = [];
  const wrappers = new Set([
    "type_list", "super_interfaces", "extends_interfaces", "interfaces",
    "implements_clause", "protocol_reference_list", "base_class_clause",
  ]);

  function appendFrom(container) {
    for (const child of container?.namedChildren || []) {
      if (TYPE_NAME_TYPES.has(child.type)) {
        const name = identifierName(child, source);
        if (name) names.push(name);
      } else if (wrappers.has(child.type)) {
        appendFrom(child);
      }
    }
  }

  appendFrom(node);
  return [...new Set(names)];
}

function relationshipFactsForDeclaration(node, language, declarationKind, source) {
  const facts = [];
  const add = (kind, targetNode, names = [firstTypeName(targetNode, source)]) => {
    for (const name of names) {
      if (name) facts.push({ kind, name, node: targetNode });
    }
  };

  switch (language) {
    case "dart": {
      if (node.type !== "class_definition") break;
      const superclass = node.childForFieldName("superclass");
      if (superclass) add("extends", superclass);
      const interfaces = node.childForFieldName("interfaces");
      if (interfaces) add("implements", interfaces, typeNamesInContainer(interfaces, source));
      break;
    }
    case "swift": {
      const inheritance = namedChildrenOfType(node, new Set(["inheritance_specifier"]));
      for (const specifier of inheritance) {
        const target = specifier.childForFieldName("inherits_from") || specifier;
        const name = firstTypeName(target, source);
        if (!name) continue;

        // Swift's colon list has no AST marker that tells a class superclass
        // from a protocol conformance. The post-pass classifies only local,
        // uniquely declared targets; external names remain absent by design.
        if (declarationKind === "class") {
          facts.push({ kind: null, name, node: target });
        } else if (declarationKind === "protocol") {
          facts.push({ kind: "extends", name, node: target });
        } else if (declarationKind === "struct" || declarationKind === "enum") {
          facts.push({ kind: "implements", name, node: target });
        }
      }
      break;
    }
    case "objective-c": {
      if (node.type === "class_interface") {
        const superclass = node.childForFieldName("superclass");
        if (superclass) add("extends", superclass);
      } else if (node.type === "protocol_declaration") {
        const inherited = namedChildrenOfType(node, new Set(["protocol_reference_list"]));
        for (const list of inherited) add("extends", list, typeNamesInContainer(list, source));
      }
      // `class_interface` parameterized_arguments represents both generic
      // arguments and protocol adoption in this grammar, so it is omitted.
      break;
    }
    case "kotlin": {
      if (node.type !== "class_declaration" && node.type !== "object_declaration") break;
      for (const specifier of namedChildrenOfType(node, new Set(["delegation_specifier"]))) {
        const target = specifier.namedChildren?.[0];
        if (!target) continue;
        if (target.type === "constructor_invocation") {
          add("extends", target);
        } else if (target.type === "user_type") {
          add("implements", target);
        }
      }
      break;
    }
    case "java": {
      const superclass = node.childForFieldName("superclass") ||
        namedChildrenOfType(node, new Set(["superclass"])).at(0);
      if (superclass) add("extends", superclass);
      const interfaceContainers = namedChildrenOfType(node, new Set([
        "super_interfaces", "extends_interfaces",
      ]));
      for (const container of interfaceContainers) {
        add(node.type === "interface_declaration" ? "extends" : "implements", container, typeNamesInContainer(container, source));
      }
      break;
    }
    case "cpp": {
      if (node.type !== "class_specifier" && node.type !== "struct_specifier") break;
      for (const baseClause of namedChildrenOfType(node, new Set(["base_class_clause"]))) {
        add("extends", baseClause, typeNamesInContainer(baseClause, source));
      }
      break;
    }
    case "arkts": {
      const heritage = namedChildrenOfType(node, new Set(["class_heritage"]));
      for (const item of heritage) {
        for (const clause of namedChildrenOfType(item, new Set(["extends_clause"]))) {
          add("extends", clause.childForFieldName("value") || clause);
        }
        for (const clause of namedChildrenOfType(item, new Set(["implements_clause"]))) {
          add("implements", clause, typeNamesInContainer(clause, source));
        }
      }
      break;
    }
  }

  return facts;
}

function hasExplicitOverride(node, language, source) {
  switch (language) {
    case "dart": {
      let previous = node.previousNamedSibling;
      while (previous?.type === "annotation") {
        if (identifierName(previous, source) === "override") return true;
        previous = previous.previousNamedSibling;
      }
      return false;
    }
    case "swift":
    case "kotlin": {
      const modifiers = namedChildrenOfType(node, new Set(["modifiers"]));
      return modifiers.some((modifier) => descendants(
        modifier,
        (child) => /modifier$/.test(child.type) && safeText(textOf(child, source)) === "override"
      ).length > 0);
    }
    case "java": {
      const modifiers = namedChildrenOfType(node, new Set(["modifiers"]));
      return modifiers.some((modifier) => descendants(
        modifier,
        (child) => child.type === "marker_annotation" && firstIdentifier(child, source) === "Override"
      ).length > 0);
    }
    case "cpp": {
      const declarator = node.childForFieldName("declarator") || node;
      return descendants(
        declarator,
        (child) => child.type === "virtual_specifier" && safeText(textOf(child, source)) === "override"
      ).length > 0;
    }
    case "arkts":
      return namedChildrenOfType(node, new Set(["override_modifier"])).length > 0;
    default:
      return false;
  }
}

function instantiationFactsFor(node, language, source) {
  const facts = [];
  const add = (targetNode, localOnly = false) => {
    const name = firstTypeName(targetNode, source);
    if (name) facts.push({ name, node: targetNode, localOnly });
  };

  switch (language) {
    case "dart":
      if (node.type === "const_object_expression") add(node);
      break;
    case "java":
      if (node.type === "object_creation_expression") add(node.childForFieldName("type") || node);
      break;
    case "cpp":
      if (node.type === "new_expression") add(node.childForFieldName("type") || node);
      break;
    case "objective-c": {
      if (node.type !== "message_expression") break;
      const selector = node.childForFieldName("method") || node.childForFieldName("selector");
      const selectorName = identifierName(selector, source);
      if (selectorName === "alloc" || selectorName === "new") {
        add(node.childForFieldName("receiver"), true);
      }
      break;
    }
    case "arkts": {
      if (node.type === "new_expression") {
        add(node.childForFieldName("constructor") || node);
      } else if (node.type === "arkui_component_expression") {
        add(node.childForFieldName("function") || node);
      }
      break;
    }
  }

  return facts;
}

function documentTerms(source, relativePath) {
  const matches = `${relativePath} ${source}`.match(/[\p{L}\p{N}_$-]{2,}/gu) || [];
  const terms = new Set();
  for (const value of matches) {
    terms.add(value.toLocaleLowerCase());
    if (terms.size >= MAX_TERMS) break;
  }
  return [...terms];
}

function bodyOwner(node, knownOwners) {
  let previous = node.previousNamedSibling;
  while (previous) {
    const owner = knownOwners.get(`${previous.startIndex}:${previous.endIndex}`);
    if (owner) return owner;
    previous = previous.previousNamedSibling;
  }
  return null;
}

async function parserFor(language) {
  const grammar = GRAMMARS[language];
  if (!grammar) throw new Error(`Unsupported language: ${language}`);
  if (activeLanguage === language && parser) return parser;

  if (parser) parser.delete();
  parser = new Parser();
  const grammarPath = path.join(__dirname, "grammars", grammar);
  if (!fs.existsSync(grammarPath)) throw new Error(`Missing grammar: ${grammar}`);
  const loaded = await Language.load(grammarPath);
  parser.setLanguage(loaded);
  activeLanguage = language;
  return parser;
}

async function extract(request) {
  const diagnostics = [];
  if (request.protocolVersion !== PROTOCOL_VERSION) {
    throw new Error(`Protocol mismatch: ${request.protocolVersion}`);
  }
  if (request.operation !== "extract") throw new Error(`Unsupported operation: ${request.operation}`);
  if (!GRAMMARS[request.language]) throw new Error(`Unsupported language: ${request.language}`);
  if (!request.relativePath || request.relativePath.startsWith("/") || request.relativePath.includes("..")) {
    throw new Error("relativePath must be a repository-relative path");
  }

  const syntaxParser = await parserFor(request.language);
  const tree = syntaxParser.parse(request.source);
  if (!tree) throw new Error("Parser did not return a syntax tree");
  if (tree.rootNode.hasError) diagnostics.push("Tree-sitter reported syntax recovery; only structurally valid facts were extracted.");

  const nodes = [{
    id: `file:${request.relativePath}`,
    parentID: null,
    kind: "file",
    name: request.relativePath,
    qualifiedName: request.relativePath,
    filePath: request.relativePath,
    language: request.language,
    location: { startLine: 1, endLine: 1, startColumn: 0, endColumn: 0 },
    signature: null,
    visibility: null,
    isExported: false,
    isAsync: false,
    isStatic: false,
    isAbstract: false,
    returnType: null,
    decorators: [],
  }];
  const emittedNodeIDs = new Set([`file:${request.relativePath}`]);
  let duplicateNodeCount = 0;
  const edges = [];
  const references = [];
  const fileID = `file:${request.relativePath}`;
  const nodeByRange = new Map();
  const declarationTypes = TYPE_KINDS[request.language] || {};
  const typeInfos = new Map();
  const pendingTypeRelationships = [];
  const pendingOverrides = [];
  const pendingInstantiations = [];
  const edgeKeys = new Set();

  function addAstEdge(sourceID, targetID, kind, node) {
    if (!sourceID || !targetID || sourceID === targetID) return;
    const at = node ? location(node) : null;
    const key = [sourceID, targetID, kind, at?.startLine ?? 0, at?.startColumn ?? 0].join(":");
    if (edgeKeys.has(key)) return;
    edgeKeys.add(key);
    edges.push({
      sourceID,
      targetID,
      kind,
      location: at,
      metadataJSON: null,
      confidence: 1,
      provenance: "ast",
    });
  }

  function addReference(fromNodeID, rawName, kind, node, candidateNames = []) {
    const name = safeText(rawName, 320);
    if (!name) return;
    const at = location(node);
    references.push({
      fromNodeID,
      rawName: name,
      kind,
      location: at,
      candidateNames: [...new Set(candidateNames.map((candidate) => safeText(candidate, 320)).filter(Boolean))],
      filePath: request.relativePath,
      language: request.language,
      fingerprint: stableID([request.relativePath, fromNodeID, kind, name, at.startLine, at.startColumn]),
    });
  }

  function localTargetsFor(names, allowedKinds, sourceID) {
    const candidates = nodes.filter((candidate) =>
      candidate.id !== sourceID &&
      allowedKinds.has(candidate.kind) &&
      (names.has(candidate.name) || names.has(candidate.qualifiedName))
    );
    return Array.from(new Map(candidates.map((candidate) => [candidate.id, candidate])).values());
  }

  function recordRelationship(fact, relationshipKind) {
    const names = new Set([fact.name, ...(fact.candidateNames || [])].filter(Boolean));
    const allowedKinds = relationshipKind === "overrides" ? CALLABLE_TARGET_KINDS : TYPE_TARGET_KINDS;
    const targets = localTargetsFor(names, allowedKinds, fact.sourceID);
    if (targets.length === 1) {
      addAstEdge(fact.sourceID, targets[0].id, relationshipKind, fact.node);
      return targets[0];
    }
    if (!fact.localOnly) {
      addReference(fact.sourceID, fact.name, relationshipKind, fact.node, fact.candidateNames || []);
    }
    return null;
  }

  function addParentRelation(ownerID, fact, relationshipKind, target) {
    const info = typeInfos.get(ownerID);
    if (!info) return;
    info.parents.push({
      name: fact.name,
      kind: relationshipKind,
      qualifiedName: target?.qualifiedName || null,
    });
  }

  function classifySwiftRelationship(fact) {
    const targets = localTargetsFor(new Set([fact.name]), TYPE_TARGET_KINDS, fact.sourceID);
    if (targets.length !== 1) return null;
    const target = targets[0];
    if (target.kind === "class") return { kind: "extends", target };
    if (target.kind === "protocol" || target.kind === "interface") {
      return { kind: "implements", target };
    }
    return null;
  }

  function canOverrideRelationship(language, kind) {
    if (language === "swift") return kind === "extends";
    return kind === "extends" || kind === "implements";
  }

  function visit(node, parentID, lexicalNames, currentCallableID, currentTypeInfo) {
    let nodeID = parentID;
    let childLexicalNames = lexicalNames;
    let childCallableID = currentCallableID;
    let childTypeInfo = currentTypeInfo;
    const kind = declarationTypes[node.type];

    const nestedDartSignature = request.language === "dart" && node.type === "function_signature" && node.parent?.type === "method_signature";
    if (kind && !nestedDartSignature) {
      const name = nameFor(node, request.language, request.source);
      if (name) {
        const at = location(node);
        const effectiveKind = (kind === "function" && parentID !== fileID &&
          ["class", "struct", "interface", "protocol", "enum"].some((value) => parentID.includes(`:${value}:`)))
          ? "method" : kind;
        const candidateID = stableID(["node", request.relativePath, effectiveKind, name, at.startLine, at.startColumn]);
        if (emittedNodeIDs.has(candidateID)) {
          // Some grammars expose a declaration and its signature as separate
          // declaration nodes at the same source range. Keep one stable node
          // instead of emitting duplicate IDs that would invalidate a file.
          duplicateNodeCount += 1;
          nodeID = parentID;
        } else {
          nodeID = candidateID;
          emittedNodeIDs.add(nodeID);
          const qualifiedName = [...lexicalNames, name].join(".");
          const sourceText = textOf(node, request.source);
          nodes.push({
            id: nodeID,
            parentID,
            kind: effectiveKind,
            name,
            qualifiedName,
            filePath: request.relativePath,
            language: request.language,
            location: at,
            signature: signatureFor(node, request.source),
            visibility: visibilityFor(node, request.source),
            isExported: /\b(public|export)\b/.test(sourceText),
            isAsync: /\b(async|suspend)\b/.test(sourceText),
            isStatic: /\bstatic\b/.test(sourceText),
            isAbstract: /\b(abstract|protocol|interface)\b/.test(sourceText),
            returnType: null,
            decorators: decoratorsFor(node, request.source),
          });
          addAstEdge(parentID, nodeID, "contains", node);
          nodeByRange.set(`${node.startIndex}:${node.endIndex}`, nodeID);
          childLexicalNames = [...lexicalNames, name];
          if (effectiveKind === "function" || effectiveKind === "method") childCallableID = nodeID;

          if (TYPE_TARGET_KINDS.has(effectiveKind)) {
            const info = { id: nodeID, parents: [] };
            typeInfos.set(nodeID, info);
            childTypeInfo = info;
            for (const fact of relationshipFactsForDeclaration(node, request.language, effectiveKind, request.source)) {
              pendingTypeRelationships.push({ sourceID: nodeID, ...fact, localOnly: false });
            }
          }

          if ((effectiveKind === "function" || effectiveKind === "method") &&
              currentTypeInfo && hasExplicitOverride(node, request.language, request.source)) {
            pendingOverrides.push({
              sourceID: nodeID,
              ownerID: currentTypeInfo.id,
              name,
              node,
            });
          }
        }
      }
    }

    if (IMPORT_TYPES.has(node.type)) addReference(fileID, importedName(node, request.source), "imports", node);
    if (CALL_TYPES.has(node.type)) {
      const name = callName(node, request.language, request.source);
      if (name) addReference(currentCallableID || nodeID || fileID, name, "calls", node);
    }
    for (const fact of instantiationFactsFor(node, request.language, request.source)) {
      pendingInstantiations.push({
        sourceID: currentCallableID || nodeID || fileID,
        ...fact,
      });
    }

    const dartOwner = request.language === "dart" && node.type === "function_body" ? bodyOwner(node, nodeByRange) : null;
    for (const child of node.namedChildren || []) {
      visit(child, nodeID, childLexicalNames, dartOwner || childCallableID, childTypeInfo);
    }
  }

  visit(tree.rootNode, fileID, [], null, null);

  for (const fact of pendingTypeRelationships) {
    if (fact.kind) {
      const target = recordRelationship(fact, fact.kind);
      addParentRelation(fact.sourceID, fact, fact.kind, target);
      continue;
    }
    const classified = classifySwiftRelationship(fact);
    if (!classified) continue;
    addAstEdge(fact.sourceID, classified.target.id, classified.kind, fact.node);
    addParentRelation(fact.sourceID, fact, classified.kind, classified.target);
  }

  for (const override of pendingOverrides) {
    const owner = typeInfos.get(override.ownerID);
    if (!owner) continue;
    for (const parent of owner.parents) {
      if (!canOverrideRelationship(request.language, parent.kind)) continue;
      const qualifiedName = `${parent.qualifiedName || parent.name}.${override.name}`;
      recordRelationship({
        sourceID: override.sourceID,
        name: qualifiedName,
        candidateNames: [qualifiedName],
        node: override.node,
        localOnly: false,
      }, "overrides");
    }
  }

  for (const instantiation of pendingInstantiations) {
    recordRelationship(instantiation, "instantiates");
  }

  tree.delete();
  if (duplicateNodeCount > 0) {
    diagnostics.push(`解析器发现 ${duplicateNodeCount} 个重复声明节点，已去重。`);
  }
  return {
    nodes,
    edges,
    references,
    documents: [{ path: request.relativePath, terms: documentTerms(request.source, request.relativePath) }],
    diagnostics,
  };
}

async function respond(request) {
  try {
    const extraction = await extract(request);
    return { protocolVersion: PROTOCOL_VERSION, requestID: request.requestID, kind: "extraction", extraction, diagnostics: extraction.diagnostics, error: null };
  } catch (error) {
    return {
      protocolVersion: PROTOCOL_VERSION,
      requestID: request && typeof request.requestID === "string" ? request.requestID : "",
      kind: "error",
      extraction: null,
      diagnostics: [],
      error: { code: "parse_failed", message: safeText(error && error.message ? error.message : error, 1024) },
    };
  }
}

(async () => {
  await Parser.init({ locateFile: (file) => path.join(__dirname, file) });
  const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  for await (const line of input) {
    if (!line.trim()) continue;
    let request;
    try {
      request = JSON.parse(line);
    } catch (error) {
      process.stdout.write(`${JSON.stringify({ protocolVersion: PROTOCOL_VERSION, requestID: "", kind: "error", extraction: null, diagnostics: [], error: { code: "invalid_request", message: "Invalid JSON request" } })}\n`);
      continue;
    }
    process.stdout.write(`${JSON.stringify(await respond(request))}\n`);
  }
})().catch((error) => {
  process.stderr.write(`WorkGraph parser startup failed: ${safeText(error && error.stack ? error.stack : error, 4096)}\n`);
  process.exitCode = 1;
});
