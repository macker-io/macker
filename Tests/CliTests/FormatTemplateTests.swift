import Foundation
import Testing
@testable import CliCore

struct FormatTemplateTests {
    @Test func parsesTableFieldsAndEscapes() throws {
        let template = try FormatTemplate.parse("table {{.ID}}\\t{{.Names}}")
        #expect(template.table)
        #expect(template.header == "ID\tNAMES")
        #expect(try FormatTemplate.render(template, row: [("ID", "abc"), ("Names", "web")]) == "abc\tweb")
    }

    @Test func parsesTableWithoutSpaceBeforeBrace() throws {
        let template = try FormatTemplate.parse("table{{.ID}}")
        #expect(template.table)
        #expect(try FormatTemplate.render(template, row: [("ID", "x")]) == "x")
    }

    @Test func bareJSONPrintsCompactObject() throws {
        let template = try FormatTemplate.parse("json")
        #expect(!template.table)
        #expect(try FormatTemplate.render(template, object: ["Id": "abc", "Name": "web"]) == "{\"Id\":\"abc\",\"Name\":\"web\"}")
    }

    @Test func jsonDotUsesRowFields() throws {
        let template = try FormatTemplate.parse("{{json .}}")
        #expect(
            try FormatTemplate.render(template, row: [("ID", "abc"), ("Names", "web")])
                == "{\"ID\":\"abc\",\"Names\":\"web\"}"
        )
    }

    @Test func dottedPathWalksNestedObjects() throws {
        let template = try FormatTemplate.parse("{{.Client.Version}}")
        #expect(try FormatTemplate.render(template, object: ["Client": ["Version": "1.41"]]) == "1.41")
    }

    @Test func isBareTableOnlyForExactTable() {
        #expect(FormatTemplate.isBareTable("table"))
        #expect(FormatTemplate.isBareTable(" table "))
        #expect(!FormatTemplate.isBareTable("table {{.ID}}"))
    }

    @Test func rejectsUnclosedAndUnknownExpressions() {
        expectCLIError("unclosed") {
            _ = try FormatTemplate.parse("{{.ID")
        }
        expectCLIError("unsupported template") {
            _ = try FormatTemplate.parse("{{.ID | upper}}")
        }
        expectCLIError("unknown field") {
            let template = try FormatTemplate.parse("{{.Missing}}")
            _ = try FormatTemplate.render(template, row: [("ID", "abc")])
        }
    }
}
