#include <cassert>
#include <algorithm>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>
#include <osg/Geometry>
#include <osg/Matrix>
#include <osg/StateSet>
#include <osgUtil/RenderLeaf>
#include <osgUtil/RenderStage>
#include <components/webcuda/submission.hpp>

struct Sink : WebCuda::SubmissionSink
{
    std::vector<std::string> commands;
    const osg::StateSet* inherited = nullptr;
    void beginPass(const osgUtil::RenderStage& s) override { commands.push_back("begin:" + s.getName()); }
    void endPass(const osgUtil::RenderStage& s) override { commands.push_back("end:" + s.getName()); }
    void geometry(const osg::Geometry& g, const WebCuda::DrawContext& c) override {
        assert(c.modelView && c.projection);
        // Pass defaults precede inherited scene state; the original state must
        // remain present exactly once for downstream override resolution.
        assert(std::count(c.states.begin(), c.states.end(), inherited) == 1);
        commands.push_back(g.getName());
    }
    void gui(const osg::Array&, std::size_t, const osg::Texture2D*, const WebCuda::DrawContext&) override {
        commands.push_back("gui");
    }
};

int main() {
    osg::ref_ptr<osgUtil::RenderStage> main = new osgUtil::RenderStage;
    osg::ref_ptr<osgUtil::RenderStage> before = new osgUtil::RenderStage;
    osg::ref_ptr<osgUtil::RenderStage> after = new osgUtil::RenderStage;
    main->setName("main"); before->setName("reflection"); after->setName("overlay");
    main->addPreRenderStage(before); main->addPostRenderStage(after);
    osg::ref_ptr<osg::StateSet> rootState = new osg::StateSet;
    std::vector<osg::ref_ptr<osgUtil::RenderLeaf>> leaves;
    auto add = [&](osgUtil::RenderBin& bin, const char* name) {
        osg::ref_ptr<osg::Geometry> geometry = new osg::Geometry;
        geometry->setName(name);
        auto leaf = new osgUtil::RenderLeaf(geometry, new osg::RefMatrix, new osg::RefMatrix);
        leaves.push_back(leaf);
        bin.getRenderLeafList().push_back(leaf);
    };
    add(*before, "water-scene");
    add(*main->find_or_insert(-1,"RenderBin"), "early");
    add(*main, "world");
    add(*main->find_or_insert(1,"RenderBin"), "late");
    add(*after, "hud");
    Sink sink; sink.inherited = rootState;
    WebCuda::submitStage(*main, sink, {rootState});
    const std::vector<std::string> expected = {
        "begin:reflection","water-scene","end:reflection",
        "begin:main","early","world","late","end:main",
        "begin:overlay","hud","end:overlay"
    };
    assert(sink.commands == expected);
    // An unhandled custom drawable must fail rather than execute its GL draw path.
    osg::ref_ptr<osg::Drawable> unsupported = new osg::Drawable;
    auto leaf = new osgUtil::RenderLeaf(unsupported, new osg::RefMatrix, new osg::RefMatrix);
    leaves.push_back(leaf);
    main->getRenderLeafList().push_back(leaf);
    bool rejected = false;
    try { WebCuda::submitStage(*main, sink, {rootState}); }
    catch (const std::runtime_error&) { rejected = true; }
    assert(rejected);
    std::puts("WebCuda submission: camera/bin order, inherited state and unsupported-drawable checks passed");
}
