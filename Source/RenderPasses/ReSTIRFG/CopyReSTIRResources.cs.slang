#include "Scene/Material/MaterialDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Utils.Math.PackedFormats;
import Utils.Math.FormatConversion;

import Scene.Raytracing;
import Scene.HitInfo;


#define is_valid(name) (is_valid_##name != 0)

Texture2D<float4> gThpIn;
Texture2D<float4> gViewIn;
Texture2D<float4> gPrevViewIn;
Texture2D<PackedHitInfo> gVBufferIn;

RWTexture2D<float4> gThpOut;
RWTexture2D<float4> gViewOut;
RWTexture2D<float4> gPrevViewOut;
RWTexture2D<PackedHitInfo> gVBufferOut;


[numthreads(16, 16, 1)]
void main(uint2 pixel : SV_DispatchThreadID)
{
    //if(is_valid(gThpOut)) gThpOut[pixel] = gThpIn[pixel];
    //if(is_valid(gViewOut)) gViewOut[pixel] = gViewIn[pixel];
    //if(is_valid(gPrevViewOut)) gPrevViewOut[pixel] = gPrevViewIn[pixel];
    //if(is_valid(gVBufferOut)) gVBufferOut[pixel] = gVBufferIn[pixel];
}
