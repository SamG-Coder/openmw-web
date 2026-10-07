#ifndef OPENMW_COMPONENTS_WEBCUDA_SHADERANALYSIS_H
#define OPENMW_COMPONENTS_WEBCUDA_SHADERANALYSIS_H
#include <array>
#include <cctype>
#include <cstdint>
#include <string>
#include <string_view>

namespace WebCuda
{
    // Shader identification only. Keep source-edit semantics even when strings
    // are modified in place without changing their address or length.
    inline bool compactShaderEquals(std::string_view source, std::string_view compact)
    {
        std::size_t next = 0;
        for (unsigned char c : source)
        {
            if (std::isspace(c)) continue;
            if (next == compact.size() || c != static_cast<unsigned char>(compact[next++])) return false;
        }
        return next == compact.size();
    }

    namespace ShaderAnalysisDetail
    {
        inline bool contains(std::string_view source, std::string_view compact)
        {
            if (compact.empty()) return true;
            for (auto first = source.find(compact.front()); first != std::string_view::npos;
                 first = source.find(compact.front(), first + 1))
            {
                auto cursor = first;
                std::size_t next = 0;
                while (cursor < source.size() && next < compact.size())
                {
                    const auto c = static_cast<unsigned char>(source[cursor++]);
                    if (std::isspace(c)) continue;
                    if (c != static_cast<unsigned char>(compact[next])) break;
                    ++next;
                }
                if (next == compact.size()) return true;
            }
            return false;
        }

        struct CacheStats { std::uint64_t hits=0, misses=0, bypasses=0; };
        class ContainsCache
        {
        public:
            static constexpr std::size_t Slots=64, MaxSourceBytes=16*1024, MaxNeedleBytes=256;
            bool contains(std::string_view source, std::string_view needle)
            {
                // Short inputs already terminate cheaply; do not allocate for
                // large/unusual shader sources. Fixed slots bound CPU storage.
                if(source.size()<512 || source.size()>MaxSourceBytes || needle.size()>MaxNeedleBytes || needle.empty())
                {
                    ++mStats.bypasses;
                    return ShaderAnalysisDetail::contains(source,needle);
                }
                std::size_t hash=reinterpret_cast<std::uintptr_t>(source.data())>>4;
                for(unsigned char c:needle)hash=(hash*33)^c;
                auto& entry=mEntries[hash%Slots];
                // Pointer is only a lookup hint. Owning snapshots and an exact
                // byte comparison are mandatory: dirty counters/address+size
                // cannot detect all edits. No borrowed shader memory is retained.
                if(entry.occupied && entry.needle==needle && entry.source==source)
                {
                    ++mStats.hits;
                    return entry.result;
                }
                ++mStats.misses;
                const bool result=ShaderAnalysisDetail::contains(source,needle);
                // std::isspace may classify non-ASCII bytes differently after a
                // locale change. Such sources keep the original uncached path.
                for(unsigned char c:source)if(c>=128)return result;
                for(unsigned char c:needle)if(c>=128)return result;
                entry.occupied=false;
                entry.source.assign(source.data(),source.size());
                entry.needle.assign(needle.data(),needle.size());
                entry.result=result;entry.occupied=true;
                return result;
            }
            CacheStats stats() const noexcept { return mStats; }
        private:
            struct Entry { std::string source,needle; bool occupied=false,result=false; };
            std::array<Entry,Slots> mEntries;
            CacheStats mStats;
        };
        inline ContainsCache& cache() { static thread_local ContainsCache value; return value; }
    }

    inline bool compactShaderContains(std::string_view source, std::string_view compact)
    {
        return ShaderAnalysisDetail::cache().contains(source,compact);
    }
}
#endif
