import Testing
@testable import SpoolMesh

@Suite struct MeshAnalysisTests {
    @Test func closedCubeIsWatertightWithUnitVolume() {
        let mesh = MeshFixtures.unitCube()
        let analysis = MeshAnalyzer.analyze(mesh)

        #expect(analysis.isManifold == true)
        #expect(analysis.triangleCount == 12)
        #expect(analysis.volumeMm3 != nil)
        if let volume = analysis.volumeMm3 {
            #expect(abs(volume - 1.0) < 0.0001)
        }
        #expect(analysis.boundingBoxMin == SIMD3<Float>(0, 0, 0))
        #expect(analysis.boundingBoxMax == SIMD3<Float>(1, 1, 1))
    }

    @Test func openBoxIsNotWatertightAndReportsNoVolume() {
        let mesh = MeshFixtures.openBox()
        let analysis = MeshAnalyzer.analyze(mesh)

        #expect(analysis.isManifold == false)
        #expect(analysis.volumeMm3 == nil, "an open mesh's volume isn't meaningful, so it must not be reported")
        #expect(analysis.triangleCount == 10)
    }

    @Test func duplicatedFaceIsNotWatertight() {
        var mesh = MeshFixtures.unitCube()
        // Duplicate one triangle exactly — a directed edge now occurs twice, which is
        // exactly the "overlapping geometry" case the count-must-be-1 check catches.
        mesh.triangles.append(mesh.triangles[0])
        #expect(MeshAnalyzer.isWatertight(mesh) == false)
    }

    @Test func emptyMeshIsNotWatertight() {
        let mesh = TriangleMesh(vertices: [], triangles: [])
        #expect(MeshAnalyzer.isWatertight(mesh) == false)
    }
}
