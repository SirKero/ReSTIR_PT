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
import Rendering.Lights.LightHelpers;
import Utils.Math.PackedFormats;
import Utils.Math.FormatConversion;
import Utils.Color.ColorHelpers;

import Reservoir;
import FinalGatherData;

//For syntax highlighting purposes
#ifndef MODE_FINAL_GATHER
    #define MODE_FINAL_GATHER 0
#endif

cbuffer PerFrame
{
    uint gFrameCount; // Frame count since scene was loaded.
    float2 gPhotonRadius; // x->Global Radius, y-> Caustic Radius
    float gAttenuationRadius;   //Radius for the distance attenuation
}

// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gView;
Texture2D<PackedHitInfo> gFinalGatherHit;
StructuredBuffer<AABB> gPhotonAABB[2];
StructuredBuffer<uint4> gPackedPhotonData[2];

// Outputs
RWTexture2D<float4> gColor;
RWStructuredBuffer<FGData> gFGSampleData;
RWTexture2D<float4> gCausticOut;


#if USE_REDUCED_RESERVOIR_FORMAT
    RWTexture2D<uint2> gReservoir;
#else
    RWTexture2D<uint4> gReservoir;
#endif


//Acceleration Structure
RaytracingAccelerationStructure gPhotonAS;

/** Payload for ray (48B).
*/
struct RayData
{
    float3 radiance; ///< Accumulated outgoing radiance from path.
    uint pad; ///< free space.
    PackedHitInfo packedHitInfo; ///< Hit info from vBuffer; Up to 16B

    SampleGenerator sg; ///< Per-ray state for the sample generator (up to 16B).
  
    __init(){
        this.radiance = float3(0);
        this.pad = 0;
    }
};

struct SphereAttribs
{
    float2 pad;
};

//Load in shading data from hit and direction
ShadingData loadShadingData(const HitInfo hit, const float3 rayDir)
{
    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    ShadingData sd = prepareShadingData(v, materialID, gScene.materials[materialID], gScene.materialResources[materialID], -rayDir, 0.f);
    
    return sd;
}

uint index2Dto1D(uint2 idx, uint width)
{
    return idx.x + width * idx.y;
}

[shader("miss")]
void miss(inout RayData rayData : SV_RayPayload)
{
    //Empty. Is needed for compilation
}


[shader("anyhit")]
void anyHit(inout RayData rayData : SV_RayPayload, SphereAttribs attribs : SV_IntersectionAttributes)
{
    const uint primIndex = PrimitiveIndex();

    //Get Photon data
    PhotonData pd = PhotonData(gPackedPhotonData[InstanceIndex()][primIndex]);
        
    //Get hit data from payload
    const HitInfo hit = HitInfo(rayData.packedHitInfo);
    //World Direction is set to the viewDir we get from the vBuffer
    ShadingData sd = loadShadingData(hit, WorldRayDirection());
    //Check for different surfaces
    
    if (dot(pd.normal, sd.faceN) < 0.6)
    {
        return;
    }
    
    //Photon contribution
    //uint hints = (uint) MaterialInstanceHints::AdjustShadingNormal;
    //let bsdf = gScene.materials.getMaterialInstance(sd, lod, hints);
    //let bsdfProperties = bsdf.getProperties(sd);
    float3 f_r = evalBSDFCosine(sd, pd.dir); //right sign?
    float NdotL = saturate(dot(sd.N, pd.dir));
    if(NdotL > 0)
        rayData.radiance += max(0.f, (f_r * pd.flux) / NdotL);
}

//Checks if the ray start point is inside the sphere.
bool hitSphere(const float3 center, const float radius, const float3 p)
{
    float3 radiusTest = p - center;
    radiusTest = radiusTest * radiusTest;
    float radiusTestF = radiusTest.x + radiusTest.y + radiusTest.z;
    if (radiusTestF < radius * radius)
        return true;
    return false;
}

[shader("intersection")]
void intersection()
{
    //Get start point and prim index
    const float3 origin = ObjectRayOrigin();
    const uint primIndex = PrimitiveIndex();

    //Get Photon AABB. Instance Index 0 is caustic; 1 is global
    AABB photonAABB = gPhotonAABB[InstanceIndex()][primIndex];
    float radius = InstanceIndex() == 0 ? gPhotonRadius.x : gPhotonRadius.y;
    
    //Check for Sphere intersection
    bool tHit = hitSphere(photonAABB.center(), radius, origin);

    //Attribs are needed by the api. Because we have no need for additional attributes it is empty
    SphereAttribs attribs;
    attribs.pad = float2(0);

    //Report the hit if the point is in the sphere
    if (tHit)
    {
        ReportHit(RayTCurrent(), 0, attribs);
    }
}


[shader("raygeneration")]
void rayGen()
{
    uint2 launchIndex = DispatchRaysIndex().xy;
    uint2 launchDim = DispatchRaysDimensions().xy;
        
    //Init reservoir
    Reservoir r = Reservoir(gReservoir[launchIndex]);
    r.M = 1; //set M to the right value
    
    //Prepare payload
    RayData rayData = RayData();
    rayData.packedHitInfo = gVBuffer[launchIndex];
    rayData.sg = SampleGenerator(launchIndex, gFrameCount + 3 * 12);

    HitInfo hit = HitInfo(rayData.packedHitInfo);
    bool valid = hit.isValid(); //Check if the ray is valid
    #if MODE_FINAL_GATHER
    ShadingData fgSD = {};
    if(valid){
        fgSD = loadShadingData(hit, -gView[launchIndex].xyz); //TODO remove
    }
    #endif

    RayDesc ray;
    uint rayFlags = RAY_FLAG_SKIP_CLOSEST_HIT_SHADER | RAY_FLAG_SKIP_TRIANGLES;
    float3 causticRadiance = float3(0);
    
    if (valid)
    {
        //Get vertex data for the world position
        TriangleHit triangleHit = hit.getTriangleHit();
        VertexData v = gScene.getVertexData(triangleHit);
    
        //Ray description 
        ray.Origin = v.posW;
        ray.TMin = 0.0;
        ray.TMax = 0.001;
        ray.Direction = -gView[launchIndex].xyz; //we take the view dir as direction to save payload space
        
        //Collect Caustic Photon
        TraceRay(gPhotonAS, rayFlags, 2 /* instanceInclusionMask */, 0 /* hitIdx */, 0 /* rayType count */, 0 /* missIdx */, ray, rayData);
        float w = 1 / (M_PI * gPhotonRadius.y * gPhotonRadius.y);
        causticRadiance += w * rayData.radiance;
   
    }
    
    rayData.radiance = float3(0);
    rayData.packedHitInfo = gFinalGatherHit[launchIndex];
    hit = HitInfo(rayData.packedHitInfo);
    valid &= hit.isValid(); //Check if the final gather ray is valid

    float3 fgRadiance = float3(0);
    float jacoDeter = -1.f;

    ShadingData sd = { };
    
    if (valid)
    {
        TriangleHit triangleHit = hit.getTriangleHit();
        VertexData v = gScene.getVertexData(triangleHit);
        ray.Direction = v.posW - ray.Origin; //Sample dir is used here to save payload space
        float distToFG = length(ray.Direction); //Distance for Jacobian determinant
        ray.Direction /= distToFG; //Normalize
    
        ray.Origin = v.posW; //Update origin
        ray.TMin = 0.0;
        ray.TMax = 0.001;
                
        uint materialID = gScene.getMaterialID(triangleHit.instanceID);
        sd = prepareShadingData(v, materialID, gScene.materials[materialID], gScene.materialResources[materialID], -ray.Direction, 0.f);
            
        
        //Jacobian Determinant (only needed for resampling)
#if !MODE_FINAL_GATHER
        jacoDeter = vplAttenuation(distToFG, gAttenuationRadius) * saturate(dot(sd.N, sd.V));
#endif
        
        TraceRay(gPhotonAS, rayFlags, 1 /* instanceInclusionMask */, 0 /* hitIdx */, 0 /* rayType count */, 0 /* missIdx */, ray, rayData);
        float w = 1 / (M_PI * gPhotonRadius.x * gPhotonRadius.x);
        fgRadiance += w * rayData.radiance;
    }

#if MODE_FINAL_GATHER
    
    //Final gather
    float3 color = float3(0);
    if(valid){
        color = max(0.f, fgRadiance * r.weightSum);
        color *= evalBSDFCosine(fgSD, ray.Direction);
    }
        
    gColor[launchIndex] = float4(color + causticRadiance, 1.f);

#else
   
    //ReSTIR Candidate
    uint lightIdx = index2Dto1D(launchIndex, launchDim.x);
    float Li = luminance(fgRadiance);

    r.targetPdf *= Li; //Add the missing parts of the targetPDF (Li)

     //Create the final gather sample
    FGData fgData = { };
    bool fgValid = true;
    if (isnan(Li) || isinf(Li))
        fgValid = false;
    fgData.posW = sd.computeNewRayOrigin();
    fgData.normal = sd.N;
    fgData.flux = fgRadiance;
    fgData.jacobianDeterminant = fgValid ? jacoDeter : -1.f;    //Negative jacobian determinant is an invalid sample

    if (!fgValid)
    {
        r.M = 0;
        r.weightSum = 0.f;
    }

#if USE_REDUCED_RESERVOIR_FORMAT
    gReservoir[launchIndex] = r.packReduced();
#else  //USE_REDUCED_RESERVOIR_FORMAT
    gReservoir[launchIndex] = r.pack();
#endif //USE_REDUCED_RESERVOIR_FORMAT
    gFGSampleData[index2Dto1D(launchIndex, launchDim.x)] = fgData;
    gCausticOut[launchIndex] = float4(causticRadiance, 1.f);

#endif //!(MODE_FINAL_GATHER)
}
