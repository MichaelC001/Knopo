import Testing
@testable import KnopoCore

@Suite struct PageNameTests {
    @Test func pageNameRules() {
        expectTrue(PageName.isValid("Project X"))
        expectTrue(PageName.isValid("Projects/Outliner"))
        expectFalse(PageName.isValid("bad[name]"))
        expectFalse(PageName.isValid("bad#name"))
        expectFalse(PageName.isValid(" leading"))
        expectFalse(PageName.isValid(""))
        expectEqual(PageName.key("Project X"), PageName.key("project x"))
        expectEqual(PageName.fileName(for: "Projects/Outliner"), "Projects%2FOutliner.md")
        expectEqual(PageName.name(fromFileName: "Projects%2FOutliner.md"), "Projects/Outliner")
        expectEqual(PageName.name(fromFileName: "Plain.md"), "Plain")
        expectNil(PageName.name(fromFileName: "not-a-page.txt"))
    }
}
