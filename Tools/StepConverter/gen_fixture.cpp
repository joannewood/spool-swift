// Test-fixture generator, not part of the shipped tool: writes a real STEP
// file (a box with a cylindrical hole through it, to exercise both planar
// and curved-surface tessellation) so step-tessellate has something genuine
// to convert. Build/run once via build_fixture.sh; the output isn't checked
// into the app, only used for local M5 verification.
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <STEPControl_Writer.hxx>
#include <STEPControl_StepModelType.hxx>
#include <gp_Ax2.hxx>
#include <gp_Pnt.hxx>
#include <gp_Dir.hxx>
#include <iostream>

int main(int argc, char **argv) {
    if (argc != 2) {
        std::cerr << "usage: gen_fixture <output.step>\n";
        return 2;
    }
    TopoDS_Shape box = BRepPrimAPI_MakeBox(20.0, 20.0, 10.0).Shape();
    gp_Ax2 axis(gp_Pnt(10.0, 10.0, -1.0), gp_Dir(0, 0, 1));
    TopoDS_Shape cylinder = BRepPrimAPI_MakeCylinder(axis, 5.0, 12.0).Shape();
    TopoDS_Shape result = BRepAlgoAPI_Cut(box, cylinder).Shape();

    STEPControl_Writer writer;
    IFSelect_ReturnStatus status = writer.Transfer(result, STEPControl_AsIs);
    if (status != IFSelect_RetDone) {
        std::cerr << "gen_fixture: transfer failed\n";
        return 1;
    }
    status = writer.Write(argv[1]);
    if (status != IFSelect_RetDone) {
        std::cerr << "gen_fixture: write failed\n";
        return 1;
    }
    std::cout << "wrote " << argv[1] << "\n";
    return 0;
}
