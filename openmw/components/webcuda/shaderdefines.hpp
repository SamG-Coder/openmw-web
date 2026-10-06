#ifndef OPENMW_COMPONENTS_WEBCUDA_SHADERDEFINES_H
#define OPENMW_COMPONENTS_WEBCUDA_SHADERDEFINES_H
#include <cstddef>
#include <list>
#include <iterator>
#include <map>
#include <memory>
#include <string>
#include <string_view>
#include <osg/Object>
#include <osg/UserDataContainer>
#include <osg/ValueObject>

namespace WebCuda
{
    // Immutable shader-variant metadata only. Uniforms, textures and inherited
    // raster state are deliberately absent and are still captured every draw.
    struct ShaderDefines
    {
        using Values=std::map<std::string,std::string,std::less<>>;
        Values values;
        bool vertexLighting=false,terrainSpecular=false;
        bool enabled(std::string_view name) const
        {
            const auto found=values.find(name);
            return found!=values.end()&&found->second!="0"&&found->second!="false";
        }
        const std::string& value(std::string_view name) const
        {
            static const std::string empty;
            const auto found=values.find(name);
            return found==values.end()?empty:found->second;
        }
    };

    class ShaderDefineCache
    {
    public:
        enum Profile : unsigned int { Base=0,Terrain=1,Composite=2,Water=4,Groundcover=8,Unlit=16,Bethesda=32 };
        explicit ShaderDefineCache(std::size_t budget=2u*1024u*1024u,std::size_t entries=256)
            :mBudget(budget),mEntryLimit(entries) {}
        ShaderDefineCache(const ShaderDefineCache&)=delete;
        ShaderDefineCache& operator=(const ShaderDefineCache&)=delete;
        std::size_t retainedBytes() const { return mBytes; }
        std::size_t entryCount() const { return mEntries.size(); }

        std::shared_ptr<const ShaderDefines> get(std::string_view source,unsigned int profile=Base)
        {
            const Query query{source,profile};
            if(auto found=mEntries.find(query);found!=mEntries.end()) {
                mOrder.splice(mOrder.end(),mOrder,found->second.order);
                return found->second.defines;
            }
            auto parsed=std::make_shared<ShaderDefines>();
            // Match getline plus first '=': no trimming, empty names/values
            // are valid, and the last duplicate definition wins.
            for(std::size_t start=0;start<source.size();) {
                const auto end=source.find('\n',start);
                const auto line=source.substr(start,end==std::string_view::npos?source.size()-start:end-start);
                const auto split=line.find('=');
                if(split!=std::string_view::npos)
                    parsed->values.insert_or_assign(std::string(line.substr(0,split)),std::string(line.substr(split+1)));
                if(end==std::string_view::npos)break;
                start=end+1;
            }
            applyProfile(*parsed,profile);
            // Account retained strings, values and tree/list bookkeeping. An
            // oversized entry is usable for this call but is never retained.
            const std::size_t treeLinks=4*sizeof(void*);
            std::size_t bytes=sizeof(Key)+sizeof(Entry)+sizeof(ShaderDefines)+treeLinks+3*sizeof(void*)+source.size()+1;
            for(const auto& [name,value]:parsed->values)
                bytes+=sizeof(ShaderDefines::Values::value_type)+treeLinks+name.capacity()+value.capacity()+2;
            if(bytes>mBudget||mEntryLimit==0)return parsed;
            while(!mOrder.empty()&&(mEntries.size()>=mEntryLimit||mBytes>mBudget-bytes)) {
                const auto* oldest=mOrder.front();
                auto found=mEntries.find(Query{oldest->source,oldest->profile});
                mBytes-=found->second.bytes;mOrder.pop_front();mEntries.erase(found);
            }
            auto [entry,inserted]=mEntries.emplace(Key{std::string(source),profile},Entry{parsed,{},bytes});
            try {mOrder.push_back(&entry->first);}
            catch(...) {mEntries.erase(entry);throw;}
            entry->second.order=std::prev(mOrder.end());mBytes+=bytes;
            return parsed;
        }
    private:
        struct Key { std::string source;unsigned int profile; };
        struct Query { std::string_view source;unsigned int profile; };
        struct Compare
        {
            using is_transparent=void;
            static bool less(std::string_view a,unsigned int ap,std::string_view b,unsigned int bp)
            { const auto order=a.compare(b);return order<0||(order==0&&ap<bp); }
            bool operator()(const Key& a,const Key& b) const { return less(a.source,a.profile,b.source,b.profile); }
            bool operator()(const Key& a,const Query& b) const { return less(a.source,a.profile,b.source,b.profile); }
            bool operator()(const Query& a,const Key& b) const { return less(a.source,a.profile,b.source,b.profile); }
        };
        using Order=std::list<const Key*>;
        struct Entry { std::shared_ptr<const ShaderDefines> defines;Order::iterator order;std::size_t bytes; };
        std::size_t mBudget,mEntryLimit,mBytes=0;
        std::map<Key,Entry,Compare> mEntries;
        Order mOrder;

        static void applyProfile(ShaderDefines& parsed,unsigned int profile)
        {
            auto& defines=parsed.values;
            const bool water=(profile&Water)!=0,groundcover=(profile&Groundcover)!=0,
                unlit=(profile&Unlit)!=0,bethesda=(profile&Bethesda)!=0,
                terrain=(profile&Terrain)!=0,composite=(profile&Composite)!=0;
            if(water)for(const char* name:{"diffuseMap","normalMap","darkMap","detailMap","decalMap","emissiveMap","specularMap","envMap","bumpMap","glossMap","parallax","diffuseParallax","adjustCoverage"})defines[name]="0";
            if(groundcover)for(const char* name:{"darkMap","detailMap","decalMap","emissiveMap","specularMap","envMap","bumpMap","glossMap","blendMap",
                "parallax","diffuseParallax","adjustCoverage","forcePPL","softParticles","particleOcclusion","skyBlending","simpleLighting","particle","preLightEnv","additiveBlending"})defines[name]="0";
            if(unlit)for(const char* name:{"normalMap","specularMap","darkMap","detailMap","decalMap","emissiveMap","envMap","bumpMap","glossMap","blendMap",
                "parallax","diffuseParallax","preLightEnv","lightingMethodClustered","particleOcclusion"})defines[name]="0";
            if(bethesda)for(const char* name:{"specularMap","darkMap","detailMap","decalMap","envMap","bumpMap","glossMap","blendMap",
                "parallax","diffuseParallax","preLightEnv","softParticles","particleOcclusion","simpleLighting","particle"})defines[name]="0";
            // These two selectors use the pre-terrain/composite variant, as
            // the original material encoder did before replacing those maps.
            parsed.vertexLighting=!bethesda&&!unlit&&!water&&!composite&&!parsed.enabled("normalMap")&&!parsed.enabled("specularMap")&&!parsed.enabled("forcePPL");
            parsed.terrainSpecular=terrain&&parsed.enabled("specularMap");
            if(terrain){defines["diffuseMap"]="1";defines["diffuseMapUV"]="0";defines["normalMapUV"]="0";defines["specularMap"]="0";}
            if(composite)for(const char* name:{"darkMap","detailMap","decalMap","emissiveMap","normalMap","envMap","bumpMap","glossMap",
                "parallax","diffuseParallax","adjustCoverage","alphaToCoverage"})defines[name]="0";
        }
    };

    inline std::shared_ptr<const ShaderDefines> shaderDefines(const osg::Object& shader,unsigned int profile=ShaderDefineCache::Base)
    {
        static thread_local ShaderDefineCache cache;
        // The ordinary producer stores a StringValueObject. Borrow its string
        // for lookup; the cache owns its key and never trusts object identity.
        const auto* container=shader.asUserDataContainer();
        if(!container)container=shader.getUserDataContainer();
        const auto* object=container?container->getUserObject("webcuda.defines"):nullptr;
        // Match this OSG version's getUserValue exact-type check as well as
        // its missing/wrong-type behavior, without copying the source string.
        if(!object||typeid(*object)!=typeid(osg::StringValueObject))return {};
        return cache.get(static_cast<const osg::StringValueObject*>(object)->getValue(),profile);
    }
}
#endif
