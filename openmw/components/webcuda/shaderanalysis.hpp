#ifndef OPENMW_COMPONENTS_WEBCUDA_SHADERANALYSIS_H
#define OPENMW_COMPONENTS_WEBCUDA_SHADERANALYSIS_H
#include <cctype>
#include <string_view>

namespace WebCuda
{
    // Shader identification only. Keep the whitespace semantics of the old
    // compact-source checks without allocating/copying complete GLSL strings
    // for every draw. Source edits take effect immediately, including edits
    // that keep the same string address and length.
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

    inline bool compactShaderContains(std::string_view source, std::string_view compact)
    {
        if (compact.empty()) return true;
        // Most shaders contain only one gl_Position assignment. Skip unrelated
        // source with string_view::find instead of rebuilding the entire source.
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
}
#endif
