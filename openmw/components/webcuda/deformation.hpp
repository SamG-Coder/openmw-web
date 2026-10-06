#ifndef OPENMW_WEBCUDA_DEFORMATION_H
#define OPENMW_WEBCUDA_DEFORMATION_H
#include <osg/Array>
#include <osg/Object>
#include <osg/Geometry>
#include <osg/Matrixf>
#include <vector>
namespace WebCuda
{
    // An immutable cull-time snapshot of morph inputs, retained until the
    // synchronous packet copy. No blended render positions are made on CPU.
    class MorphInputs : public osg::Object
    {
    public:
        MorphInputs() { setName("webcuda.morph"); }
        MorphInputs(const MorphInputs& other,const osg::CopyOp& copy=osg::CopyOp::SHALLOW_COPY)
            : osg::Object(other,copy),base(other.base),targets(other.targets) {}
        META_Object(WebCuda,MorphInputs)
        osg::ref_ptr<const osg::Vec3Array> base;
        struct Target { osg::ref_ptr<const osg::Vec3Array> offsets;float weight; };
        std::vector<Target> targets;
    };
    class SkinInputs : public osg::Object
    {
    public:
        SkinInputs() { setName("webcuda.skin"); }
        SkinInputs(const SkinInputs& other,const osg::CopyOp& copy=osg::CopyOp::SHALLOW_COPY)
            : osg::Object(other,copy),source(other.source),bones(other.bones),groups(other.groups),skinToSkeleton(other.skinToSkeleton),transform(other.transform) {}
        META_Object(WebCuda,SkinInputs)
        osg::ref_ptr<const osg::Geometry> source;
        struct Bone { osg::Matrixf bind,pose;bool valid; };
        struct Group { std::vector<std::pair<std::size_t,float>> weights;std::vector<unsigned short> vertices; };
        std::vector<Bone> bones;
        std::vector<Group> groups;
        osg::Matrixf skinToSkeleton,transform;
    };
}
#endif
