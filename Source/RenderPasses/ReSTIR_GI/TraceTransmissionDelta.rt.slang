#include "Scene/Material/MaterialDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Scene.HitInfo;
import Rendering.Materials.StandardMaterial;
import Rendering.Materials.ClothMaterial;
import Rendering.Materials.HairMaterial;
import Rendering.Materials.MaterialShading;
import Rendering.Materials.Microfacet;

import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;
import Utils.Math.PackedFormats;
import Utils.Math.FormatConversion;
//import Rendering.Materials.IsotropicGGX;
import Utils.Color.ColorHelpers;


cbuffer PerFrame
{
    uint gFrameCount;       // Frame count since scene was loaded.
    uint gMaxBounces;       // Max number of bounces
    bool gRequDiffParts;
    bool gAlphaTest;
}

// Inputs
Texture2D<PackedHitInfo> gInVBuffer;

//Outputs
RWTexture2D<PackedHitInfo> gOutVBuffer;
RWTexture2D<float4> gOutViewDir;
RWTexture2D<float> gOutRayDist;
RWTexture2D<float4> gOutThp;

#define is_valid(name) (is_valid_##name != 0)

static const float kDemodulateMinReflectance = 0.01f;

struct TraceData
{
    PackedHitInfo packedHitInfo; //< Reflection albedo of the current hit point

    SampleGenerator sg; ///< Per-ray state for the sample generator (up to 16B).
    
    /** Create ray payload with default parameters.
    */
    static TraceData create()
    {
        TraceData d;
        d.packedHitInfo = {};
        return d;
    }
};

uint index2Dto1D(uint2 idx, uint width){
    return idx.x + width * idx.y;
}

//Load in shading data from hit and direction
ShadingData loadShadingData(const HitInfo hit, const float3 rayDir)
{
    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    ShadingData sd = prepareShadingData(v, materialID, gScene.materials[materialID], gScene.materialResources[materialID], -rayDir, 0.f);
    adjustShadingNormal(sd, v);
    
    return sd;
}

[shader("miss")]
void miss(inout TraceData rayData : SV_RayPayload)
{
    HitInfo hitInfo = { };
    rayData.packedHitInfo = hitInfo.pack();  //Invalid hit
}

//Use anyhit for alpha test if activated
[shader("anyhit")]
void anyHit(inout TraceData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes)
{
    if (gAlphaTest)
    {
        // Alpha test for non-opaque geometry.
        GeometryInstanceID instanceID = getGeometryInstanceID();
        VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
        uint materialID = gScene.getMaterialID(instanceID);
        if (alphaTest(v, gScene.materials[materialID], gScene.materialResources[materialID], 0.f))
            IgnoreHit();
    }
}

[shader("closesthit")]
void closestHit(inout TraceData rayData : SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs : SV_IntersectionAttributes){
    TriangleHit triangleHit;
    triangleHit.instanceID = getGeometryInstanceID();
    triangleHit.primitiveIndex = PrimitiveIndex();
    triangleHit.barycentrics = attribs.barycentrics;
    rayData.packedHitInfo = HitInfo(triangleHit).pack();
}

[shader("raygeneration")]
void rayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim = DispatchRaysDimensions().xy;

    float3 diffuseReflectance = { };
    float3 specularReflectance = { };
        
    HitInfo hitInfo = HitInfo(gInVBuffer[launchIndex]);
    float3 viewDir = -gScene.camera.computeRayPinhole(launchIndex, launchDim).dir;
    float rayDist = 0.f;
    float3 thp = float3(1);
    TraceData traceData = TraceData::create();
    traceData.sg = SampleGenerator(launchIndex, gFrameCount + 7 * 13);
    float3 originPos = gScene.camera.getPosition();  //For ray dist
    
    for (uint i = 0; i <= gMaxBounces; i++)
    {
        //End loop if the scene is missed
        if (!hitInfo.isValid())
            break;

        ShadingData sd = loadShadingData(hitInfo, -viewDir);
        rayDist = distance(originPos, sd.posW);
        
        //let bsdf = gScene.materials.getMaterialInstance(sd, lod, hints);
        //let bsdfProperties = bsdf.getProperties(sd);

        if (i == gMaxBounces)
            break;
        
        BSDFSample_ bsdfSample;

        if (!sampleBSDF(sd, traceData.sg, bsdfSample, true))
            break;

        bool isTransmission = bsdfSample.isLobe(LobeType::Transmission);
        bool hasDiffuseParts = gRequDiffParts ? luminance(sd.diffuse) > 0 : true;
        //bool isDiffuse = bsdfSample.isLobe(LobeType::Diffuse) && !isTransmission;
        bool isDiffuse = bsdfSample.isLobe(LobeType::NonDeltaReflection) && hasDiffuseParts;

        if(isDiffuse)
            break;
        
        thp *= bsdfSample.weight;   //Update troughput
                
        RayDesc tRay;
        tRay.Origin = sd.computeNewRayOrigin(!isTransmission);
        tRay.TMin = 0.0001f;
        tRay.TMax = 10000.f;
        tRay.Direction = bsdfSample.wi; //TODO sign

        TraceRay(gScene.rtAccel, 0, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, tRay, traceData);

        //Update info
        hitInfo = HitInfo(traceData.packedHitInfo);
        viewDir = -bsdfSample.wi;   //TODO sign
        originPos = sd.posW;
    }


    //Write
    gOutVBuffer[launchIndex] = hitInfo.pack();
    gOutViewDir[launchIndex] = float4(viewDir, 1);
    gOutRayDist[launchIndex] = rayDist;
    gOutThp[launchIndex] = float4(thp, 1);
}
