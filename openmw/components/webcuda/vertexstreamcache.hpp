#ifndef OPENMW_COMPONENTS_WEBCUDA_VERTEXSTREAMCACHE_H
#define OPENMW_COMPONENTS_WEBCUDA_VERTEXSTREAMCACHE_H
#include <osg/Array>
#include <osg/observer_ptr>
#include <cmath>
#include <cstring>
#include <cstdint>
#include <limits>
#include <iterator>
#include <list>
#include <map>
#include <stdexcept>
#include <tuple>
#include <utility>
#include <vector>

namespace WebCuda
{
    // Immutable transport snapshots, not transformed vertices. Compare the
    // original bytes on every use: OSG callers can edit arrays without dirty().
    // Weak source ownership also prevents address reuse from reviving a version.
    class VertexStreamCache
    {
    public:
        struct Entry
        {
            osg::observer_ptr<const osg::Array> source;
            const osg::Array* sourceIdentity=nullptr; // lookup only, never dereferenced
            unsigned int count=0,components=0;
            std::uint32_t version=0;
            std::vector<unsigned char> raw;
            std::vector<float> values;
            std::size_t bytes() const { return raw.size()+values.size()*sizeof(float); }
        };
        explicit VertexStreamCache(std::size_t budget=64u*1024u*1024u,std::size_t minimum=256u)
            : mBudget(budget),mMinimum(minimum) {}

        template<class Convert>
        const Entry* capture(const osg::Array* source,unsigned int count,unsigned int components,Convert convert)
        {
            const auto words=std::uint64_t(count)*components;
            if(!source||count>source->getNumElements()||!components||components>4||words>0xffffffffu)
                throw std::runtime_error("Invalid vertex stream cache input");
            const std::size_t rawBytes=std::size_t(count)*source->getElementSize();
            const std::size_t bytes=rawBytes+std::size_t(words)*sizeof(float);
            if(!count||words*sizeof(float)<mMinimum||bytes>mBudget)return nullptr;
            const Key key{source,count,components};
            if(++mLookups%1024==0) {
                for(auto it=mEntries.begin();it!=mEntries.end();)
                    if(!it->source.valid()){auto old=it++;erase(old);}else ++it;
            }
            auto found=mIndex.find(key);
            if(found!=mIndex.end()) {
                const auto entry=found->second;
                if(entry->source.valid()&&entry->raw.size()==rawBytes
                    &&std::memcmp(entry->raw.data(),source->getDataPointer(),rawBytes)==0) {
                    mEntries.splice(mEntries.end(),mEntries,entry);
                    return &*entry;
                }
            }
            Entry next;next.source=source;next.sourceIdentity=source;next.count=count;next.components=components;
            next.raw.resize(rawBytes);std::memcpy(next.raw.data(),source->getDataPointer(),rawBytes);
            next.values.resize(static_cast<std::size_t>(words));
            for(unsigned int i=0;i<count;i++) {
                const auto value=convert(i);
                for(unsigned int k=0;k<components;k++) {
                    if(!std::isfinite(value[k]))throw std::runtime_error("Non-finite cached vertex input");
                    next.values[std::size_t(i)*components+k]=value[k];
                }
            }
            if(mNextVersion==std::numeric_limits<std::uint32_t>::max())throw std::runtime_error("Vertex stream version exhausted");
            next.version=++mNextVersion;
            if(found!=mIndex.end())erase(found->second);
            while(!mEntries.empty()&&(mBytes+bytes>mBudget||mEntries.size()>=8192))erase(mEntries.begin());
            mEntries.push_back(std::move(next));
            const auto entry=std::prev(mEntries.end());
            try {mIndex.emplace(key,entry);}catch(...){mEntries.pop_back();throw;}
            mBytes+=bytes;
            return &*entry;
        }
        std::size_t bytes() const { return mBytes; }
        std::size_t size() const { return mEntries.size(); }
    private:
        using Key=std::tuple<const osg::Array*,unsigned int,unsigned int>;
        using Entries=std::list<Entry>;
        void erase(Entries::iterator entry)
        {
            mIndex.erase(Key{entry->sourceIdentity,entry->count,entry->components});
            mBytes-=entry->bytes();mEntries.erase(entry);
        }
        std::size_t mBudget,mMinimum,mBytes=0;
        unsigned int mLookups=0;
        std::uint32_t mNextVersion=0;
        Entries mEntries;
        std::map<Key,Entries::iterator> mIndex;
    };
}
#endif
