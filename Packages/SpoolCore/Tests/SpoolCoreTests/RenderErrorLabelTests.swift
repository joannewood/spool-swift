import Testing
@testable import SpoolCore

@Suite struct RenderErrorLabelTests {
    @Test func oversizedMesh() {
        let error = "3MF's inner mesh data is 99000000 bytes uncompressed, over the "
            + "12000000-byte safety limit — skipped without attempting to render"
        #expect(RenderErrorLabel.label(for: error) == "Mesh too large to render")
    }

    @Test func excessiveComponents() {
        let error = "3MF has 166 <item>/<component> build references, over the "
            + "60-reference safety limit — skipped without attempting to render"
        #expect(RenderErrorLabel.label(for: error) == "Too complex to render")
    }

    @Test func fallsBackForUnrecognizedErrors() {
        #expect(RenderErrorLabel.label(for: "some other unrelated error") == "Render failed")
        #expect(RenderErrorLabel.label(for: nil) == "Render failed")
        #expect(RenderErrorLabel.label(for: "") == "Render failed")
    }
}
