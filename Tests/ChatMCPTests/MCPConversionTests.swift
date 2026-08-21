import Foundation
import Testing
import MCP
import ChatCore
@testable import ChatMCP

@Suite("ChatValue ↔ MCP.Value")
struct MCPValueConversionTests {

    @Test("Every case survives a round trip")
    func roundTrip() {
        let original = ChatValue.object([
            "text": .string("hi"),
            "flag": .bool(true),
            "count": .number(3),
            "ratio": .number(1.5),
            "nothing": .null,
            "items": .array([.number(1), .string("two")])
        ])
        #expect(ChatValue(original.mcpValue) == original)
    }

    @Test("Whole numbers convert to MCP integers")
    func wholeNumbersBecomeInts() {
        // A server with an integer-typed parameter rejects 3.0 where it wants 3.
        #expect(ChatValue.number(3).mcpValue == .int(3))
        #expect(ChatValue.number(-7).mcpValue == .int(-7))
    }

    @Test("Fractional numbers stay doubles")
    func fractionsStayDoubles() {
        #expect(ChatValue.number(1.5).mcpValue == .double(1.5))
    }

    @Test("MCP integers and doubles both read back as numbers")
    func numbersReadBack() {
        #expect(ChatValue(MCP.Value.int(4)) == .number(4))
        #expect(ChatValue(MCP.Value.double(4.25)) == .number(4.25))
    }

    @Test("Booleans do not become numbers")
    func boolsStayBools() {
        #expect(ChatValue(MCP.Value.bool(true)) == .bool(true))
        #expect(ChatValue.bool(false).mcpValue == .bool(false))
    }

    @Test("Binary content is preserved as a data URL")
    func binaryBecomesDataURL() {
        let value = ChatValue(MCP.Value.data(mimeType: "image/png", Data([1, 2, 3])))
        #expect(value.stringValue == "data:image/png;base64,\(Data([1, 2, 3]).base64EncodedString())")
    }
}

@Suite("MCP schema conversion")
struct MCPSchemaConverterTests {

    private func parameters(_ schema: MCP.Value) -> (properties: [String: ToolSchema], optional: [String]) {
        MCPSchemaConverter.parameters(schema)
    }

    @Test("Required and optional properties are split")
    func requiredAndOptional() {
        let (properties, optional) = parameters(.object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")]),
                "limit": .object(["type": .string("integer")])
            ]),
            "required": .array([.string("path")])
        ]))

        #expect(properties.count == 2)
        #expect(optional == ["limit"])
    }

    @Test("Every scalar type maps across")
    func scalarTypes() {
        #expect(MCPSchemaConverter.convert(.object(["type": .string("string")])) == .string())
        #expect(MCPSchemaConverter.convert(.object(["type": .string("integer")])) == .integer())
        #expect(MCPSchemaConverter.convert(.object(["type": .string("number")])) == .number())
        #expect(MCPSchemaConverter.convert(.object(["type": .string("boolean")])) == .boolean())
    }

    @Test("Descriptions carry through")
    func descriptions() {
        let schema = MCPSchemaConverter.convert(
            .object(["type": .string("string"), "description": .string("A path.")]))
        #expect(schema.description == "A path.")
    }

    @Test("A string with an enum becomes an enumeration")
    func enumeration() {
        let schema = MCPSchemaConverter.convert(.object([
            "type": .string("string"),
            "enum": .array([.string("a"), .string("b")])
        ]))
        #expect(schema == .enumeration(values: ["a", "b"]))
    }

    @Test("Arrays carry their item schema, and default to strings without one")
    func arrays() {
        let typed = MCPSchemaConverter.convert(.object([
            "type": .string("array"),
            "items": .object(["type": .string("integer")])
        ]))
        #expect(typed == .array(items: .integer()))

        let untyped = MCPSchemaConverter.convert(.object(["type": .string("array")]))
        #expect(untyped == .array(items: .string()))
    }

    @Test("Nested objects recurse")
    func nestedObjects() {
        let (properties, _) = parameters(.object([
            "type": .string("object"),
            "properties": .object([
                "filter": .object([
                    "type": .string("object"),
                    "properties": .object(["name": .object(["type": .string("string")])]),
                    "required": .array([.string("name")])
                ])
            ])
        ]))
        #expect(properties["filter"] == .object(properties: ["name": .string()], optional: []))
    }

    @Test("An untyped node is treated as an object, matching JSON Schema's default")
    func untypedIsObject() {
        let schema = MCPSchemaConverter.convert(.object([
            "properties": .object(["a": .object(["type": .string("string")])])
        ]))
        #expect(schema == .object(properties: ["a": .string()], optional: ["a"]))
    }

    @Test("Composition keywords are dropped rather than approximated")
    func metaKeysDropped() {
        // A wrong schema is worse than a missing constraint: the model believes it.
        let (properties, _) = parameters(.object([
            "type": .string("object"),
            "$schema": .string("http://json-schema.org/draft-07/schema#"),
            "properties": .object([
                "real": .object(["type": .string("string")]),
                "anyOf": .object(["type": .string("string")]),
                "$ref": .object(["type": .string("string")])
            ])
        ]))
        #expect(Set(properties.keys) == ["real"])
    }

    @Test("A missing or non-object schema yields no parameters")
    func emptySchema() {
        #expect(MCPSchemaConverter.parameters(nil).properties.isEmpty)
        #expect(MCPSchemaConverter.parameters(.string("nonsense")).properties.isEmpty)
    }

    @Test("A schema with no properties yields an empty parameter map")
    func noProperties() {
        let (properties, optional) = parameters(.object(["type": .string("object")]))
        #expect(properties.isEmpty)
        #expect(optional.isEmpty)
    }
}
