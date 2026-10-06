#ifndef OPENMW_ESM_FOGSTATE_H
#define OPENMW_ESM_FOGSTATE_H

#include <cstdint>
#include <vector>
#include <memory>
#include <string>

namespace ESM
{
    class ESMReader;
    class ESMWriter;

    // Transient owned GPU snapshot. Never serialized as a new save record:
    // completed PNG bytes use the existing FTEX representation.
    struct PendingFogImage
    {
        unsigned int mWidth=0,mHeight=0;
        std::vector<std::uint32_t> mInputs;
        std::vector<char> mPng;
        std::string mError;
        bool mReady=false;
    };

    struct FogTexture
    {
        int32_t mX=0, mY=0; // Only used for interior cells
        std::vector<char> mImageData;
        std::shared_ptr<PendingFogImage> mPendingImage;
    };

    // format 0, saved games only
    // Fog of war state
    struct FogState
    {
        // Only used for interior cells
        float mNorthMarkerAngle;
        struct Bounds
        {
            float mMinX;
            float mMinY;
            float mMaxX;
            float mMaxY;
        } mBounds;
        float mCenterX;
        float mCenterY;

        std::vector<FogTexture> mFogTextures;

        void load(ESMReader& esm);
        void save(ESMWriter& esm, bool interiorCell) const;
    };
}

#endif
